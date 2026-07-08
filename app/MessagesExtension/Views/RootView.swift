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
            case .welcome(let hasBackup):
                WelcomeView(store: store, bridge: bridge, hasBackup: hasBackup)
            case .working(let message):
                VStack(spacing: 12) {
                    ProgressView()
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            case .ready:
                HomeView(store: store, bridge: bridge)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(.orange)
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

struct WelcomeView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject var bridge: ExtensionBridge
    let hasBackup: Bool

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

            Image(systemName: "bitcoinsign.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)

            Text(hasBackup ? "Your Bitcoin wallet is ready to unlock" : "Bitcoin, right here in Messages")
                .font(.headline)
                .multilineTextAlignment(.center)

            if !bridge.isCompact {
                Text(
                    hasBackup
                        ? "A backup was found in your iCloud. Unlock it with Face ID."
                        : "One tap creates a wallet that's backed up to your iCloud — no seed phrases, no sign-ups."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            }

            if hasBackup {
                Button {
                    Task { await expandThen { await store.restoreWallet() } }
                } label: {
                    Label("Unlock with Face ID", systemImage: "faceid")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    Task { await expandThen { await store.createWallet() } }
                } label: {
                    Label("Create Bitcoin Wallet", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if store.chain.network != .bitcoin {
                NetworkBadge(network: store.chain.network)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 24)
    }

    /// Face ID cannot survive a compact→expanded transition happening
    /// underneath it (LAError -4 systemCancel), so expand first, let the
    /// Messages presentation settle, then start the authenticated flow.
    private func expandThen(_ action: @escaping () async -> Void) async {
        if bridge.isCompact {
            bridge.requestExpanded()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        await action()
    }
}

struct NetworkBadge: View {
    let network: NetworkKind

    var body: some View {
        Text(network.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.purple.opacity(0.15)))
            .foregroundStyle(.purple)
    }
}
