import Foundation
import Testing
@testable import OHBPopup

/// Les baux YOLO : lecture tolérante, bail montré, compte à rebours, sondage et coupure.
@Suite(.french)
struct YoloParsingTests {
    private func decode(_ json: String) throws -> [YoloLease] {
        try OHBotAuthClient.decoder.decode(YoloLeasesDto.self, from: Data(json.utf8)).leases
    }

    @Test func readsTheDocumentedShape() throws {
        let leases = try decode("""
        {"leases":[{"leaseId":"l1","scope":"thread","botId":"b1","threadId":"t1","runtimeId":"rt","expiresAt":"2026-11-02T10:00:00.250Z","signature":"x"},
                   {"leaseId":"l2","scope":"runtime","runtimeId":"rt","expiresAt":"2026-11-02T10:00:00Z"}]}
        """)
        #expect(leases.map(\.id) == ["l1", "l2"])
        #expect(leases[0].scope == .thread && leases[0].botID == "b1" && leases[0].threadID == "t1" && leases[0].runtimeID == "rt")
        #expect(abs((leases[0].expiresAt?.timeIntervalSince1970 ?? 0) - 1_793_613_600.25) < 0.001)
        #expect(leases[1].scope == .runtime && leases[1].botID == nil)
        #expect(leases[1].expiresAt == Date(timeIntervalSince1970: 1_793_613_600))
    }

    @Test func expiresAtAcceptsIsoOffsetsAndEpochsInSecondsOrMilliseconds() throws {
        let leases = try decode("""
        [{"leaseId":"s","expiresAt":1793613600},{"leaseId":"ms","expiresAt":1793613600000},
         {"leaseId":"str","expiresAt":"1793613600"},{"leaseId":"off","expiresAt":"2026-11-02T11:00:00+01:00"},
         {"leaseId":"frac","expiresAt":1793613600.5}]
        """)
        let at = Date(timeIntervalSince1970: 1_793_613_600)
        #expect(leases.map(\.expiresAt) == [at, at, at, at, at.addingTimeInterval(0.5)])
    }

    @Test func toleratesMissingFieldsUnknownScopesAndBadElements() throws {
        let leases = try decode("""
        {"items":[{"id":"x","scope":"ORGANIZATION","expiresAt":"demain"},{"scope":"bot","expiresAt":null},42,"nope",{"leaseId":"ok","scope":"Bot"}]}
        """)
        #expect(leases.map(\.id) == ["x", "", "ok"]) // 42 et "nope" sautés, pas toute la réponse
        #expect(leases[0].scope == .unknown && leases[0].expiresAt == nil) // échéance illisible : nil, le bail compte
        #expect(leases[1].scope == .bot && leases[1].expiresAt == nil)
        #expect(leases[2].scope == .bot)
        #expect(try decode(#"{"leases":null}"#).isEmpty)
        #expect(try decode("[]").isEmpty)
        #expect(throws: DecodingError.self) { try decode(#"{"other":[]}"#) }
    }
}

@Suite(.french)
struct YoloDisplayTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func lease(_ id: String, _ scope: YoloLease.Scope = .bot, in seconds: TimeInterval?) -> YoloLease {
        YoloLease(id: id, scope: scope, botID: nil, threadID: nil, runtimeID: nil, expiresAt: seconds.map { now.addingTimeInterval($0) })
    }

    @Test func showsTheLeaseThatEndsLastAmongActiveOnes() {
        let leases = [lease("a", in: 60), lease("b", in: 600), lease("old", in: -1), lease("edge", in: 0)]
        #expect(Yolo.displayed(leases, now: now)?.id == "b")
        #expect(Yolo.displayed([lease("old", in: -5), lease("edge", in: 0)], now: now) == nil) // échu à l'instant : plus actif
        #expect(Yolo.displayed([], now: now) == nil)
        #expect(YoloState(leases: leases).active(at: now).map(\.id) == ["a", "b"])
        #expect(!YoloState(leases: [lease("old", in: -1)]).isActive(at: now))
    }

    @Test func aLeaseWithoutDeadlineWinsThenTheBroadestScope() {
        #expect(Yolo.displayed([lease("timed", in: 9999), lease("open", in: nil)], now: now)?.id == "open")
        let tie = [lease("t", .thread, in: 60), lease("r", .runtime, in: 60), lease("b", .bot, in: 60)]
        #expect(Yolo.displayed(tie, now: now)?.id == "r")
        #expect(Yolo.displayed([lease("z", in: 60), lease("a", in: 60)], now: now)?.id == "a") // stable
    }

    @Test func countdownFormat() {
        func text(_ s: TimeInterval) -> String { Yolo.countdown(until: now.addingTimeInterval(s), now: now) }
        #expect(text(0) == "0:00")
        #expect(text(-30) == "0:00")
        #expect(text(0.2) == "0:01") // arrondi vers le haut : jamais 0:00 avant l'échéance
        #expect(text(59) == "0:59")
        #expect(text(65) == "1:05")
        #expect(text(3599) == "59:59")
        #expect(text(3600) == "1:00:00")
        #expect(text(90_061) == "25:01:01")
    }

    @Test func scopeAndCountCopy() {
        #expect(Yolo.scopeText(lease("r", .runtime, in: 1), botName: "Ops") == "tout le runtime")
        #expect(Yolo.scopeText(lease("b", .bot, in: 1), botName: "Ops") == "Ops")
        #expect(Yolo.scopeText(lease("b", .bot, in: 1), botName: nil) == "un bot")
        #expect(Yolo.scopeText(lease("t", .thread, in: 1), botName: "Ops") == "un fil de Ops")
        #expect(Yolo.leaseCount(1) == "1 bail actif" && Yolo.leaseCount(3) == "3 baux actifs")
    }

    @Test func compactIslandShowsYoloEvenWithoutBots() {
        #expect(Island.compact(bots: []) == nil)
        let c = Island.compact(bots: [], yolo: true)
        #expect(c?.yolo == true && c?.idle == true)
        let plain = Island.sideWidth(compact: Island.Compact(botIDs: [], extra: 0, working: 1, waiting: 0), flash: nil, cameraHeight: 32)
        let badged = Island.sideWidth(compact: Island.Compact(botIDs: [], extra: 0, working: 1, waiting: 0, yolo: true), flash: nil, cameraHeight: 32)
        #expect(badged > plain)
    }
}

/// Une source de jetons fixe : ni trousseau ni connexion.
@MainActor
final class FixedTokens: TokenSource {
    var origin: URL? = URL(string: "https://api.test")
    var isSignedIn = true
    var organizationId: String? = "org-1"
    func validToken() async throws -> BearerToken { BearerToken(accessToken: "at", organizationId: "org-1", expiresAt: .distantFuture) }
    func refreshedToken() async throws -> BearerToken { try await validToken() }
}

@Suite(.french) @MainActor
struct YoloMonitorTests {
    static let active = #"{"leases":[{"leaseId":"l1","scope":"bot","botId":"b1","runtimeId":"rt","expiresAt":"2099-01-01T00:00:00Z"}]}"#

    private func make() -> (YoloMonitor, NotchModel, StubTransport) {
        let model = NotchModel(), t = StubTransport()
        return (YoloMonitor(model: model, account: FixedTokens(), transport: t, poll: .seconds(30)), model, t)
    }

    @Test func refreshReadsLeasesWithTheOrganizationHeaderAndDropsExpiredOnes() async {
        let (m, model, t) = make()
        t.on(YoloMonitor.leasesPath, (200, #"{"leases":[{"leaseId":"l1","expiresAt":"2099-01-01T00:00:00Z"},{"leaseId":"gone","expiresAt":"2000-01-01T00:00:00Z"}]}"#))
        await m.refresh()
        #expect(model.yolo.leases.map(\.id) == ["l1"])
        let call = t.calls.first
        #expect(call?.method == "GET" && call?.headers["X-OHB-Organization"] == "org-1" && call?.headers["Authorization"] == "Bearer at")
    }

    @Test func aFailureKeepsKnownLeasesAnd404ClearsThem() async {
        let (m, model, t) = make()
        t.on(YoloMonitor.leasesPath, (200, Self.active), (500, "{}"), (404, #"{"error":{"code":"NOT_FOUND"}}"#))
        await m.refresh()
        await m.refresh()
        #expect(model.yolo.leases.map(\.id) == ["l1"]) // panne : YOLO reste affiché
        #expect(model.journal.entries.last?.level == .warning)
        await m.refresh()
        #expect(model.yolo.leases.isEmpty) // serveur sans YOLO
    }

    @Test func killPostsThenClearsAndRereads() async {
        let (m, model, t) = make()
        t.on(YoloMonitor.leasesPath, (200, Self.active), (200, #"{"leases":[]}"#))
        t.on(YoloMonitor.killPath, (200, #"{"killed":1}"#))
        await m.refresh()
        await m.killAll()
        #expect(model.yolo.leases.isEmpty && !model.yolo.killing && model.yolo.killError == nil)
        #expect(t.calls.map(\.method) == ["GET", "POST", "GET"])
        #expect(t.calls[1].path == YoloMonitor.killPath && t.calls[1].headers["X-OHB-Organization"] == "org-1")
    }

    @Test func aForbiddenKillSaysWhoMayAndKeepsYoloShown() async {
        let (m, model, t) = make()
        t.on(YoloMonitor.leasesPath, (200, Self.active))
        t.on(YoloMonitor.killPath, (403, #"{"error":{"code":"FORBIDDEN"}}"#))
        await m.refresh()
        await m.killAll()
        #expect(model.yolo.leases.map(\.id) == ["l1"])
        #expect(!model.yolo.killing)
        #expect(model.yolo.killError == "Seuls les propriétaires et administrateurs de l'organisation peuvent couper YOLO.")
        #expect(model.journal.entries.last?.level == .error)
    }

    @Test func aNetworkFailureOnKillIsReported() async {
        let (m, model, t) = make()
        t.on(YoloMonitor.leasesPath, (200, Self.active))
        await m.refresh()
        await m.killAll() // pas de réponse scriptée : hôte injoignable
        #expect(model.yolo.killError?.hasPrefix("Serveur injoignable") == true)
        #expect(model.yolo.leases.map(\.id) == ["l1"])
    }

    @Test func nextPollFollowsTheSoonestDeadlineWithinBounds() {
        let (m, model, _) = make()
        let now = Date()
        #expect(m.nextDelay(now: now) == .seconds(30))
        model.yolo.leases = [YoloLease(id: "a", scope: .bot, expiresAt: now.addingTimeInterval(10)),
                             YoloLease(id: "b", scope: .bot, expiresAt: now.addingTimeInterval(20))]
        #expect(m.nextDelay(now: now) == .milliseconds(10_500))
        model.yolo.leases = [YoloLease(id: "a", scope: .bot, expiresAt: now.addingTimeInterval(0.1))]
        #expect(m.nextDelay(now: now) == .seconds(1))
        model.yolo.leases = [YoloLease(id: "a", scope: .bot, expiresAt: now.addingTimeInterval(3600))]
        #expect(m.nextDelay(now: now) == .seconds(30))
    }

    /// Le premier GET répond en retard : il ne doit pas ressusciter les baux coupés entre-temps.
    final class SlowFirstGet: HTTPTransport, @unchecked Sendable {
        let inner: StubTransport
        private let lock = NSLock()
        private var slowed = false
        init(_ inner: StubTransport) { self.inner = inner }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let delay = request.httpMethod == "GET" && lock.withLock { defer { slowed = true }; return !slowed }
            let reply = try await inner.send(request)
            if delay { try await Task.sleep(for: .milliseconds(150)) }
            return reply
        }
    }

    @Test func aSlowRefreshDoesNotResurrectKilledLeases() async {
        let model = NotchModel(), t = StubTransport()
        t.on(YoloMonitor.leasesPath, (200, Self.active), (200, #"{"leases":[]}"#))
        t.on(YoloMonitor.killPath, (200, "{}"))
        let m = YoloMonitor(model: model, account: FixedTokens(), transport: SlowFirstGet(t))
        let slow = Task { await m.refresh() }
        await waitUntil { t.calls.count == 1 }
        await m.killAll()
        await slow.value
        #expect(model.yolo.leases.isEmpty)
    }

    @Test func stopClearsTheState() async {
        let (m, model, t) = make()
        t.on(YoloMonitor.leasesPath, (200, Self.active))
        await m.refresh()
        m.stop()
        #expect(model.yolo == YoloState())
    }
}
