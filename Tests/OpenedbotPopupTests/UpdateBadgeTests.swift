import Foundation
import Testing
@testable import OpenedbotPopup

/// La mise à jour annoncée par l'hôte : le message `updateState`, ce qu'il montre, le point de l'île
/// compacte, la ligne du panneau et son geste vers la console.
@Suite(.french)
struct UpdateStateProtocolTests {
    @Test func validLinesParse() {
        #expect(HostProtocol.parse(#"{"type":"updateState","status":"ready","version":"1.0.4"}"#)
            == .success(.updateState(status: "ready", version: "1.0.4")))
        // Version nulle ou absente : inconnue. Un champ en plus : ignoré.
        #expect(HostProtocol.parse(#"{"type":"updateState","status":"required","version":null}"#)
            == .success(.updateState(status: "required", version: nil)))
        #expect(HostProtocol.parse(#"{"type":"updateState","status":"idle","extra":{"a":1}}"#)
            == .success(.updateState(status: "idle", version: nil)))
        #expect(HostProtocol.parse(#"{"type":"updateState","status":"downloading","version":"10.20.300"}"#)
            == .success(.updateState(status: "downloading", version: "10.20.300")))
        // Un mot qu'un hôte plus récent enverrait : accepté tel quel (c'est le modèle qui n'en montre rien).
        #expect(HostProtocol.parse(#"{"type":"updateState","status":"rebooting"}"#)
            == .success(.updateState(status: "rebooting", version: nil)))
        let longest = String(repeating: "a", count: 32), version = String(repeating: "1", count: 32)
        #expect(HostProtocol.parse(#"{"type":"updateState","status":"\#(longest)","version":"\#(version)"}"#)
            == .success(.updateState(status: longest, version: version)))
    }

    @Test func malformedLinesAreRefused() {
        let refused = [
            #"{"type":"updateState"}"#,                                    // pas de statut
            #"{"type":"updateState","status":null}"#,
            #"{"type":"updateState","status":""}"#,
            #"{"type":"updateState","status":3}"#,
            #"{"type":"updateState","status":"Ready"}"#,                   // [a-z] seulement
            #"{"type":"updateState","status":"ready now"}"#,
            #"{"type":"updateState","status":"prête"}"#,
            #"{"type":"updateState","status":"\#(String(repeating: "a", count: 33))"}"#,
            #"{"type":"updateState","status":"ready","version":"1.0.4-beta.1"}"#, // chiffres et points seulement
            #"{"type":"updateState","status":"ready","version":"v1.0.4"}"#,
            #"{"type":"updateState","status":"ready","version":""}"#,
            #"{"type":"updateState","status":"ready","version":104}"#,
            #"{"type":"updateState","status":"ready","version":true}"#,
            #"{"type":"updateState","status":"ready","version":"\#(String(repeating: "1", count: 33))"}"#,
        ]
        for line in refused {
            #expect(HostProtocol.parse(line) == .failure(.invalidFields), "\(line)")
        }
    }

    @Test func theProtocolStaysVersionOne() {
        #expect(HostProtocol.version == 1)
    }
}

@Suite(.french)
struct HostUpdateTests {
    @Test func onlyReadyAndRequiredAreShown() {
        let shown: [String: HostUpdate.Badge?] = [
            "idle": nil, "checking": nil, "available": nil, "downloading": nil, "ready": .ready,
            "installing": nil, "error": nil, "required": .required, "rebooting": nil,
        ]
        for (word, badge) in shown {
            #expect(HostUpdate(status: word, version: "1.0.4").badge == badge, "\(word)")
        }
        #expect(HostUpdate(status: "rebooting", version: nil).status == .unknown)
        #expect(HostUpdate.none.badge == nil && HostUpdate.none.title == nil && HostUpdate.none.subtitle == nil)
    }

    @Test func titlesAndSubtitles() {
        let ready = HostUpdate(status: "ready", version: "1.0.4")
        #expect(ready.title == "Mise à jour prête")
        #expect(ready.subtitle == "openedbot 1.0.4")
        // Prête, version inconnue : pas de sous-titre.
        #expect(HostUpdate(status: "ready", version: nil).subtitle == nil)
        let required = HostUpdate(status: "required", version: nil)
        #expect(required.title == "Mise à jour requise")
        #expect(required.subtitle == "Ouvrez openedbot pour l'installer")
        #expect(HostUpdate(status: "required", version: "1.1.0").subtitle == "Ouvrez openedbot pour l'installer")
        Language.$override.withValue(.en) {
            #expect(HostUpdate.Badge.ready.title == "Update ready")
            #expect(HostUpdate.Badge.required.title == "Update required")
            #expect(required.subtitle == "Open openedbot to install it")
        }
    }

    @Test func theConsolePathIsTheUpdatesSettings() {
        #expect(HostUpdate.consolePath == "/settings/updates")
    }
}

@Suite(.french)
@MainActor
struct UpdateIslandTests {
    private func bot(_ id: String, running: Bool = false) -> Bot {
        var b = Bot(id: id, name: id.capitalized,
                    runtime: BotRuntime(name: "gpu-box", model: "m", mode: "auto", connected: true,
                                        lastSeenAt: Date(), connectorVersion: "0.5.7"))
        if running {
            b.runs = [BotRun(id: "\(id)-run", kind: .dm, title: "Commande", detail: "", status: .running,
                             usedSteps: 1, maxSteps: 8, tokens: 0, since: Date())]
        }
        return b
    }

    @Test func theDotShowsAtRestAndAtWork() {
        let resting = Island.compact(bots: [bot("a"), bot("b")], update: .ready)
        #expect(resting?.idle == true && resting?.update == .ready)
        let busy = Island.compact(bots: [bot("a", running: true)], update: .required)
        #expect(busy?.idle == false && busy?.update == .required)
        let unread = Island.compact(bots: [bot("a")], unread: 2, latestUnreadBotID: "a", update: .ready)
        #expect(unread?.update == .ready)
        #expect(Island.compact(bots: [bot("a")])?.update == nil)
        // Sans bot connu (hébergée, déconnectée) : l'île se montre pour la mise à jour, rien sans elle.
        #expect(Island.compact(bots: [], update: .required)?.update == .required)
        #expect(Island.compact(bots: []) == nil)
    }

    @Test func theCompactIslandCarriesTheDotOnlyForReadyOrRequired() {
        for word in ["idle", "checking", "available", "downloading", "ready", "installing", "error", "required", "rebooting"] {
            let model = NotchModel()
            model.update = HostUpdate(status: word, version: "1.0.4")
            let compact = Island.compact(bots: [bot("a")], update: model.update.badge)
            #expect((compact?.update != nil) == (word == "ready" || word == "required"), "\(word)")
        }
    }

    @Test func theWingMakesRoomForTheDot() {
        // Le côté droit l'emporte : le point ajoute sa largeur et un espace.
        let crowd = Island.Compact(botIDs: ["a"], extra: 0, working: 5, waiting: 2, unread: 3, total: 10, yolo: true)
        var dotted = crowd
        dotted.update = .ready
        let without = Island.sideWidth(compact: crowd, flash: nil, cameraHeight: 32)
        #expect(Island.sideWidth(compact: dotted, flash: nil, cameraHeight: 32) == without + Island.updateDotSize + 7)
        // Au repos aussi (« 1 bot » à droite) : la largeur suit.
        let rest = Island.compact(bots: [bot("a")])
        let restDotted = Island.compact(bots: [bot("a")], update: .ready)
        #expect(Island.sideWidth(compact: restDotted, flash: nil, cameraHeight: 32)
            == Island.sideWidth(compact: rest, flash: nil, cameraHeight: 32) + Island.updateDotSize + 7)
        // Dix bots au repos : les avatars et « +7 » à gauche restent plus larges, le point tient sans élargir.
        let ten = (0..<10).map { bot("b\($0)") }
        #expect(Island.sideWidth(compact: Island.compact(bots: ten, update: .ready), flash: nil, cameraHeight: 32)
            >= Island.sideWidth(compact: Island.compact(bots: ten), flash: nil, cameraHeight: 32))
    }
}

@Suite(.french) @MainActor
struct HostUpdateChannelTests {
    final class Recorder {
        var updates: [HostUpdate] = []
    }

    private func harness() -> (HostTokenSourceTests.Harness, Recorder) {
        let h = HostTokenSourceTests.Harness()
        let r = Recorder()
        h.source.onUpdate = { [r] in r.updates.append($0) }
        return (h, r)
    }

    @Test func theStateReachesTheModelAndSurvivesSignOut() async {
        let (h, r) = harness()
        await h.signIn()
        h.host.write(#"{"type":"updateState","status":"downloading","version":"1.0.4"}"#)
        h.host.write(#"{"type":"updateState","status":"ready","version":"1.0.4"}"#)
        await waitUntil { r.updates.count == 2 }
        #expect(r.updates.map(\.badge) == [nil, .ready])
        #expect(r.updates.last == HostUpdate(status: .ready, version: "1.0.4"))
        // La session tombe : la mise à jour concerne l'app, elle reste.
        h.host.write(#"{"type":"signedOut"}"#)
        await waitUntil { !h.source.isSignedIn }
        #expect(r.updates.count == 2)
        // Juste avant d'installer, l'hôte dit `installing` : le point s'efface.
        h.host.write(#"{"type":"updateState","status":"installing","version":"1.0.4"}"#)
        await waitUntil { r.updates.count == 3 }
        #expect(r.updates.last?.badge == nil)
    }

    @Test func endOfStdinClearsTheState() async {
        let (h, r) = harness()
        await h.signIn()
        h.host.write(#"{"type":"updateState","status":"required","version":null}"#)
        await waitUntil { r.updates.count == 1 }
        #expect(r.updates.last?.badge == .required)
        h.host.close()
        await waitUntil { h.eofs == 1 }
        #expect(r.updates.last == HostUpdate.none)
    }

    @Test func badOrUnknownLinesAreIgnoredWithoutFatal() async {
        let (h, r) = harness()
        await h.signIn()
        h.host.write(#"{"type":"updateState","status":"ready","version":"1.0.4"}"#)
        // Un type que cette popup ne connaît pas, et un updateState mal formé : ignorés, rien ne change.
        h.host.write(#"{"type":"updateProgress","percent":40}"#)
        h.host.write(#"{"type":"updateState","status":"ready","version":"1.0.5-rc"}"#)
        h.host.write(#"{"type":"updateState","status":"rebooting"}"#)
        await waitUntil { r.updates.count == 2 }
        #expect(r.updates.map(\.badge) == [.ready, nil])
        #expect(r.updates.last?.status == .unknown)
        #expect(h.fatal == nil)
        #expect(h.source.isReady && h.source.isSignedIn)
        #expect(!h.host.received.contains { $0["type"] as? String == "fatal" })
    }

    @Test func theRowAsksTheHostToOpenTheUpdatesSettings() async {
        let (h, _) = harness()
        await h.signIn()
        // Ce que fait la ligne du panneau (NotchWindowController → onOpenConsole → HostTokenSource).
        h.source.openConsole(path: HostUpdate.consolePath)
        await waitUntil { h.host.received.count == 1 }
        #expect(h.host.received.first?["type"] as? String == "openConsole")
        #expect(h.host.received.first?["path"] as? String == "/settings/updates")
        #expect(h.host.received.first?.count == 2) // rien d'autre ne part
    }
}
