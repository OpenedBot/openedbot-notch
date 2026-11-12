import SwiftUI

// La mise à jour de l'app annoncée par openedbot : un point bleu dans l'île compacte, une ligne dans
// le panneau qui ouvre la console sur ses réglages. L'encoche n'installe ni ne relance rien.

/// Le point « mise à jour prête / requise », à droite de la caméra, au repos comme au travail.
struct UpdateDot: View {
    let badge: HostUpdate.Badge

    var body: some View {
        Circle().fill(Palette.update)
            .frame(width: Island.updateDotSize, height: Island.updateDotSize)
            .accessibilityElement()
            .accessibilityLabel(badge.title)
    }
}

/// La ligne du panneau : « Mise à jour prête » et sa version, ou « Mise à jour requise » et où
/// l'installer. Un clic montre openedbot sur `/settings/updates`.
struct IslandUpdateRow: View {
    let update: HostUpdate
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        if let title = update.title {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(systemName: update.badge == .required ? "exclamationmark.arrow.circlepath" : "arrow.down.circle.fill")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.update)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Palette.textPrimary).lineLimit(1)
                        if let subtitle = update.subtitle {
                            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(hovering ? 0.1 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.update.opacity(0.4), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .pointer()
            .help(tr("Show the update in openedbot", "Voir la mise à jour dans openedbot"))
        }
    }
}
