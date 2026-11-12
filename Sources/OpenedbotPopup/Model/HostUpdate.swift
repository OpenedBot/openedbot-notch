import Foundation

/// L'état de la mise à jour de l'app openedbot, tel que l'hôte l'annonce (`updateState`). L'encoche
/// ne fait que le montrer et ouvrir la console sur ses réglages : elle n'installe et ne relance rien.
struct HostUpdate: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case idle, checking, available, downloading, ready, installing, error, required
        /// Un mot qu'un hôte plus récent enverrait : rien à montrer.
        case unknown
    }

    /// Ce que l'île montre : une mise à jour téléchargée, prête, ou une version minimale exigée.
    enum Badge: Equatable, Sendable {
        case ready, required

        /// Le titre de la ligne du panneau, et l'étiquette d'accessibilité du point.
        var title: String {
            switch self {
            case .ready: tr("Update ready", "Mise à jour prête")
            case .required: tr("Update required", "Mise à jour requise")
            }
        }
    }

    var status: Status = .idle
    /// `ready` : la version téléchargée ; `required` : la version minimale, quand elle est connue.
    var version: String?

    init(status: Status = .idle, version: String? = nil) {
        self.status = status
        self.version = version
    }

    /// D'après le message de l'hôte, mot inconnu compris.
    init(status raw: String, version: String?) {
        self.init(status: Status(rawValue: raw) ?? .unknown, version: version)
    }

    /// Rien d'annoncé (avant le premier message, après la fermeture de l'hôte).
    static let none = HostUpdate()

    /// Seuls `ready` et `required` se montrent ; tout le reste cache le badge.
    var badge: Badge? {
        switch status {
        case .ready: .ready
        case .required: .required
        case .idle, .checking, .available, .downloading, .installing, .error, .unknown: nil
        }
    }

    var title: String? { badge?.title }

    /// La ligne sous le titre : la version prête quand on la connaît, où l'installer si elle est exigée.
    var subtitle: String? {
        switch badge {
        case .ready: version.map { "openedbot \($0)" }
        case .required: tr("Open openedbot to install it", "Ouvrez openedbot pour l'installer")
        case nil: nil
        }
    }

    /// Le chemin de la console où l'on installe la mise à jour (fenêtre principale d'openedbot).
    static let consolePath = "/settings/updates"
}
