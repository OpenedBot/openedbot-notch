import Foundation
import os

/// Les baux YOLO de l'organisation : relus toutes les 30 s (et juste après l'échéance la plus proche),
/// posés dans `model.yolo` ; « Couper YOLO partout » par `POST /api/organization/yolo/kill`.
/// Même client que le flux (`OHBotAPI`) : bearer, `X-OHB-Organization`, un rejeu après un 401.
@MainActor
final class YoloMonitor {
    static let leasesPath = "/api/organization/yolo/leases"
    static let killPath = "/api/organization/yolo/kill"

    private let model: NotchModel
    private let api: OHBotAPI
    private let poll: Duration
    private var task: Task<Void, Never>?
    /// Incrémenté par une coupure et par `stop` : une relecture partie avant n'écrit plus rien,
    /// sinon elle ressusciterait les baux qu'on vient de couper.
    private var generation = 0
    private static let log = Logger(subsystem: "app.openedbot.popup", category: "yolo")

    init(model: NotchModel, account: any TokenSource, transport: any HTTPTransport = URLSession.shared, poll: Duration = .seconds(30)) {
        self.model = model
        self.api = OHBotAPI(account: account, transport: transport)
        self.poll = poll
    }

    func start() {
        stop()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let delay = self.nextDelay(now: Date())
                try? await Task.sleep(for: delay)
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
        generation += 1
        model.yolo = YoloState()
    }

    /// Le prochain sondage : au plus `poll`, mais juste après l'échéance la plus proche pour que le
    /// badge suive le serveur sans attendre 30 s.
    func nextDelay(now: Date) -> Duration {
        let soonest = model.yolo.leases.compactMap(\.expiresAt).filter { $0 > now }.min()
        guard let soonest else { return poll }
        let wait = Duration.milliseconds(Int64((soonest.timeIntervalSince(now) + 0.5) * 1000))
        return max(.seconds(1), min(poll, wait))
    }

    // MARK: Lecture

    func refresh() async {
        let started = generation
        do {
            let dto: YoloLeasesDto = try await api.get(Self.leasesPath)
            guard started == generation else { return }
            model.yolo.leases = dto.leases.filter { $0.isActive(at: Date()) }
        } catch OHBotAuthError.cancelled {
        } catch OHBotAuthError.http(404, _) {
            // Un serveur sans YOLO : rien ne peut être actif.
            guard started == generation else { return }
            model.yolo.leases = []
            note(.info, tr("YOLO not available on this server", "YOLO indisponible sur ce serveur"), key: "yolo-unavailable")
        } catch {
            // On garde les baux connus (moins ceux échus) : cacher YOLO sur une panne serait pire.
            guard started == generation else { return }
            model.yolo.leases = model.yolo.active(at: Date())
            note(.warning, tr("YOLO leases unreadable: \(Self.text(error))", "baux YOLO illisibles : \(Self.text(error))"), key: "yolo-error")
        }
    }

    // MARK: Coupure

    /// Le bouton de l'île, après confirmation.
    func kill() {
        Task { await killAll() }
    }

    func killAll() async {
        guard !model.yolo.killing else { return }
        struct NoBody: Encodable {}
        generation += 1
        let mine = generation
        model.yolo.killing = true
        model.yolo.killError = nil
        do {
            let _: OHBotAPI.Empty = try await api.post(Self.killPath, json: NoBody())
            guard mine == generation else { return }
            model.yolo.killing = false
            model.yolo.leases = []
            note(.info, tr("YOLO turned off everywhere", "YOLO coupé partout"))
        } catch {
            guard mine == generation else { return }
            model.yolo.killing = false
            let text: String = if case OHBotAuthError.http(403, _) = error {
                tr("Only an owner or admin of the organization can turn YOLO off.",
                   "Seuls les propriétaires et administrateurs de l'organisation peuvent couper YOLO.")
            } else {
                Self.text(error)
            }
            model.yolo.killError = text
            note(.error, tr("YOLO kill refused: \(text)", "coupure YOLO refusée : \(text)"))
        }
        // Le serveur a le dernier mot : ce qui reste actif (coupure refusée, bail recréé) revient.
        await refresh()
    }

    // MARK: Journal

    private func note(_ level: JournalEntry.Level, _ text: String, key: String? = nil) {
        switch level {
        case .info: Self.log.info("\(text, privacy: .public)")
        case .warning: Self.log.notice("\(text, privacy: .public)")
        case .error: Self.log.error("\(text, privacy: .public)")
        }
        model.record(level, .api, text, key: key)
    }

    private static func text(_ error: Error) -> String {
        (error as? OHBotAuthError)?.userMessage ?? error.localizedDescription
    }
}
