import AppKit
import Foundation
import Testing
@testable import OpenedbotPopup

// L'avatar d'un bot dans l'encoche est celui de la console : même artwork, même image importée, même
// visage bloub. Régression du 2026-11-06 : Rafale, Brume et Sillage (artworks ember, crystal, ocean)
// tombaient sur leur visage bloub parce que ces artworks n'étaient pas embarqués.

@MainActor
@Suite(.french)
struct AvatarSourceTests {
    @Test func everyConsoleArtworkIsBundledAndDecodes() {
        // `BOT_ARTWORKS` de la console : 30 artworks tirés au hasard + 3 portraits.
        #expect(Avatars.catalog.count == 33)
        for id in Avatars.catalog {
            #expect(Avatars.image(for: id) != nil, "artwork \(id) absent du bundle")
        }
    }

    @Test func aCatalogArtworkWinsOverTheVectorFaceStoredBesideIt() {
        // Les fiches réelles de la démo acme : l'artwork choisi, et les axes bloub qui l'accompagnent.
        let rafale = BotFace(artwork: "ember", palette: "bleu", shape: "triangle", eyes: "confus")
        let brume = BotFace(artwork: "crystal", palette: "turquoise", shape: "goutte", eyes: "fier")
        let sillage = BotFace(artwork: "ocean", palette: "rose", shape: "squircle", eyes: "confus")
        #expect(AvatarSource.resolve(seed: "93c251d3", face: rafale) == .artwork("ember"))
        #expect(AvatarSource.resolve(seed: "115c5e96", face: brume) == .artwork("crystal"))
        #expect(AvatarSource.resolve(seed: "a3bf72cb", face: sillage) == .artwork("ocean"))
        #expect(AvatarSource.resolve(seed: "x", face: BotFace(artwork: "selene")) == .artwork("selene"))
    }

    @Test func noFaceTakesTheArtworkDerivedFromTheID() {
        #expect(AvatarSource.resolve(seed: "b-7f3e", face: nil) == .artwork("aurora"))
        #expect(AvatarSource.resolve(seed: "support", face: nil) == .artwork(OpenedbotMapping.defaultArtwork(for: "support")))
    }

    @Test func anUploadedImageIsFetchedWithTheSession() {
        let face = BotFace(artwork: "/api/attachments/att-1", palette: "rose", shape: "galet", eyes: "fier")
        #expect(AvatarSource.resolve(seed: "b", face: face) == .uploaded(path: "/api/attachments/att-1"))
        // S'il ne se charge pas : le visage bloub de la même fiche, sans l'image.
        #expect(AvatarSource.uploadFallback(face) == BotFace(artwork: nil, palette: "rose", shape: "galet", eyes: "fier"))
        #expect(AvatarSource.uploadFallback(nil) == BotFace())
    }

    @Test func aVectorFaceOrAnUnknownArtworkDrawsTheBloubFace() {
        let vector = BotFace(artwork: nil, palette: "ambre", shape: "triangle", eyes: "mefiant")
        #expect(AvatarSource.resolve(seed: "b", face: vector) == .bloub(vector))
        let unknown = BotFace(artwork: "retired-art", palette: "vert")
        #expect(AvatarSource.resolve(seed: "b", face: unknown) == .bloub(unknown))
        let empty = BotFace(artwork: "")
        #expect(AvatarSource.resolve(seed: "b", face: empty) == .bloub(empty))
        // Un identifiant hors catalogue n'atteint jamais le bundle.
        #expect(Avatars.image(for: "../faces/catalog") == nil)
    }

    @Test func demoBotsKeepTheirArtwork() {
        for bot in MockBotFeed.roster(now: Date()) {
            #expect(AvatarSource.resolve(seed: bot.id, face: bot.avatarFace) == .artwork(bot.artwork!))
        }
    }

    @Test func theMenuIconIsTheSameAvatarRendered() {
        let bot = Bot(id: "93c251d3", name: "Rafale", artwork: "ember", runtime: MockBotFeed.roster(now: Date())[0].runtime,
                      face: BotFace(artwork: "ember", palette: "bleu", shape: "triangle", eyes: "confus"))
        let icon = AvatarView.menuImage(for: bot)
        #expect(icon?.size == NSSize(width: 16, height: 16))
    }
}

@MainActor
@Suite(.french)
struct RemoteImagesTests {
    /// Un PNG carré plein, à la taille d'un avatar importé.
    private static func png(_ pixels: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func settle(_ done: @escaping @MainActor () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private final class Calls { var paths: [String] = [] }

    @Test func anAvatarIsFetchedOnceAndDecodedSmall() async {
        let images = RemoteImages()
        let calls = Calls()
        let data = Self.png(1024)
        images.loader = { path in calls.paths.append(path); return data }
        images.load("/api/attachments/a", maxPixels: Avatars.thumbnailPixels)
        images.load("/api/attachments/a", maxPixels: Avatars.thumbnailPixels) // en vol : pas de second appel
        await settle { images.image("/api/attachments/a", maxPixels: Avatars.thumbnailPixels) != nil }
        let image = images.image("/api/attachments/a", maxPixels: Avatars.thumbnailPixels)
        #expect(image != nil)
        // La vignette porte sa taille en pixels (`NSImage(cgImage:size:)`) : 1024 → 128.
        #expect(image?.size == NSSize(width: Avatars.thumbnailPixels, height: Avatars.thumbnailPixels))
        images.load("/api/attachments/a", maxPixels: Avatars.thumbnailPixels) // en cache
        #expect(calls.paths == ["/api/attachments/a"])
        // L'image entière (pièce jointe) est une autre entrée.
        #expect(images.image("/api/attachments/a") == nil)
    }

    @Test func aNewAvatarPathIsANewFetch() async {
        let images = RemoteImages()
        let calls = Calls()
        let data = Self.png(64)
        images.loader = { path in calls.paths.append(path); return data }
        images.load("/api/attachments/old", maxPixels: 128)
        await settle { images.image("/api/attachments/old", maxPixels: 128) != nil }
        images.load("/api/attachments/new", maxPixels: 128)
        await settle { images.image("/api/attachments/new", maxPixels: 128) != nil }
        #expect(calls.paths == ["/api/attachments/old", "/api/attachments/new"])
    }

    @Test func aFailedFetchFallsBackThenRetriesLater() async {
        let images = RemoteImages()
        let calls = Calls()
        var clock = Date(timeIntervalSince1970: 1_000)
        images.now = { clock }
        var fail = true
        let data = Self.png(64)
        images.loader = { path in
            calls.paths.append(path)
            if fail { throw OpenedbotAuthError.http(status: 503, code: nil) }
            return data
        }
        images.load("/api/attachments/x", maxPixels: 128)
        await settle { images.failed("/api/attachments/x", maxPixels: 128) }
        #expect(images.failed("/api/attachments/x", maxPixels: 128))
        #expect(images.image("/api/attachments/x", maxPixels: 128) == nil)
        // Trop tôt : pas de nouvel appel.
        clock = clock.addingTimeInterval(RemoteImages.retryAfter - 1)
        images.load("/api/attachments/x", maxPixels: 128)
        #expect(calls.paths.count == 1)
        // Le délai passé, l'API répond : l'image remplace le repli.
        fail = false
        clock = clock.addingTimeInterval(2)
        images.load("/api/attachments/x", maxPixels: 128)
        await settle { images.image("/api/attachments/x", maxPixels: 128) != nil }
        #expect(calls.paths.count == 2)
        #expect(images.image("/api/attachments/x", maxPixels: 128) != nil)
        #expect(!images.failed("/api/attachments/x", maxPixels: 128))
    }

    @Test func undecodableBytesCountAsAFailure() async {
        let images = RemoteImages()
        images.loader = { _ in Data("<html>not an image</html>".utf8) }
        images.load("/api/attachments/html", maxPixels: 128)
        await settle { images.failed("/api/attachments/html", maxPixels: 128) }
        #expect(images.failed("/api/attachments/html", maxPixels: 128))
    }

    @Test func aResetDropsAnAnswerForThePreviousSession() async {
        let images = RemoteImages()
        let gate = AsyncStream<Void>.makeStream()
        let data = Self.png(64)
        images.loader = { _ in
            for await _ in gate.stream { break }
            return data
        }
        images.load("/api/attachments/org-a", maxPixels: 128)
        images.reset() // changement d'organisation pendant le chargement
        gate.continuation.yield()
        gate.continuation.finish()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(images.image("/api/attachments/org-a", maxPixels: 128) == nil)
        #expect(!images.failed("/api/attachments/org-a", maxPixels: 128))
    }

    @Test func withoutALoaderNothingLoads() {
        let images = RemoteImages()
        images.load("/api/attachments/demo", maxPixels: 128)
        #expect(images.image("/api/attachments/demo", maxPixels: 128) == nil)
        #expect(!images.failed("/api/attachments/demo", maxPixels: 128))
    }
}
