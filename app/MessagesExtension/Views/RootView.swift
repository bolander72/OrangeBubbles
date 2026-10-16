import SwiftUI
import WalletKit

struct RootView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject var bridge: ExtensionBridge

    var body: some View {
        ZStack {
            switch store.phase {
            case .loading:
                ProgressView()
            case .working(let message):
                WorkingView(message: message)
            case .ready:
                HomeView(store: store, bridge: bridge)
            case .setupFailed(let message):
                SetupFailedView(store: store, message: message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Brand.orange)
        // Errors surface through UIKit on the top-most presented controller
        // (see ExtensionBridge.presentError) so they appear over Send /
        // Receive / card sheets instead of dismissing them.
        .onChange(of: store.lastError) { _, message in
            guard let message else { return }
            bridge.presentError(message) { store.lastError = nil }
        }
    }
}

/// Shown only during first-ever setup or a fresh-device restore — normal
/// opens go straight to the wallet (ADR 0004: there is no wallet ceremony).
struct WorkingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            BitcoinMark(size: 52)
            ProgressView()
                .tint(Brand.orange)
            Text(message)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Auto-setup could not complete (keychain unavailable, passkey assertion
/// failed on a fresh device, …). The only screen with a manual button.
struct SetupFailedView: View {
    @ObservedObject var store: WalletStore
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            IconBubble(systemName: "exclamationmark.triangle.fill", tint: .orange, size: 56)

            Text("Couldn't open your wallet")
                .font(.system(.headline, design: .rounded).weight(.bold))

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Button {
                Task { await store.retrySetup() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ProminentButtonStyle())
            .padding(.top, 6)
        }
        .padding(.horizontal, 28)
    }
}
