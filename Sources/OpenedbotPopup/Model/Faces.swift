import AppKit
import ImageIO
import SwiftUI

/// Les visages bloub de la console au repos (`Resources/faces`, exportés depuis la console openedbot
/// avec le vrai moteur) : un SVG par forme × expression, la couleur posée à la volée.
@MainActor
enum BloubFaces {
    struct Catalog: Decodable { var shapes: [String]; var expressions: [String]; var colors: [String] }

    static let catalog: Catalog = load("catalog", as: Catalog.self) ?? Catalog(shapes: [], expressions: [], colors: [])
    static let colors: [String: String] = load("colors", as: [String: String].self) ?? [:]
    private static var cache: [String: NSImage] = [:]

    private static func load<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "faces"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// `pickBySeed` de la console : un identifiant inconnu retombe sur un choix stable tiré de la graine.
    nonisolated static func pick(_ list: [String], seed: String, salt: String) -> String? {
        guard !list.isEmpty else { return nil }
        var hash: UInt32 = 0
        for unit in "\(salt):\(seed)".utf16 { hash = hash &* 31 &+ UInt32(unit) }
        return list[Int(hash % UInt32(list.count))]
    }

    static func resolve(_ face: BotFace, seed: String) -> (shape: String, eyes: String, color: String)? {
        func find(_ list: [String], _ id: String?, _ salt: String) -> String? {
            if let id, list.contains(id) { return id }
            return pick(list, seed: seed, salt: salt)
        }
        guard let shape = find(catalog.shapes, face.shape, "shape"), let eyes = find(catalog.expressions, face.eyes, "eyes"),
              let color = find(catalog.colors, face.palette, "palette") else { return nil }
        return (shape, eyes, color)
    }

    static func image(_ face: BotFace, seed: String) -> NSImage? {
        guard let r = resolve(face, seed: seed), var hex = colors[r.color] else { return nil }
        // « encre » (#0a0a0c) disparaît sur le noir de l'encoche et des fenêtres : on l'éclaircit en gris clair.
        if r.color == "encre" { hex = "#d4d4d4" }
        let key = "\(r.shape)/\(r.eyes)/\(hex)"
        if let hit = cache[key] { return hit }
        guard let url = Bundle.module.url(forResource: "face-\(r.shape)-\(r.eyes)", withExtension: "svg", subdirectory: "faces"),
              let template = try? String(contentsOf: url, encoding: .utf8),
              let image = NSImage(data: Data(template.replacingOccurrences(of: "#INK", with: hex).utf8)) else { return nil }
        cache[key] = image
        return image
    }
}

/// Les images servies par l'API avec la session (`/api/attachments/:id`) : avatars importés, pièces jointes.
/// Le flux openedbot pose le chargeur ; en démo il n'y en a pas et rien ne se charge.
///
/// Une image se demande à une taille : `maxPixels` nil la garde entière (pièce jointe), sinon elle est
/// décodée en vignette hors du fil principal (avatar). La clé est le chemin, qui change quand le bot
/// change d'image (une pièce jointe ne change jamais d'octets) : l'ancienne n'est simplement plus lue.
@MainActor @Observable
final class RemoteImages {
    static let shared = RemoteImages()
    /// Après un échec, on retente au plus tôt après ce délai : une coupure passagère ne fige pas le repli.
    static let retryAfter: TimeInterval = 30
    @ObservationIgnored var loader: (@MainActor (String) async throws -> Data)?
    private(set) var images: [String: NSImage] = [:]
    private(set) var failures: [String: Date] = [:]
    @ObservationIgnored private var inflight: Set<String> = []
    /// Monte à chaque `reset` : une réponse demandée pour l'ancienne session ne s'écrit plus.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var now: () -> Date = Date.init

    private static func key(_ path: String, _ maxPixels: Int?) -> String {
        maxPixels.map { "\(path)#\($0)" } ?? path
    }

    func image(_ path: String, maxPixels: Int? = nil) -> NSImage? { images[Self.key(path, maxPixels)] }
    func failed(_ path: String, maxPixels: Int? = nil) -> Bool { failures[Self.key(path, maxPixels)] != nil }

    func load(_ path: String, maxPixels: Int? = nil) {
        let key = Self.key(path, maxPixels)
        guard images[key] == nil, !inflight.contains(key), let loader else { return }
        if let failedAt = failures[key], now().timeIntervalSince(failedAt) < Self.retryAfter { return }
        inflight.insert(key)
        let generation = self.generation
        Task {
            let image: NSImage?
            do {
                let data = try await loader(path)
                image = try await Self.decode(data, maxPixels: maxPixels)
            } catch {
                image = nil
            }
            guard generation == self.generation else { return }
            inflight.remove(key)
            if let image {
                images[key] = image
                failures[key] = nil
            } else {
                failures[key] = now()
            }
        }
    }

    /// Une vignette se décode hors du fil principal ; une image entière reste paresseuse (`NSImage(data:)`).
    private static func decode(_ data: Data, maxPixels: Int?) async throws -> NSImage {
        guard let maxPixels else {
            guard let image = NSImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            return image
        }
        let thumbnail = await Task.detached(priority: .userInitiated) { () -> Thumbnail? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = Avatars.thumbnail(source: source, maxPixels: maxPixels) else { return nil }
            return Thumbnail(image: cg)
        }.value
        guard let cg = thumbnail?.image else { throw CocoaError(.fileReadCorruptFile) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private struct Thumbnail: @unchecked Sendable { let image: CGImage }

    func reset() {
        generation += 1
        images.removeAll()
        failures.removeAll()
        inflight.removeAll()
    }
}

/// Le visage d'un bot comme `BotFace` dans la console (`AvatarSource`) : image importée, illustration
/// du catalogue, visage bloub. L'initiale ne sert que si rien de cela ne se dessine.
struct FaceView: View {
    let seed: String
    let name: String
    let face: BotFace?
    var size: CGFloat
    private var remote = RemoteImages.shared

    init(seed: String, name: String, face: BotFace?, size: CGFloat) {
        self.seed = seed; self.name = name; self.face = face; self.size = size
    }

    var body: some View {
        switch AvatarSource.resolve(seed: seed, face: face) {
        case .uploaded(let path):
            uploaded(path)
        case .artwork(let artwork):
            if let image = Avatars.image(for: artwork) {
                let portrait = Avatars.portraits.contains(artwork)
                Image(nsImage: image).resizable().interpolation(.high)
                    .aspectRatio(contentMode: portrait ? .fill : .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: portrait ? size * 0.3 : 0, style: .continuous))
            } else {
                initial
            }
        case .bloub(let face):
            bloub(face)
        }
    }

    /// L'image importée, ronde et remplie comme dans la console ; un disque discret pendant le
    /// chargement, le visage bloub de la fiche si elle ne se charge pas.
    private func uploaded(_ path: String) -> some View {
        Group {
            if let image = remote.image(path, maxPixels: Avatars.thumbnailPixels) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(Circle())
            } else if remote.failed(path, maxPixels: Avatars.thumbnailPixels) {
                bloub(AvatarSource.uploadFallback(face))
            } else {
                Circle().fill(.white.opacity(0.1)).frame(width: size, height: size)
            }
        }
        .task(id: path) { remote.load(path, maxPixels: Avatars.thumbnailPixels) }
    }

    @ViewBuilder private func bloub(_ face: BotFace) -> some View {
        if let image = BloubFaces.image(face, seed: seed) {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            initial
        }
    }

    private var initial: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(Palette.textPrimary)
            .frame(width: size, height: size)
            .background(Circle().fill(.white.opacity(0.14)))
    }
}
