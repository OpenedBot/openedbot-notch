import Foundation

/// La démonstration que l'hôte demande à la première connexion (et depuis « Revoir la
/// démonstration ») : deux bots fictifs, aucun appel réseau, un cycle d'environ 12 s qui boucle.
///
/// Un cycle : les deux bots travaillent (l'île compacte, « en cours »), puis Rédaction demande un
/// accord et l'île se déplie d'elle-même sur « Autoriser » / « Refuser » ; la réponse (la vôtre,
/// ou un accord automatique au bout de quelques secondes) reste locale, l'île se replie, les deux
/// runs finissent (« terminé »). Inspirée de `MockBotFeed.simulateApproval`.
///
/// Elle s'arrête au bout de `cycles` boucles (0 : sans fin), ou à la fin du cycle pendant lequel
/// l'utilisateur l'a touchée (survol, clic, réponse) ; elle garde alors sa dernière image et le dit
/// (`onEnded`), l'hôte décide de la suite.
@MainActor
final class DemoBotFeed: BotFeed {
    static let researchID = "demo-recherche"
    static let writingID = "demo-redaction"
    /// La durée d'un cycle, accord automatique compris, à l'échelle 1.
    static let cycleSeconds: Double = 12

    var onTransition: ((Bot, FeedTransition) -> Void)?
    /// La démonstration s'est arrêtée d'elle-même.
    var onEnded: () -> Void = {}
    /// Replier l'île après la réponse, sauf si le pointeur est dessus (le contrôleur le sait).
    var fold: () -> Void

    private let model: NotchModel
    private let timeScale: Double
    private let answerTimeout: Duration
    private var task: Task<Void, Never>?
    private var answer: CheckedContinuation<Bool?, Never>?
    private var answerToken = 0
    private var cycles = 0
    private(set) var touched = false
    private(set) var isPlaying = false
    private(set) var completedCycles = 0

    /// `answerTimeout` : combien de temps la demande d'accord attend une réponse avant de s'accorder seule.
    init(model: NotchModel, timeScale: Double = 1, answerTimeout: Duration = .seconds(4)) {
        self.model = model
        self.timeScale = timeScale
        self.answerTimeout = answerTimeout
        fold = { [weak model] in model?.isExpanded = false }
    }

    func start() { start(cycles: 0) }

    func start(cycles: Int) {
        stop()
        self.cycles = max(0, cycles)
        touched = false
        completedCycles = 0
        isPlaying = true
        model.sections = []
        model.runtime = nil
        model.feedState = .live
        model.bots = Self.roster(now: Date())
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        resolveAnswer(nil)
        isPlaying = false
    }

    /// Reprend au début du cycle, ses textes réécrits (la langue a changé) : la limite de cycles
    /// restante et un geste déjà fait tiennent toujours.
    func relocalize() {
        guard isPlaying else { return }
        let remaining = cycles == 0 ? 0 : max(1, cycles - completedCycles)
        let wasTouched = touched
        start(cycles: remaining)
        touched = wasTouched
    }

    /// Survol, clic : la démonstration finit son cycle puis s'arrête.
    func userInteracted() {
        touched = true
    }

    func respond(approvalID: UUID, allow: Bool) {
        guard apply(approvalID: approvalID, allow: allow) else { return }
        touched = true
        resolveAnswer(allow)
    }

    func send(_ text: String, attachments: [PendingAttachment], replyTo: String?, to botID: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        touched = true
        model.update(botID) { bot in
            bot.thread.append(ChatMessage(role: .user, text: trimmed))
            bot.thread.append(ChatMessage(role: .bot, text: tr("This is a demo: your real bots will answer here once it ends.",
                                                               "Ceci est une démonstration : vos vrais bots répondront ici ensuite.")))
        }
    }

    func react(botID: String, messageID: String, emoji: String) {}
    func loadModelCatalog() async {}
    func setModel(botID: String, model: String?, effort: String?) async throws {}

    // MARK: Script

    private func run() async {
        do {
            while !Task.isCancelled {
                try await cycle()
                completedCycles += 1
                if touched || (cycles > 0 && completedCycles >= cycles) {
                    isPlaying = false
                    onEnded()
                    return
                }
            }
        } catch {}
    }

    private func cycle() async throws {
        let now = Date()
        model.isExpanded = false
        model.bots = Self.roster(now: now)
        try await sleep(1.5)
        step(Self.researchID, to: 2, detail: tr("web.search · 12 sources", "web.search · 12 sources"))
        step(Self.writingID, to: 2, detail: tr("Draft · 600 words", "Brouillon · 600 mots"))
        try await sleep(1.5)
        step(Self.researchID, to: 3, detail: tr("Comparing 4 offers", "Comparaison de 4 offres"))
        try await sleep(1)
        // L'accord : l'île se déplie d'elle-même pour le montrer.
        var approvalID: UUID?
        model.update(Self.writingID) { bot in
            let run = bot.runs.first?.id ?? "demo-run"
            bot.thread.append(ChatMessage(role: .bot, text: tr("The post is ready. May I publish it on the blog?", "Le billet est prêt. Je peux le publier sur le blog ?")))
            bot.pending = Approval(botID: bot.id, runID: run, tool: "cms", command: "cms publish --post billet-novembre",
                                   expiresAt: Date().addingTimeInterval(9 * 60))
            bot.inboxCount = 1
            if let r = bot.runs.firstIndex(where: { $0.id == run }) { bot.runs[r].status = .awaitingApproval }
            approvalID = bot.pending?.id
        }
        model.isExpanded = true
        let given = await waitForAnswer()
        try Task.checkCancellation()
        if given == nil, let approvalID, let bot = model.bot(Self.writingID) {
            // Personne n'a répondu : la démo s'accorde seule, comme un clic sur « Autoriser ».
            _ = apply(approvalID: approvalID, allow: true)
            model.flash(Island.Flash(botID: bot.id, botName: bot.name, kind: .allowed), for: 2)
        }
        let allowed = given ?? true
        fold()
        try await sleep(1)
        finish(Self.researchID, detail: tr("Summary of 4 offers", "Synthèse de 4 offres"))
        if allowed {
            step(Self.writingID, to: 3, detail: tr("Publishing", "Publication"))
        }
        try await sleep(1.5)
        if allowed {
            finish(Self.writingID, detail: tr("Post published", "Billet publié"))
        } else {
            // Refusé : rien n'est publié, le billet reste un brouillon.
            finish(Self.writingID, detail: tr("Kept as a draft", "Gardé en brouillon"))
        }
        if let bot = model.bot(Self.writingID) {
            model.flash(Island.Flash(botID: bot.id, botName: bot.name, kind: .finished), for: 1.5)
        }
        try await sleep(1.5)
    }

    private func step(_ id: String, to used: Int, detail: String) {
        model.update(id) { bot in
            guard let r = bot.runs.indices.first else { return }
            bot.runs[r].usedSteps = min(used, bot.runs[r].maxSteps)
            bot.runs[r].detail = detail
            if bot.runs[r].status != .awaitingApproval { bot.runs[r].status = .running }
            bot.thread.append(ChatMessage(role: .tool, text: detail))
        }
    }

    private func finish(_ id: String, detail: String) {
        model.update(id) { bot in
            bot.pending = nil
            bot.inboxCount = 0
            guard let r = bot.runs.indices.first else { return }
            bot.runs[r].usedSteps = bot.runs[r].maxSteps
            bot.runs[r].status = .completed
            bot.runs[r].detail = detail
        }
    }

    /// Applique une réponse à la demande en cours ; false si elle n'est plus là.
    @discardableResult
    private func apply(approvalID: UUID, allow: Bool) -> Bool {
        guard let bot = model.bots.first(where: { $0.pending?.id == approvalID }) else { return false }
        model.update(bot.id) { bot in
            bot.pending = nil
            bot.inboxCount = 0
            if let r = bot.runs.indices.first {
                bot.runs[r].status = .running
                if !allow { bot.runs[r].detail = tr("Kept as a draft", "Gardé en brouillon") }
            }
            bot.thread.append(ChatMessage(role: .system, text: allow ? tr("Allowed once (demo)", "Autorisé une fois (démo)") : tr("Denied (demo)", "Refusé (démo)")))
        }
        return true
    }

    private func waitForAnswer() async -> Bool? {
        let timeout = answerTimeout
        answerToken += 1
        let token = answerToken
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            answer = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                // Le minuteur d'une demande déjà répondue ne répond pas à la suivante.
                guard let self, self.answerToken == token else { return }
                self.resolveAnswer(nil)
            }
        }
    }

    private func resolveAnswer(_ value: Bool?) {
        answer?.resume(returning: value)
        answer = nil
    }

    private func sleep(_ seconds: Double) async throws {
        let scaled = seconds * timeScale
        guard scaled > 0 else { await Task.yield(); try Task.checkCancellation(); return }
        try await Task.sleep(for: .milliseconds(Int(scaled * 1000)))
    }

    // MARK: Roster

    static func roster(now: Date) -> [Bot] {
        let runtime = BotRuntime(name: "mac-studio", model: "claude-sonnet-5-5", mode: "manual", connected: true, lastSeenAt: now,
                                 connectorVersion: "1.5.0", latestVersion: "1.5.0", downSince: nil)
        return [
            Bot(id: researchID, name: tr("Research", "Recherche"), artwork: "astral", runtime: runtime,
                runs: [BotRun(id: "demo-veille", kind: .routine, title: tr("Market watch", "Veille concurrentielle"), detail: tr("Searching", "Recherche en cours"),
                              status: .running, usedSteps: 1, maxSteps: 4, tokens: 1_200, since: now)],
                thread: [ChatMessage(role: .tool, text: tr("web.search · starting", "web.search · démarrage"), at: now)]),
            Bot(id: writingID, name: tr("Writing", "Rédaction"), artwork: "bloom", runtime: runtime,
                runs: [BotRun(id: "demo-billet", kind: .dm, title: tr("Blog post", "Billet de blog"), detail: tr("Outline", "Plan"),
                              status: .running, usedSteps: 1, maxSteps: 3, tokens: 900, since: now)],
                thread: [ChatMessage(role: .tool, text: tr("docs.outline · 5 sections", "docs.outline · 5 parties"), at: now)]),
        ]
    }
}
