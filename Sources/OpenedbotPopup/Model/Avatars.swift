import AppKit
import ImageIO
import SwiftUI

/// Les artworks WEBP d'openedbot (console openedbot), embarqués dans `Resources/bots`.
/// Ils font 1024 px et l'encoche les montre entre 13 et 34 pt : décodés en entier, dix
/// avatars pèsent 40 Mo ; en vignettes (256 px au plus, ImageIO réduit par deux), 2,5 Mo.
@MainActor
enum Avatars {
    static let thumbnailPixels = 128
    /// Les portraits du catalogue (`artworks.ts`) : recadrés, coins arrondis ; les autres tiennent dans le cadre.
    nonisolated static let portraits: Set<String> = ["astral", "halo", "selene"]
    /// `BOT_ARTWORKS` de la console : les artworks tirés au hasard, puis les portraits. Chacun a son
    /// fichier dans `Resources/bots` (copie à l'octet de `apps/console/public/bots`) ; un identifiant
    /// hors de cette liste n'est pas un artwork, comme `resolveBotArtwork` le dit.
    nonisolated static let catalog: Set<String> = Set(OpenedbotMapping.defaultArtworks).union(portraits)
    private static var cache: [String: NSImage] = [:]

    static func image(for artwork: String?) -> NSImage? {
        guard let artwork, catalog.contains(artwork) else { return nil }
        if let hit = cache[artwork] { return hit }
        guard let url = Bundle.module.url(forResource: "bot-\(artwork)", withExtension: "webp", subdirectory: "bots"),
              let image = thumbnail(at: url) else { return nil }
        cache[artwork] = image
        return image
    }

    /// Décode l'image directement à la taille voulue, sans jamais matérialiser l'original.
    static func thumbnail(at url: URL, maxPixels: Int = thumbnailPixels) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = thumbnail(source: source, maxPixels: maxPixels) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated static func thumbnail(source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Ce que `BotFace` (console, `bot-face.tsx`) montre pour un bot, décidé sans rien dessiner :
/// une image importée (`/api/attachments/:id`, chargée avec la session), un artwork du catalogue,
/// un visage bloub. Un bot sans visage reçoit l'artwork tiré de son identifiant ; un artwork
/// inconnu laisse la place au visage bloub de sa fiche, comme dans la console.
enum AvatarSource: Equatable, Sendable {
    case uploaded(path: String)
    case artwork(String)
    case bloub(BotFace)

    static func resolve(seed: String, face: BotFace?) -> AvatarSource {
        if let artwork = face?.artwork, artwork.hasPrefix("/api/") { return .uploaded(path: artwork) }
        if let artwork = face?.artwork, Avatars.catalog.contains(artwork) { return .artwork(artwork) }
        guard let face else { return .artwork(OpenedbotMapping.defaultArtwork(for: seed)) }
        return .bloub(face)
    }

    /// Une image importée qui ne se charge pas : le visage bloub décrit par la même fiche.
    static func uploadFallback(_ face: BotFace?) -> BotFace {
        var drawn = face ?? BotFace()
        drawn.artwork = nil
        return drawn
    }
}

extension Bot {
    /// Le visage à montrer : celui de l'API ; en démo, `artwork` porte l'illustration et `face` est vide.
    var avatarFace: BotFace? { face ?? artwork.map { BotFace(artwork: $0) } }
}

/// L'avatar d'un bot : son visage, résolu comme dans la console.
struct AvatarView: View {
    let bot: Bot
    var size: CGFloat

    var body: some View {
        FaceView(seed: bot.id, name: bot.name, face: bot.avatarFace, size: size)
    }

    /// Le même avatar figé en image, pour un `NSMenuItem`. Une image importée pas encore en cache
    /// part en chargement : le menu, refait à chaque ouverture, la montrera la fois suivante.
    static func menuImage(for bot: Bot, size: CGFloat = 16) -> NSImage? {
        if case .uploaded(let path) = AvatarSource.resolve(seed: bot.id, face: bot.avatarFace) {
            RemoteImages.shared.load(path, maxPixels: Avatars.thumbnailPixels)
        }
        let renderer = ImageRenderer(content: AvatarView(bot: bot, size: size))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }
}
