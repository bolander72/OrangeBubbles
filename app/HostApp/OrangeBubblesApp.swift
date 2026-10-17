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
    @State private var snapshot = SharedSnapshot.load()
    @State private var showReceive = false
    @Environment(\.scenePhase) private var scenePhase

    private let orange = Color(red: 0.97, green: 0.58, blue: 0.10)
    private let orangeDeep = Color(red: 0.93, green: 0.42, blue: 0.05)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    balanceCard
                    actions
                    walletSection
                    if let snapshot, !snapshot.recent.isEmpty {
                        recentActivity(snapshot)
                    }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .refreshable { snapshot = SharedSnapshot.load() }
            .navigationTitle("OrangeBubbles")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(orange)
        .sheet(isPresented: $showReceive) {
            HostReceiveView(onIssued: { snapshot = SharedSnapshot.load() })
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

    // MARK: - Balance

    /// Watch-only: everything here comes from the App Group snapshot the
    /// extension publishes. No keys live in this process.
    private var balanceCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("Balance")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let network = snapshot?.network, network != "bitcoin" {
                    Text(network.uppercased())
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.purple.opacity(0.14)))
                        .foregroundStyle(.purple)
                }
            }
            if let snapshot {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(SharedSnapshot.formatSats(snapshot.balanceSats))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [orange, orangeDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("sats")
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text("\(Self.btcString(snapshot.balanceSats)) BTC")
                        .font(.system(.caption, design: .monospaced))
                    if let usd = snapshot.usdLine {
                        Text("≈ \(usd)")
                            .font(.system(.caption, design: .rounded).weight(.medium))
                    }
                    if snapshot.pendingSats > 0 {
                        Text("\(SharedSnapshot.formatSats(snapshot.pendingSats)) pending")
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                            .foregroundStyle(orangeDeep)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(orange.opacity(0.12)))
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                Text("As of \(snapshot.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "bitcoinsign.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(orange)
                    .padding(.top, 6)
                Text("Open OrangeBubbles in a Messages conversation once and your wallet appears here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private static func btcString(_ sats: UInt64) -> String {
        String(format: "%d.%08d", Int(sats / 100_000_000), Int(sats % 100_000_000))
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                showReceive = true
            } label: {
                Label("Receive", systemImage: "arrow.down.left")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(LinearGradient(colors: [orange, orangeDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
            }
            .disabled(snapshot == nil)
            .opacity(snapshot == nil ? 0.45 : 1)

            // Sending stays in Messages on purpose: the Face ID review flow
            // and the receipt card live in the conversation.
            Link(destination: URL(string: "sms:")!) {
                Label("Send in Messages", systemImage: "message.fill")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(orangeDeep)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(orange.opacity(0.13))
                    )
            }
        }
    }

    // MARK: - Activity

    private func recentActivity(_ snapshot: SharedSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent activity")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 0) {
                ForEach(Array(snapshot.recent.prefix(4).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 56) }
                    HStack(spacing: 12) {
                        Image(systemName: item.incoming ? "arrow.down.left" : "arrow.up.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(item.incoming ? .green : orange)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill((item.incoming ? Color.green : orange).opacity(0.14)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.incoming ? "Received" : "Sent")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            Text(item.confirmed
                                 ? (item.timestamp.map { $0.formatted(.relative(presentation: .named)) } ?? "Confirmed")
                                 : "Pending")
                                .font(.caption)
                                .foregroundStyle(item.confirmed ? Color.secondary : orangeDeep)
                        }
                        Spacer()
                        Text((item.incoming ? "+" : "−") + SharedSnapshot.formatSats(item.amountSats))
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .foregroundStyle(item.incoming ? .green : .primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            Text("Tap any payment in Messages for details and to speed it up.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        Text("Your keys never leave your iPhone. The encrypted backup lives in your own iCloud.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 6)
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
