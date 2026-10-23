import AuthenticationServices
import SwiftUI
import WalletKit

/// The container app. The product lives in Messages; this screen is the
/// watch-only companion (balance, activity, Receive) and hosts the passkey
/// ceremonies that can't run inside a Messages extension (see PasskeyOps).
/// Built from the same design system as the extension so the two read as
/// one product.
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
    @State private var snapshot = SharedSnapshot.load()
    @State private var showReceive = false
    @Environment(\.scenePhase) private var scenePhase

    private var network: NetworkKind {
        NetworkKind(rawValue: snapshot?.network ?? "") ?? ChainConfig.fromBundle().network
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    balanceHeader
                        .padding(.top, 20)
                        .padding(.horizontal, 20)

                    actionRow
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    passkeySection
                        .padding(.horizontal, 20)
                        .padding(.top, 12)

                    if let snapshot, !snapshot.recent.isEmpty {
                        activity(snapshot)
                            .padding(.top, 18)
                    } else if snapshot != nil {
                        emptyActivity
                            .padding(.top, 28)
                    }

                    footer
                        .padding(.horizontal, 28)
                        .padding(.top, 28)
                        .padding(.bottom, 24)
                }
            }
            .refreshable { snapshot = SharedSnapshot.load() }
            .navigationTitle("OrangeBubbles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        BitcoinMark(size: 22)
                        Text("OrangeBubbles")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                    }
                }
            }
        }
        .tint(Brand.orange)
        .sheet(isPresented: $showReceive) {
            HostReceiveView(network: network, onIssued: { snapshot = SharedSnapshot.load() })
        }
        .task { await ops.determineState() }
        .onChange(of: scenePhase) { _, phase in
            // The extension rewrites the snapshot on every refresh; re-read
            // whenever this app comes back to the front.
            if phase == .active { snapshot = SharedSnapshot.load() }
        }
        #if DEBUG
            // Test hook: `simctl launch … --args -issueReceiveAddress 1` runs
            // the same hand-out the Siri intent performs, inside the real
            // host-app process (App Group entitlement and all), and logs it.
            .task {
                guard UserDefaults.standard.bool(forKey: "issueReceiveAddress") else { return }
                let issued = SharedSnapshot.load()?.issueReceiveAddress()
                NSLog("debug issueReceiveAddress -> %@ (ledger now %@)",
                      issued ?? "nil", SharedSnapshot.issuedReceiveAddresses.joined(separator: ","))
            }
        #endif
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

    // MARK: - Balance (same header as the extension's Home)

    /// Watch-only: everything here comes from the App Group snapshot the
    /// extension publishes. No keys live in this process.
    private var balanceHeader: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Text("Balance")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                NetworkBadge(network: network)
            }

            if let snapshot {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.sats(snapshot.balanceSats))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(Brand.gradient)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text("sats")
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { fiatLine(snapshot); pendingPill(snapshot) }
                    VStack(spacing: 5) { fiatLine(snapshot); pendingPill(snapshot) }
                }

                Text("As of \(snapshot.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            } else {
                VStack(spacing: 12) {
                    BitcoinMark(size: 64)
                        .padding(.top, 10)
                    Text("Your wallet lives in Messages")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                    Text("Open a conversation, tap the app strip and choose OrangeBubbles once. Your balance and activity show up here after that.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func fiatLine(_ snapshot: SharedSnapshot) -> some View {
        HStack(spacing: 10) {
            Text("\(Format.btc(snapshot.balanceSats)) BTC")
                .font(.system(.caption, design: .monospaced))
            if let usd = snapshot.usdLine {
                Text("≈ \(usd)")
                    .font(.system(.caption, design: .rounded).weight(.medium))
            }
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private func pendingPill(_ snapshot: SharedSnapshot) -> some View {
        if snapshot.pendingSats > 0 {
            HStack(spacing: 3) {
                Image(systemName: "clock.fill").font(.system(size: 8))
                Text("\(Format.sats(snapshot.pendingSats)) pending")
            }
            .lineLimit(1)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(Brand.orangeDeep)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Brand.orange.opacity(0.12)))
        }
    }

    // MARK: - Actions (same tiles as the extension)

    private var actionRow: some View {
        AdaptiveStack(spacing: 10) {
            ActionTile(title: "Receive", systemImage: "arrow.down.left", filled: true) {
                showReceive = true
            }
            .disabled(snapshot == nil)

            // Sending stays in Messages on purpose: the Face ID review flow
            // and the receipt card live in the conversation.
            ActionTile(title: "Send in Messages", systemImage: "message.fill") {
                if let url = URL(string: "sms:") { UIApplication.shared.open(url) }
            }
        }
    }

    // MARK: - Passkey protection

    @ViewBuilder
    private var passkeySection: some View {
        switch ops.state {
        case .checking, .noWallet:
            EmptyView()
        case .upgradable:
            HStack(spacing: 10) {
                IconBubble(systemName: "person.badge.key.fill", tint: .green, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Harden your backup")
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                    Text("One Face ID makes it passkey-sealed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Upgrade") { Task { await ops.upgrade() } }
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        case .passkeyActive:
            InfoBanner(systemName: "checkmark.shield.fill", text: "Passkey protection is active. Your backup unlocks with Face ID on any of your devices.", tint: .green)
        case .lockedPasskeyBackup:
            VStack(spacing: 10) {
                InfoBanner(systemName: "faceid", text: "A passkey-sealed backup of your wallet is in iCloud. Unlock it here once; Messages picks it up from there.", tint: Brand.orange)
                Button { Task { await ops.unlock() } } label: {
                    Label("Unlock wallet with passkey", systemImage: "faceid")
                }
                .buttonStyle(ProminentButtonStyle())
            }
        case .working(let message):
            HStack(spacing: 10) {
                ProgressView().tint(Brand.orange)
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
        case .done(let message):
            InfoBanner(systemName: "checkmark.circle.fill", text: message, tint: .green)
        case .failed(let message):
            VStack(spacing: 8) {
                InfoBanner(systemName: "exclamationmark.triangle.fill", text: message, tint: .red)
                Button("Try again") { Task { await ops.determineState() } }
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
            }
        }
    }

    // MARK: - Activity (same rows as the extension)

    private func activity(_ snapshot: SharedSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent activity")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            ForEach(Array(snapshot.recent.prefix(4).enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 68) }
                HStack(spacing: 12) {
                    IconBubble(
                        systemName: item.incoming ? "arrow.down.left" : "arrow.up.right",
                        tint: item.incoming ? .green : Brand.orange
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.incoming ? "Received" : (item.amountSats == 0 ? "Sent to yourself" : "Sent"))
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        if item.confirmed {
                            Text(item.timestamp.map { Format.relative($0) } ?? "Confirmed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 3) {
                                Image(systemName: "clock.fill").font(.system(size: 8))
                                Text("Pending")
                            }
                            .font(.system(.caption, design: .rounded).weight(.medium))
                            .foregroundStyle(Brand.orangeDeep)
                        }
                    }
                    Spacer()
                    Text(item.amountSats == 0 && !item.incoming ? "±0" : (item.incoming ? "+" : "−") + Format.sats(item.amountSats))
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(item.incoming ? .green : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }

            Text("Tap a payment in Messages for details, or to speed it up.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
    }

    private var emptyActivity: some View {
        VStack(spacing: 10) {
            IconBubble(systemName: "sparkles", size: 46)
            Text("No activity yet")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
            Text("Tap **Receive** to get your first sats.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        Text("Your keys never leave your iPhone. The encrypted backup lives in your own iCloud.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
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
