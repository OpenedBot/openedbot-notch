import Foundation

/// Un bail YOLO : signé et daté côté openedbot, il auto-approuve les écritures d'un bot sur l'hôte
/// jusqu'à `expiresAt`. L'encoche ne fait que le montrer et proposer de tout couper.
struct YoloLease: Equatable, Sendable, Identifiable {
    enum Scope: String, Equatable, Sendable {
        case thread, bot, runtime
        /// Une portée qu'un serveur plus récent enverrait : le bail compte quand même.
        case unknown

        /// Départage deux baux qui finissent en même temps : le plus large d'abord.
        var breadth: Int {
            switch self { case .runtime: 0; case .bot: 1; case .thread: 2; case .unknown: 3 }
        }
    }

    var id: String
    var scope: Scope
    var botID: String?
    var threadID: String?
    var runtimeID: String?
    /// Nil quand le serveur ne l'envoie pas ou sous une forme illisible : le bail reste actif
    /// jusqu'à ce que le serveur le retire (montrer YOLO à tort vaut mieux que le cacher).
    var expiresAt: Date?

    func isActive(at now: Date) -> Bool { expiresAt.map { $0 > now } ?? true }
}

extension YoloLease: Decodable {
    private enum Keys: String, CodingKey { case leaseId, id, scope, botId, threadId, runtimeId, expiresAt }

    /// Tolérant : tous les champs sont facultatifs, seul un élément qui n'est pas un objet est refusé.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func string(_ key: Keys) -> String? {
            guard let v = try? c.decodeIfPresent(String.self, forKey: key), !v.isEmpty else { return nil }
            return v
        }
        id = string(.leaseId) ?? string(.id) ?? ""
        scope = string(.scope).flatMap { Scope(rawValue: $0.lowercased()) } ?? .unknown
        botID = string(.botId)
        threadID = string(.threadId)
        runtimeID = string(.runtimeId)
        if let n = try? c.decodeIfPresent(Double.self, forKey: .expiresAt) {
            expiresAt = Yolo.date(epoch: n)
        } else {
            expiresAt = string(.expiresAt).flatMap(Yolo.date(parsing:))
        }
    }
}

/// `GET /api/organization/yolo/leases` : `{ "leases": [...] }` (ou `items`), ou directement un tableau.
/// Un élément illisible est sauté, pas toute la réponse.
struct YoloLeasesDto: Decodable, Sendable {
    var leases: [YoloLease]

    private enum Keys: String, CodingKey { case leases, items }
    /// Consomme un élément sans le lire, pour passer à la suite après un échec.
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(leases: [YoloLease]) { self.leases = leases }

    init(from decoder: Decoder) throws {
        var list: UnkeyedDecodingContainer
        if let c = try? decoder.container(keyedBy: Keys.self) {
            let key: Keys
            if c.contains(.leases) { key = .leases } else if c.contains(.items) { key = .items } else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "leases attendu"))
            }
            if try c.decodeNil(forKey: key) { leases = []; return }
            list = try c.nestedUnkeyedContainer(forKey: key)
        } else {
            list = try decoder.unkeyedContainer()
        }
        var out: [YoloLease] = []
        while !list.isAtEnd {
            if let lease = try? list.decode(YoloLease.self) { out.append(lease) } else { _ = try list.decode(Skip.self) }
        }
        leases = out
    }
}

/// Ce que l'île sait de YOLO : les baux actifs relus toutes les 30 s, et la coupure en cours.
struct YoloState: Equatable, Sendable {
    var leases: [YoloLease] = []
    /// « Couper YOLO partout » est parti, pas encore revenu.
    var killing = false
    /// Le dernier échec de la coupure, en clair ; effacé par l'essai suivant.
    var killError: String?

    func active(at now: Date) -> [YoloLease] { leases.filter { $0.isActive(at: now) } }
    func isActive(at now: Date) -> Bool { leases.contains { $0.isActive(at: now) } }
}

enum Yolo {
    /// Le bail montré par le badge : celui qui finit le dernier, puisque YOLO reste actif jusqu'à
    /// lui. Un bail sans échéance l'emporte ; à égalité, le plus large, puis l'identifiant.
    static func displayed(_ leases: [YoloLease], now: Date) -> YoloLease? {
        leases.filter { $0.isActive(at: now) }.min { a, b in
            let ea = a.expiresAt ?? .distantFuture, eb = b.expiresAt ?? .distantFuture
            if ea != eb { return ea > eb }
            if a.scope.breadth != b.scope.breadth { return a.scope.breadth < b.scope.breadth }
            return a.id < b.id
        }
    }

    /// Le compte à rebours du badge : `m:ss` sous l'heure, `h:mm:ss` au-delà. Arrondi à la seconde
    /// supérieure : « 0:01 » jusqu'à la dernière seconde, « 0:00 » une fois l'échéance passée.
    static func countdown(until end: Date, now: Date) -> String {
        let s = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Ce que couvre le bail, en quelques mots.
    static func scopeText(_ lease: YoloLease, botName: String?) -> String {
        switch lease.scope {
        case .runtime: tr("whole runtime", "tout le runtime")
        case .bot: botName ?? tr("one bot", "un bot")
        case .thread: botName.map { tr("one thread of \($0)", "un fil de \($0)") } ?? tr("one thread", "un fil")
        case .unknown: tr("unknown scope", "portée inconnue")
        }
    }

    static func leaseCount(_ n: Int) -> String {
        n == 1 ? tr("1 active lease", "1 bail actif") : tr("\(n) active leases", "\(n) baux actifs")
    }

    /// Un nombre d'epoch : en millisecondes au-delà de 10^11 (an 5138 en secondes, 1973 en
    /// millisecondes), en secondes sinon.
    static func date(epoch n: Double) -> Date? {
        guard n.isFinite else { return nil }
        return Date(timeIntervalSince1970: abs(n) >= 1e11 ? n / 1000 : n)
    }

    /// ISO 8601 (fractions de seconde ou non), ou un epoch écrit en chaîne.
    static func date(parsing raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if let n = Double(s) { return date(epoch: n) }
        return (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
            ?? (try? Date(s, strategy: Date.ISO8601FormatStyle()))
    }
}
