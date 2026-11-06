import AppKit
import Foundation
import Testing
@testable import OpenedbotPopup

/// La démonstration de la première connexion : deux bots fictifs, un accord qui déplie l'île, un
/// arrêt à la fin du cycle quand l'utilisateur l'a touchée, et rien d'autre que le modèle local.
@MainActor
@Suite(.french)
struct DemoFeedTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<20_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test func aCycleRunsTwoBotsThroughAnApprovalAndEnds() async {
        let model = NotchModel()
        let feed = DemoBotFeed(model: model, timeScale: 0, answerTimeout: .zero)
        var ended = 0
        var sawWaitingExpanded = false
        var folded = 0
        feed.onEnded = { ended += 1 }
        feed.fold = { folded += 1; model.isExpanded = false }
        feed.start(cycles: 1)
        #expect(model.bots.map(\.name) == ["Recherche", "Rédaction"])
        #expect(model.bots.allSatisfy { $0.activity == .working })
        #expect(Island.compact(bots: model.bots)?.working == 2)
        await waitUntil {
            if model.bot(DemoBotFeed.writingID)?.activity == .waiting, model.isExpanded { sawWaitingExpanded = true }
            return ended > 0
        }
        #expect(sawWaitingExpanded, "the approval unfolds the island by itself")
        #expect(ended == 1)
        #expect(folded == 1)
        #expect(!feed.isPlaying)
        // La dernière image reste : les deux runs ont fini, rien n'attend.
        #expect(model.bots.allSatisfy { $0.activity == .success && $0.pending == nil })
        #expect(model.bot(DemoBotFeed.writingID)?.thread.contains { $0.text == "Autorisé une fois (démo)" } == true)
        // Aucune annonce : pas de bannière, pas de son, pas de notification.
        #expect(model.inbox.unreadCount == 0)
    }

    @Test func itLoopsUntilTheUserTouchesItThenStopsAtTheEndOfTheCycle() async {
        let model = NotchModel()
        let feed = DemoBotFeed(model: model, timeScale: 0, answerTimeout: .seconds(60))
        var ended = 0
        feed.onEnded = { ended += 1 }
        feed.start(cycles: 0)
        await waitUntil { model.bot(DemoBotFeed.writingID)?.pending != nil }
        let approval = try! #require(model.bot(DemoBotFeed.writingID)?.pending)
        // La réponse reste locale et compte comme un geste : la démo finit ce cycle puis s'arrête.
        feed.respond(approvalID: approval.id, allow: false)
        #expect(feed.touched)
        #expect(model.bot(DemoBotFeed.writingID)?.pending == nil)
        await waitUntil { ended > 0 }
        #expect(ended == 1)
        #expect(feed.completedCycles == 1)
        let writing = try! #require(model.bot(DemoBotFeed.writingID))
        #expect(writing.thread.contains { $0.text == "Refusé (démo)" })
        // Refusé : rien n'est publié.
        #expect(!writing.thread.contains { $0.text == "Publication" })
        #expect(writing.runs.first?.detail == "Gardé en brouillon")
    }

    @Test func aLanguageChangeKeepsTheCycleLimitAndTheTouch() async {
        let model = NotchModel()
        let replay = DemoBotFeed(model: model, timeScale: 0, answerTimeout: .zero)
        var ended = 0
        replay.onEnded = { ended += 1 }
        replay.start(cycles: 2)
        replay.relocalize()
        await waitUntil { ended > 0 }
        #expect(ended == 1, "a replay still stops by itself")
        #expect(replay.completedCycles == 2)

        let firstRun = DemoBotFeed(model: model, timeScale: 0, answerTimeout: .seconds(60))
        var firstEnded = 0
        firstRun.onEnded = { firstEnded += 1 }
        firstRun.start(cycles: 0)
        firstRun.userInteracted()
        firstRun.relocalize()
        #expect(firstRun.touched)
        await waitUntil { model.bot(DemoBotFeed.writingID)?.pending != nil }
        if let approval = model.bot(DemoBotFeed.writingID)?.pending { firstRun.respond(approvalID: approval.id, allow: true) }
        await waitUntil { firstEnded > 0 }
        #expect(firstEnded == 1)
        #expect(firstRun.completedCycles == 1)
    }

    @Test func untouchedItKeepsLoopingAndStopsWhenAsked() async {
        let model = NotchModel()
        let feed = DemoBotFeed(model: model, timeScale: 0, answerTimeout: .zero)
        var ended = 0
        feed.onEnded = { ended += 1 }
        feed.start(cycles: 0)
        await waitUntil { feed.completedCycles >= 3 }
        #expect(feed.completedCycles >= 3)
        #expect(ended == 0, "no end without a touch")
        feed.userInteracted()
        await waitUntil { ended > 0 }
        #expect(ended == 1)
        feed.stop()
    }

    @Test func aReplayStopsByItselfAfterItsCycles() async {
        let model = NotchModel()
        let feed = DemoBotFeed(model: model, timeScale: 0, answerTimeout: .zero)
        var ended = 0
        feed.onEnded = { ended += 1 }
        feed.start(cycles: 2)
        await waitUntil { ended > 0 }
        #expect(feed.completedCycles == 2)
        #expect(!feed.touched)
    }

    @Test func onlyTheFictionalBotsHaveNoConsolePage() {
        #expect(DemoBotFeed.isFictional(path: AppDelegate.consolePath(botID: DemoBotFeed.writingID)))
        #expect(DemoBotFeed.isFictional(path: AppDelegate.consolePath(botID: DemoBotFeed.researchID)))
        #expect(!DemoBotFeed.isFictional(path: AppDelegate.consolePath(botID: "b1")))
        // La page des mises à jour et la console restent ouvrables pendant la démonstration.
        #expect(!DemoBotFeed.isFictional(path: HostUpdate.consolePath))
        #expect(!DemoBotFeed.isFictional(path: "/"))
    }

    @Test func theHostDrivesTheDemo() {
        var sent: [HostProtocol.Outgoing] = []
        let host = HostTokenSource(send: { sent.append($0); return true })
        var demos: [Int] = []
        var ends = 0
        host.onDemo = { demos.append($0) }
        host.onEndDemo = { ends += 1 }
        host.receive(line: #"{"type":"demo","cycles":0}"#)
        host.receive(line: #"{"type":"demo","cycles":2}"#)
        host.receive(line: #"{"type":"endDemo"}"#)
        #expect(demos == [0, 2])
        #expect(ends == 1)
        host.demoEnded()
        #expect(sent == [.demoEnded])
    }
}

/// Où l'encoche se pose, et quand elle se replace.
@MainActor
@Suite
struct NotchPlacementTriggerTests {
    @Test func theCameraScreenWinsOverTheMainOne() {
        // L'écran intégré ouvert (avec la caméra) en deuxième position, l'externe principal : l'intégré.
        #expect(NotchWindowController.cameraScreenIndex(hasCamera: [false, true], main: 0) == 1)
        // Capot fermé : plus d'écran à caméra, l'écran principal.
        #expect(NotchWindowController.cameraScreenIndex(hasCamera: [false, false], main: 1) == 1)
        #expect(NotchWindowController.cameraScreenIndex(hasCamera: [false], main: nil) == 0)
        #expect(NotchWindowController.cameraScreenIndex(hasCamera: [], main: nil) == nil)
    }

    @Test func wakingUpReplacesTheNotch() {
        let app = NotificationCenter()
        let workspace = NotificationCenter()
        var rebuilds = 0
        let triggers = PlacementTriggers(app: app, workspace: workspace) { rebuilds += 1 }
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(rebuilds == 1)
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        app.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #expect(rebuilds == 3)
        triggers.stop()
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(rebuilds == 3, "nothing after stop")
    }

    @Test func theHostedNotchDefaultsToTheIsland() {
        let fresh = TestSupport.defaults("edge-fresh")
        LaunchMode.seed(fresh, from: [:])
        LaunchMode.defaultHostedEdge(fresh)
        #expect(fresh.string(forKey: LaunchMode.edgeKey) == NotchEdge.top.rawValue)
        let model = NotchModel()
        model.load(from: fresh)
        #expect(model.edge == .top)
        // Un bord repris de l'autonome, ou déjà choisi, reste.
        let seeded = TestSupport.defaults("edge-seeded")
        LaunchMode.seed(seeded, from: ["notch.edge": "right"])
        LaunchMode.defaultHostedEdge(seeded)
        #expect(seeded.string(forKey: LaunchMode.edgeKey) == "right")
    }

    @Test func theDemoPlacesTheIslandWithoutSavingIt() {
        let defaults = TestSupport.defaults("edge-override")
        let model = NotchModel()
        model.load(from: defaults)
        model.edge = .right
        model.alongOffset = 40
        model.edgeOverride = .top
        #expect(model.placedEdge == .top)
        #expect(model.alongOffset == 0, "the island's own offset, not the right edge's")
        #expect(defaults.string(forKey: "notch.edge") == "right", "the override is never saved")
        model.edgeOverride = nil
        #expect(model.placedEdge == .right)
        #expect(model.alongOffset == 40)
    }
}
