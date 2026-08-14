import SwiftUI
import WalletKit

/// Shown to someone who just tapped "Join" on a pot invite: a friendly
/// "setting up…" state while their DKG round syncs over CloudKit, then a
/// success (or error). No crypto/threshold language surfaces.
struct SettingUpPotView: View {
    @ObservedObject var coordinator: VaultCoordinator
    let emoji: String
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(emoji).font(.system(size: 62))

            switch coordinator.stage {
            case .ready:
                Text("\(coordinator.config.name) is ready! 🎉")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                Text("You're in. Everyone shares this pot — spending takes any \(coordinator.config.threshold).")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Button(action: onOpen) {
                    Label("Open pot", systemImage: "arrow.right.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(ProminentButtonStyle()).padding(.horizontal, 32).padding(.top, 4)

            case .error(let message):
                IconBubble(systemName: "exclamationmark.triangle.fill", tint: .orange, size: 52)
                Text("Couldn't set up the pot")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                Button("Close", action: onClose).buttonStyle(QuietButtonStyle()).padding(.top, 4)

            default:
                ProgressView().controlSize(.large).tint(Brand.orange)
                Text("Joining \(coordinator.config.name)…")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                Text("Your phones are setting up the shared pot together. No single phone ever holds the whole key.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).padding(.horizontal, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
