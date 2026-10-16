import AuthenticationServices
import SwiftUI

/// The container app. The product lives in Messages; this screen points
/// people there — and hosts the passkey ceremonies that can't run inside
/// a Messages extension (see PasskeyOps).
@main
struct OrangeBubblesApp: App {
    var body: some Scene {
        WindowGroup {
            HostHomeView()
        }
    }
}

struct HostHomeView: View {
    @StateObject private var ops = PasskeyOps()

    private let orange = Color(red: 0.97, green: 0.58, blue: 0.10)

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bitcoinsign.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(orange)
            Text("OrangeBubbles lives in Messages")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Open a conversation, tap the app strip, and choose OrangeBubbles to send and receive bitcoin.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            walletSection

            Spacer()
            Text("Your keys never leave your device.\nEncrypted backup lives in your iCloud.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
        .task { await ops.determineState() }
        .onOpenURL { url in
            // orangebubbles://upgrade — handoff from the Messages extension.
            guard url.host == "upgrade" || url.path.contains("upgrade") else { return }
            Task {
                await ops.determineState()
                if ops.state == .upgradable { await ops.upgrade() }
            }
        }
        .background(AnchorGrabber { window in ops.anchor = { window } })
    }

    @ViewBuilder
    private var walletSection: some View {
        switch ops.state {
        case .checking:
            ProgressView()
        case .noWallet:
            EmptyView()
        case .upgradable:
            Button {
                Task { await ops.upgrade() }
            } label: {
                Label("Upgrade to passkey protection", systemImage: "person.badge.key.fill")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(orange.opacity(0.15)))
            }
        case .passkeyActive:
            Label("Passkey protection active", systemImage: "checkmark.shield.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.green)
        case .lockedPasskeyBackup:
            Button {
                Task { await ops.unlock() }
            } label: {
                Label("Unlock wallet with passkey", systemImage: "faceid")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(orange.opacity(0.15)))
            }
        case .working(let message):
            VStack(spacing: 8) {
                ProgressView()
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
                .multilineTextAlignment(.center)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await ops.determineState() }
                }
                .font(.footnote.weight(.semibold))
            }
        }
    }
}

/// Passkey sheets need a UIWindow anchor; SwiftUI doesn't hand one out,
/// so grab it from the hosting view.
private struct AnchorGrabber: UIViewRepresentable {
    let onWindow: (UIWindow?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}
