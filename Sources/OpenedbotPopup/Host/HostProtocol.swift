import Foundation

/// Le protocole hôte ↔ popup, v1 : une ligne JSON par message, de l'hôte sur notre stdin, vers
/// l'hôte sur notre stdout. Miroir du protocole de l'app bureau openedbot, qui fait foi
/// (OpenedBot/openedbot : apps/desktop-tauri/src-tauri/src/popup.rs, l'hôte Tauri qui envoie
/// `updateState` ; apps/desktop/src/shared/popup-protocol.ts pour l'ancien shell Electron) :
/// changer les deux ensemble.
///
/// Règles : une version inconnue arrête la session ; une ligne mal formée est ignorée et
/// journalisée sans son contenu ; jamais de refresh token sur ce canal ; jamais de jeton dans
/// un journal. Les champs inconnus sont ignorés, pour qu'une v1 puisse s'enrichir ; un type
/// inconnu aussi (`.unknownType`, journalisé), pour qu'un hôte plus récent ne casse pas la popup.
///
/// Hôte → popup : `hello`, `token`, `signedIn`, `signedOut`, et `updateState`
/// (`{"type":"updateState","status":"ready","version":"1.0.4"}`) : l'état de la mise à jour de
/// l'app, envoyé à chaque changement et une fois après `hello` + `signedIn`/`signedOut`. `status`
/// est un mot en minuscules (`idle`, `checking`, `available`, `downloading`, `ready`, `installing`,
/// `error`, `required` ; un autre mot ne montre rien) ; `version` est absent, null, ou des
/// chiffres et des points. Ajouté dans la v1 sans changer de version : une popup plus ancienne
/// l'ignore comme tout type inconnu.
/// Popup → hôte : `ready`, `token`, `openConsole`, `signOut`, `fatal`.
///
/// La démonstration, ajoutée dans la v1 de la même façon : `ready` annonce `features: ["demo"]`
/// (un hôte plus ancien ignore le champ) ; l'hôte n'envoie `demo` (`{"type":"demo","cycles":0}`)
/// qu'à une popup qui l'a annoncée, avant l'état de session, puis `endDemo` pour revenir aux vrais
/// bots. `cycles` : combien de boucles avant l'arrêt, 0 = jusqu'à ce que l'utilisateur la touche.
/// Arrêtée d'elle-même, la démo garde sa dernière image et l'écrit à l'hôte : `demoEnded`.
enum HostProtocol {
    static let version = 1
    /// Ce que cette popup sait faire au-delà de la v1, annoncé dans `ready` (et déclaré dans
    /// `OpenedbotHostedFeatures` de l'Info.plist, que l'hôte lit avant de la lancer).
    static let features = ["demo"]
    /// La plus longue ligne acceptée, en octets. Un vrai message en fait quelques centaines.
    static let maxLineLength = 16 * 1024

    /// Hôte → popup.
    enum Incoming: Equatable, Sendable {
        case hello(protocol: Int, apiOrigin: String, consoleURL: String)
        case token(TokenReply)
        case signedOut
        case signedIn
        /// L'état de la mise à jour de l'app chez l'hôte. `status` reste le mot reçu : c'est
        /// `HostUpdate` qui décide quoi montrer, un mot inconnu ne montre rien.
        case updateState(status: String, version: String?)
        /// Jouer la démonstration (bots fictifs, aucun réseau) au lieu des bots de la session.
        case demo(cycles: Int)
        /// Revenir aux bots de la session.
        case endDemo
    }

    /// Les trois valeurs sont nulles ensemble. Nulles sans `unavailable` : pas de session.
    /// Nulles avec : la session vit, mais l'hôte n'a pas pu avoir de jeton (réseau, 5xx).
    struct TokenReply: Equatable, Sendable {
        var id: String
        var accessToken: String?
        var expiresAt: String?
        var organizationId: String?
        var unavailable = false
    }

    /// Popup → hôte.
    enum Outgoing: Equatable, Sendable {
        case ready(protocol: Int, version: String, features: [String] = HostProtocol.features)
        /// `force` : l'équivalent de `bridge.refresh()`, après un 401 sur un jeton qu'on croyait bon.
        case token(id: String, force: Bool)
        /// Montrer la fenêtre d'openedbot et l'amener sur ce chemin de la console.
        case openConsole(path: String)
        case signOut
        /// On refuse de tourner pour une raison qu'une relance ne guérira pas, puis on quitte.
        case fatal(code: String)
        /// La démonstration s'est arrêtée d'elle-même ; elle garde sa dernière image jusqu'à `endDemo`.
        case demoEnded
    }

    enum ParseFailure: Error, Equatable, Sendable {
        case tooLong, invalidJSON, notAnObject, unknownType, invalidFields
    }

    // MARK: Lecture

    static func parse(_ line: String) -> Result<Incoming, ParseFailure> {
        guard line.utf8.count <= maxLineLength else { return .failure(.tooLong) }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) } catch {
            return .failure(.invalidJSON)
        }
        guard let f = object as? [String: Any] else { return .failure(.notAnObject) }
        switch f["type"] as? String {
        case "hello":
            guard let p = integer(f["protocol"]), let api = string(f["apiOrigin"], max: 2048),
                  let console = string(f["consoleUrl"], max: 2048) else { return .failure(.invalidFields) }
            return .success(.hello(protocol: p, apiOrigin: api, consoleURL: console))
        case "token":
            guard let id = f["id"] as? String, isID(id) else { return .failure(.invalidFields) }
            let fields = [("accessToken", 8192), ("expiresAt", 64), ("organizationId", 128)].map { key, max in nullableString(f[key], max: max) }
            // Chaque champ doit être présent : une chaîne valide ou null.
            guard fields.allSatisfy({ $0 != nil }) else { return .failure(.invalidFields) }
            let values = fields.map { $0! }
            let nulls = values.filter { $0 == nil }.count
            guard nulls == 0 || nulls == 3 else { return .failure(.invalidFields) }
            var reply = TokenReply(id: id, accessToken: values[0], expiresAt: values[1], organizationId: values[2])
            if let error = f["error"] {
                guard error as? String == "unavailable", nulls == 3 else { return .failure(.invalidFields) }
                reply.unavailable = true
            }
            return .success(.token(reply))
        case "signedOut": return .success(.signedOut)
        case "signedIn": return .success(.signedIn)
        case "updateState":
            guard let status = f["status"] as? String, isWord(status) else { return .failure(.invalidFields) }
            // Absent ou null : version inconnue. Présent : des chiffres et des points, rien d'autre.
            let version: String?
            switch f["version"] {
            case nil, is NSNull: version = nil
            case let v as String where isVersion(v): version = v
            default: return .failure(.invalidFields)
            }
            return .success(.updateState(status: status, version: version))
        case "demo":
            guard let cycles = integer(f["cycles"]), cycles <= 100 else { return .failure(.invalidFields) }
            return .success(.demo(cycles: cycles))
        case "endDemo": return .success(.endDemo)
        default: return .failure(.unknownType)
        }
    }

    // MARK: Écriture

    /// Une ligne terminée par `\n`. On copie les champs un à un : rien d'autre ne peut partir.
    static func encode(_ message: Outgoing) -> Data {
        let fields: [String: Any] = switch message {
        case .ready(let p, let v, let features): ["type": "ready", "protocol": p, "version": v, "features": features]
        case .token(let id, let force): ["type": "token", "id": id, "force": force]
        case .openConsole(let path): ["type": "openConsole", "path": path]
        case .signOut: ["type": "signOut"]
        case .fatal(let code): ["type": "fatal", "code": code]
        case .demoEnded: ["type": "demoEnded"]
        }
        // JSONSerialization échappe les sauts de ligne des chaînes : un message reste une ligne.
        var data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data(#"{"type":"fatal","code":"ENCODING"}"#.utf8)
        data.append(0x0A)
        return data
    }

    // MARK: Origine

    /// L'origine imposée par `hello` : HTTPS, ou HTTP pour les hôtes de lab qu'openedbot accepte aussi
    /// (boucle locale, réseaux privés, `.local` / `.lan` / `.test`). Jamais de chemin.
    static func origin(from raw: String) -> URL? {
        guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty,
              c.path.isEmpty || c.path == "/", c.query == nil, c.fragment == nil, c.user == nil, c.password == nil else { return nil }
        guard scheme == "https" || (scheme == "http" && isLabHost(host)) else { return nil }
        var out = URLComponents()
        out.scheme = scheme; out.host = host; out.port = c.port
        return out.url
    }

    /// La console, chemin éventuel compris ; mêmes règles de schéma que l'API.
    static func consoleURL(from raw: String) -> URL? {
        guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(), !host.isEmpty,
              c.query == nil, c.fragment == nil, c.user == nil, c.password == nil else { return nil }
        guard scheme == "https" || (scheme == "http" && isLabHost(host)) else { return nil }
        return c.url
    }

    static func isLabHost(_ host: String) -> Bool {
        if host == "localhost" || host == "[::1]" || host == "::1" || host.hasSuffix(".localhost") { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".test") { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        let (a, b) = (octets[0], octets[1])
        return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b))
    }

    // MARK: Plomberie

    private static func isID(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// Un mot d'état : 1 à 32 lettres ASCII minuscules.
    private static func isWord(_ s: String) -> Bool {
        (1...32).contains(s.unicodeScalars.count) && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
    }

    /// Une version : 1 à 32 chiffres ASCII et points.
    private static func isVersion(_ s: String) -> Bool {
        (1...32).contains(s.unicodeScalars.count) && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || $0 == "." }
    }

    private static func string(_ value: Any?, max: Int) -> String? {
        guard let s = value as? String, !s.isEmpty, s.count <= max else { return nil }
        return s
    }

    /// `.some(nil)` pour un null JSON, `.some(s)` pour une chaîne valide, nil sinon (absent, mauvais type).
    private static func nullableString(_ value: Any?, max: Int) -> String?? {
        if value is NSNull { return .some(nil) }
        guard let s = string(value, max: max) else { return nil }
        return .some(s)
    }

    /// Un entier JSON, pas un booléen (`NSNumber` les confond) ni un décimal.
    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d >= 0, d == d.rounded(), d < 1_000_000 else { return nil }
        return Int(d)
    }
}

/// Découpe un flux d'octets en lignes. Une ligne trop longue est jetée jusqu'à son saut de ligne et
/// comptée, jamais gardée sans limite.
struct HostLineSplitter: Sendable {
    private var buffer: [UInt8] = []
    private var discarding = false
    let maxLength: Int

    init(maxLength: Int = HostProtocol.maxLineLength) { self.maxLength = maxLength }

    mutating func push(_ bytes: some Sequence<UInt8>) -> (lines: [String], overflowed: Int) {
        var lines: [String] = []
        var overflowed = 0
        for b in bytes {
            if b == 0x0A {
                if discarding {
                    discarding = false
                } else {
                    if buffer.last == 0x0D { buffer.removeLast() }
                    let line = String(decoding: buffer, as: UTF8.self)
                    if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
                }
                buffer.removeAll(keepingCapacity: true)
            } else if !discarding {
                buffer.append(b)
                if buffer.count > maxLength {
                    buffer.removeAll()
                    discarding = true
                    overflowed += 1
                }
            }
        }
        return (lines, overflowed)
    }
}
