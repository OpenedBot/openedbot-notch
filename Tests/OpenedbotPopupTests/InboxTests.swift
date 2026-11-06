import Foundation
import Testing
@testable import OpenedbotPopup

/// La boîte de notifications : priorités, file des bannières, lecture, absence, nouveaux messages.
@Suite(.french)
@MainActor
struct InboxTests {
    let now = Date()

    private func notice(_ kind: Notice.Kind, _ bot: String = "seo", at offset: TimeInterval = 0, approval: UUID? = nil) -> Notice {
        Notice(kind: kind, botID: bot, botName: bot.capitalized, text: "détail", at: now.addingTimeInterval(offset), approvalID: approval)
    }

    @Test func bannersComeMostUrgentFirstThenOldest() {
        var inbox = Inbox()
        inbox.add(notice(.finished, "a", at: 0))
        inbox.add(notice(.message, "b", at: 1))
        inbox.add(notice(.failed, "c", at: 2))
        inbox.add(notice(.approval, "d", at: 3, approval: UUID()))
        #expect(inbox.nextBanner()?.botID == "c")
        #expect(inbox.nextBanner()?.botID == "d")
        #expect(inbox.nextBanner()?.botID == "a")
        #expect(inbox.nextBanner()?.botID == "b")
        #expect(inbox.nextBanner() == nil)
        // Les bannières passées, tout reste non lu.
        #expect(inbox.unreadCount == 4)
    }

    @Test func runtimeBackIsRecordedReadWithoutBanner() {
        var inbox = Inbox()
        inbox.add(notice(.back))
        #expect(inbox.unreadCount == 0 && inbox.notices.count == 1 && inbox.nextBanner() == nil)
    }

    @Test func sameApprovalIsNotDoubled() {
        var inbox = Inbox()
        let id = UUID()
        inbox.add(notice(.approval, approval: id))
        inbox.add(notice(.approval, approval: id))
        #expect(inbox.notices.count == 1)
    }

    @Test func answeredApprovalIsReadAndLeavesTheQueue() {
        var inbox = Inbox()
        let id = UUID()
        inbox.add(notice(.approval, approval: id))
        inbox.resolveApproval(id)
        #expect(inbox.unreadCount == 0 && inbox.nextBanner() == nil)
    }

    @Test func boxKeepsTheFiftyMostRecent() {
        var inbox = Inbox()
        for i in 0..<60 { inbox.add(notice(.message, "b\(i)", at: Double(i))) }
        #expect(inbox.notices.count == Inbox.capacity)
        #expect(inbox.notices.first?.botID == "b59" && inbox.notices.last?.botID == "b10")
        #expect(inbox.queue.count == Inbox.capacity)
    }

    @Test func markAllReadClearsBadgeAndQueue() {
        var inbox = Inbox()
        inbox.add(notice(.message))
        inbox.add(notice(.finished))
        inbox.markAllRead()
        #expect(inbox.unreadCount == 0 && inbox.queue.isEmpty)
    }

    @Test func readNoticesGoAwayButOpenApprovalsStay() {
        var inbox = Inbox()
        let open = UUID()
        inbox.add(notice(.approval, "a", approval: open))
        inbox.add(notice(.message, "b"))
        inbox.add(notice(.message, "c"))
        inbox.add(notice(.back, "d"))
        inbox.markRead(inbox.notices.first { $0.botID == "a" }!.id)
        inbox.markRead(inbox.notices.first { $0.botID == "b" }!.id)
        inbox.removeRead(keepingApprovals: [open])
        // Le message lu et le retour du runtime (lu d'office) partent ; le message non lu et la
        // demande encore ouverte, même lue, restent.
        #expect(inbox.notices.map(\.botID) == ["c", "a"])
        #expect(Set(inbox.queue) == Set(inbox.notices.map(\.id)))
    }

    @Test func clearEmptiesTheListExceptOpenApprovals() {
        var inbox = Inbox()
        let open = UUID()
        inbox.add(notice(.approval, "a", approval: open))
        inbox.add(notice(.approval, "b", approval: UUID()))
        inbox.add(notice(.failed, "c"))
        inbox.clear(keepingApprovals: [open])
        #expect(inbox.notices.map(\.botID) == ["a"] && inbox.queue == inbox.notices.map(\.id))
        // La demande restée n'est pas doublée si le flux la renvoie.
        inbox.add(notice(.approval, "a", approval: open))
        #expect(inbox.notices.count == 1)
    }

    // MARK: Absence

    @Test func awayWhenLockedAsleepOrIdle() {
        #expect(Presence.isAway(locked: true, asleep: false, idleSeconds: 0))
        #expect(Presence.isAway(locked: false, asleep: true, idleSeconds: 0))
        #expect(Presence.isAway(locked: false, asleep: false, idleSeconds: 121))
        #expect(!Presence.isAway(locked: false, asleep: false, idleSeconds: 30))
    }

    @Test func returningShowsOneBanner() {
        #expect(Presence.returnBanner([]) == nil)
        let one = notice(.message)
        #expect(Presence.returnBanner([one]) == .notice(one))
        let a = notice(.message, at: 0), b = notice(.finished, at: 5)
        #expect(Presence.returnBanner([a, b]) == .recap(count: 2, latest: b))
        let ask = notice(.approval, at: 1, approval: UUID())
        #expect(Presence.returnBanner([a, ask, b]) == .notice(ask))
    }

    // MARK: Nouveaux messages

    private func bot(_ id: String, replies: [ChatMessage]) -> Bot {
        var b = Bot(id: id, name: id.capitalized,
                    runtime: BotRuntime(name: "r", model: "m", mode: "auto", connected: true, lastSeenAt: now, connectorVersion: "1"))
        b.thread = replies
        return b
    }

    @Test func aNewBotReplyIsNoticedOncePerBot() {
        let old = ChatMessage(role: .bot, text: "Ancien", at: now.addingTimeInterval(-10))
        let before = bot("seo", replies: [old])
        let previous = ["seo": MessageDiff.botMessageIDs(before)]
        let r1 = ChatMessage(role: .bot, text: "Premier", at: now.addingTimeInterval(1))
        let r2 = ChatMessage(role: .bot, text: "**Second**\nligne", at: now.addingTimeInterval(2))
        let user = ChatMessage(role: .user, text: "Moi", at: now.addingTimeInterval(3))
        let replies = MessageDiff.replies(previous: previous, bots: [bot("seo", replies: [old, r1, r2, user])], since: now)
        #expect(replies.count == 1)
        #expect(replies.first?.text == "Second ligne" && replies.first?.count == 2)
    }

    @Test func historyLoadedLaterIsNotNews() {
        let previous = ["seo": Set<String>()]
        let past = ChatMessage(role: .bot, text: "D'hier", at: now.addingTimeInterval(-86_400))
        #expect(MessageDiff.replies(previous: previous, bots: [bot("seo", replies: [past])], since: now).isEmpty)
    }

    @Test func aBotSeenForTheFirstTimeIsNotNews() {
        let fresh = ChatMessage(role: .bot, text: "Bonjour", at: now.addingTimeInterval(1))
        #expect(MessageDiff.replies(previous: [:], bots: [bot("seo", replies: [fresh])], since: now).isEmpty)
    }

    @Test func longRepliesAreCut() {
        let text = String(repeating: "a", count: 300)
        #expect(MessageDiff.excerpt(text).count == 160 && MessageDiff.excerpt(text).hasSuffix("…"))
    }

    // MARK: Île

    @Test func unreadNoticesKeepTheIslandVisibleWithoutActiveBots() {
        let c = Island.compact(bots: [], unread: 3, latestUnreadBotID: "seo")
        #expect(c?.botIDs == ["seo"] && c?.unread == 3)
        #expect(Island.compact(bots: [], unread: 0) == nil)
    }

    @Test func noticeCenterQueuesBannersOnlyInTheIsland() async {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        center.post(notice(.finished, "a"))
        #expect(model.banner == nil && model.inbox.unreadCount == 1)
        center.isIsland = { true }
        center.post(notice(.message, "b"))
        // L'île choisie : la plus ancienne de même priorité passe d'abord.
        if case .notice(let n) = model.banner { #expect(n.botID == "a") } else { Issue.record("pas de bannière") }
        center.dismissBanner()
        // La suivante passe après une courte pause ; la suite parallèle peut ralentir le fil principal.
        for _ in 0..<60 where model.banner == nil { try? await Task.sleep(for: .milliseconds(50)) }
        if case .notice(let n) = model.banner { #expect(n.botID == "b") } else { Issue.record("pas de seconde bannière") }
    }

    @Test func closingThePanelErasesWhatWasRead() async {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        center.post(notice(.back, "a"))
        center.post(notice(.failed, "b"))
        model.isExpanded = true
        for _ in 0..<20 { await Task.yield() }
        model.isExpanded = false
        for _ in 0..<60 where model.inbox.notices.count != 1 { try? await Task.sleep(for: .milliseconds(50)) }
        // Le retour du runtime, enregistré lu, part ; la panne, non lue, reste.
        #expect(model.inbox.notices.map(\.botID) == ["b"])
    }

    @Test func clearButtonEmptiesTheBox() {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        center.post(notice(.failed, "a"))
        center.post(notice(.message, "b"))
        center.clear()
        #expect(model.inbox.notices.isEmpty && model.inbox.unreadCount == 0)
    }

    private func waiting(_ id: String, remote: String, command: String = "ls") -> Bot {
        var b = bot(id, replies: [])
        b.pending = Approval(remoteID: remote, botID: id, runID: "r", tool: "shell", command: command, expiresAt: now.addingTimeInterval(600))
        return b
    }

    /// La session avant la démonstration : les bots donnés, une notification par demande en attente.
    private func sessionSetAside(_ center: NoticeCenter, _ model: NotchModel, _ bots: [Bot], read: Bool = false) {
        model.bots = bots
        for bot in bots where bot.pending != nil { center.transition(bot, .waiting) }
        if read { model.inbox.markAllRead() }
        center.setAside()
        #expect(model.inbox.notices.isEmpty, "the demo starts with an empty box")
        model.bots = DemoBotFeed.roster(now: now)
    }

    @Test func approvalsRestoredAfterTheDemoFollowTheResumedFeed() async {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        // Avant la démonstration : une demande en attente sur seo, une sur ops.
        sessionSetAside(center, model, [waiting("seo", remote: "ap-seo"), waiting("ops", remote: "ap-ops")])
        center.restore()
        // Le flux reprend : seo attend toujours (sous une nouvelle identité locale), ops a été répondu.
        let seo = waiting("seo", remote: "ap-seo")
        model.bots = [seo, bot("ops", replies: [])]
        center.rosterLoaded()
        #expect(model.inbox.unreadCount == 1)
        #expect(model.inbox.notices.first { $0.botID == "seo" }?.approvalID == seo.pending?.id)
        #expect(model.inbox.notices.first { $0.botID == "ops" }?.read == true)
        // Répondue ensuite (le roster une fois vu par le centre), celle de seo se ferme comme les autres.
        try? await Task.sleep(for: .milliseconds(100))
        model.update("seo") { $0.pending = nil }
        await waitUntil { model.inbox.unreadCount == 0 }
        #expect(model.inbox.unreadCount == 0)
    }

    @Test func anotherRequestOfTheSameBotNeverTakesTheOldText() {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        sessionSetAside(center, model, [waiting("seo", remote: "ap-a", command: "rm -rf build")])
        center.restore()
        // A répondue ailleurs pendant la démonstration, B demandée par le même bot.
        let b = waiting("seo", remote: "ap-b", command: "git push")
        model.bots = [b]
        center.rosterLoaded()
        let old = model.inbox.notices.first { $0.text.contains("rm -rf build") }
        #expect(old?.read == true && old?.approvalID != b.pending?.id, "A is closed, never bound to B")
        let fresh = model.inbox.notices.first { $0.text.contains("git push") }
        #expect(fresh?.approvalID == b.pending?.id && fresh?.read == false, "B is announced with its own text")
    }

    @Test func restoredApprovalsWaitForTheirReconciliationBeforeAnyBanner() {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        sessionSetAside(center, model, [waiting("seo", remote: "ap-seo")])
        center.isIsland = { true }
        center.restore()
        center.pump()
        #expect(model.banner == nil, "not with the identity from before the demo")
        let seo = waiting("seo", remote: "ap-seo")
        model.bots = [seo]
        center.rosterLoaded()
        guard case .notice(let shown) = model.banner else { Issue.record("no banner after the reconciliation"); return }
        #expect(shown.approvalID == seo.pending?.id)
    }

    @Test func readApprovalsSurviveTheCleanupBeforeTheRosterReturns() async {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        sessionSetAside(center, model, [waiting("seo", remote: "ap-seo")], read: true)
        center.restore()
        // Panneau de la démonstration refermé avant que le roster revienne : le ménage des lues passe.
        model.isExpanded = true
        try? await Task.sleep(for: .milliseconds(50))
        model.isExpanded = false
        model.bots = []
        try? await Task.sleep(for: .milliseconds(50))
        let seo = waiting("seo", remote: "ap-seo")
        model.bots = [seo]
        center.rosterLoaded()
        #expect(model.inbox.notices.contains { $0.approvalID == seo.pending?.id }, "still pending, still there")
    }

    @Test func approvalsRestoredAfterTheDemoCloseOnAnEmptyRoster() {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        sessionSetAside(center, model, [waiting("seo", remote: "ap-seo")])
        center.restore()
        // Tous les bots archivés pendant la démonstration : le roster relu est vide.
        model.bots = []
        center.rosterLoaded()
        #expect(model.inbox.unreadCount == 0 && model.inbox.nextBanner() == nil)
        // Une seule fois : une nouvelle demande, ensuite, n'est pas touchée.
        model.inbox.add(notice(.approval, "ops", approval: UUID()))
        center.rosterLoaded()
        #expect(model.inbox.unreadCount == 1)
    }

    @Test func aReplyDuringTheDemoIsAnnouncedOnceWhenTheSessionReturns() async {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        let seen = ChatMessage(role: .bot, text: "Avant", at: now)
        model.bots = [bot("seo", replies: [seen])]
        try? await Task.sleep(for: .milliseconds(50))
        center.setAside()
        model.bots = DemoBotFeed.roster(now: Date())
        try? await Task.sleep(for: .milliseconds(50))
        // Fin de la démonstration : les bots fictifs partent, puis le flux de la session reprend.
        center.restore()
        model.bots = []
        try? await Task.sleep(for: .milliseconds(50))
        let reply = ChatMessage(role: .bot, text: "Pendant la démo", at: Date())
        model.bots = [bot("seo", replies: [seen, reply])]
        center.rosterLoaded()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.inbox.notices.filter { $0.kind == .message }.map(\.text) == ["Pendant la démo"], "announced once, the old one never")
    }

    @Test func aThreadRereadLateAfterTheDemoAnnouncesOnlyWhatIsNew() async {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        func reply(_ id: String) -> ConversationMessage {
            ConversationMessage(id: id, role: .assistant, text: "Réponse \(id)", attachments: [], runID: nil, at: Date())
        }
        var seo = bot("seo", replies: [])
        seo.conversation = Conversation(messages: [reply("m1")])
        model.bots = [seo]
        try? await Task.sleep(for: .milliseconds(50))
        center.setAside()
        model.bots = DemoBotFeed.roster(now: now)
        try? await Task.sleep(for: .milliseconds(50))
        center.restore()
        // Le roster revient, mais le fil de seo n'a pas pu être relu.
        model.bots = [bot("seo", replies: [])]
        center.rosterLoaded()
        try? await Task.sleep(for: .milliseconds(50))
        // Relu ensuite : la réponse d'avant la démonstration reste vue, seule la nouvelle s'annonce.
        seo.conversation = Conversation(messages: [reply("m1"), reply("m2")])
        model.bots = [seo]
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.inbox.notices.filter { $0.kind == .message }.map(\.text) == ["Réponse m2"])
    }

    /// Une demande d'accord en bannière quand la démonstration commence, et une panne en file derrière.
    private func approvalBannerSetAside(_ center: NoticeCenter, _ model: NotchModel) {
        model.plays = false
        center.isIsland = { true }
        let seo = waiting("seo", remote: "ap-seo")
        model.bots = [seo]
        center.transition(seo, .waiting)
        guard case .notice(let shown) = model.banner, shown.kind == .approval else { Issue.record("no approval banner"); return }
        center.post(notice(.failed, "ops"))
        center.setAside()
        #expect(model.banner == nil, "no session banner over the demo")
        model.bots = DemoBotFeed.roster(now: now)
        center.restore()
    }

    @Test func anApprovalBannerInterruptedByTheDemoComesBackFirst() {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        approvalBannerSetAside(center, model)
        let seo = waiting("seo", remote: "ap-seo")
        model.bots = [seo]
        center.rosterLoaded()
        guard case .notice(let shown) = model.banner else { Issue.record("no banner after the demo"); return }
        #expect(shown.approvalID == seo.pending?.id, "the interrupted request, before the failure queued behind it")
    }

    @Test func anInterruptedApprovalAnsweredDuringTheDemoStaysClosed() {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        approvalBannerSetAside(center, model)
        model.bots = [bot("seo", replies: [])]
        center.rosterLoaded()
        guard case .notice(let shown) = model.banner else { Issue.record("no banner after the demo"); return }
        #expect(shown.kind == .failed && shown.botID == "ops")
    }

    @Test func theDemoNeverBecomesANotification() async {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        model.plays = false
        center.isMuted = { true }
        // Une réponse d'un bot de la démonstration, puis une demande d'accord : rien dans la boîte.
        model.bots = DemoBotFeed.roster(now: Date())
        for _ in 0..<20 { await Task.yield() }
        model.update(DemoBotFeed.writingID) { $0.thread.append(ChatMessage(role: .bot, text: "Le billet est prêt.")) }
        for _ in 0..<20 { await Task.yield() }
        if let bot = model.bot(DemoBotFeed.writingID) { center.transition(bot, .finished) }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.inbox.notices.isEmpty && model.inbox.unreadCount == 0)
    }

    @Test func awayKeepsBannersForLater() {
        let model = NotchModel()
        let center = NoticeCenter(model: model)
        defer { center.stop() }
        center.isIsland = { true }
        model.plays = false
        model.isAway = true
        center.post(notice(.message))
        #expect(model.banner == nil && model.inbox.queue.count == 1)
    }
}
