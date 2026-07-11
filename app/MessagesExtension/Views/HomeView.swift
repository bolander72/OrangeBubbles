import SwiftUI
import WalletKit

struct HomeView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject var bridge: ExtensionBridge

    @State private var showReceive = false
    @State private var showSend = false
    @State private var showSettings = false
    @State private var speedingUp = false

    var body: some View {
        VStack(spacing: 0) {
            balanceHeader
                .padding(.top, bridge.isCompact ? 10 : 20)
                .padding(.horizontal, 20)
                .overlay(alignment: .topTrailing) {
                    if !bridge.isCompact {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Color(.secondarySystemBackground)))
                        }
                        .accessibilityLabel("Wallet settings")
                        .padding(.top, 14)
                        .padding(.trailing, 16)
                    }
                }

            actionRow
                .padding(.horizontal, 20)
                .padding(.top, 16)

            if !store.backupInICloud {
                InfoBanner(
                    systemName: "icloud.slash.fill",
                    text: "iCloud unavailable — this wallet lives only on this device."
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            if !bridge.isCompact {
                activity
                    .padding(.top, 18)
            }

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showReceive) {
            ReceiveView(store: store, bridge: bridge)
        }
        .sheet(isPresented: $showSend) {
            SendView(store: store, bridge: bridge, prefill: nil)
        }
        .sheet(item: incomingCard) { card in
            CardStatusView(store: store, bridge: bridge, card: card)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .task { await store.refresh() }
    }

    /// Any tapped card (request or receipt) opens the live status view.
    private var incomingCard: Binding<IncomingCard?> {
        Binding(
            get: { store.incomingRequest },
            set: { if $0 == nil { store.incomingRequest = nil } }
        )
    }

    // MARK: - Balance

    private var balanceHeader: some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Text("Balance")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                NetworkBadge(network: store.chain.network)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.sats(store.balance.totalSats))
                    .font(.system(size: bridge.isCompact ? 30 : 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.gradient)
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.4), value: store.balance.totalSats)
                Text("sats")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("\(Format.btc(store.balance.totalSats)) BTC")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let usd = store.usdApprox(store.balance.totalSats) {
                    Text(usd)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if store.balance.pendingSats > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.fill").font(.system(size: 8))
                        Text("\(Format.sats(store.balance.pendingSats)) pending")
                    }
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(Brand.orangeDeep)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Brand.orange.opacity(0.12)))
                }

                if store.isSyncing {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                bridge.requestExpanded()
                showReceive = true
            } label: {
                Label("Receive", systemImage: "arrow.down.left")
            }
            .buttonStyle(ProminentButtonStyle())

            Button {
                bridge.requestExpanded()
                showSend = true
            } label: {
                Label("Send", systemImage: "arrow.up.right")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(store.balance.totalSats == 0)
            .opacity(store.balance.totalSats == 0 ? 0.45 : 1)
        }
    }

    // MARK: - Activity

    private var activity: some View {
        Group {
            if store.transactions.isEmpty {
                emptyActivity
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Activity")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 6)

                        ForEach(store.transactions) { tx in
                            TransactionRow(
                                tx: tx,
                                explorerURL: store.chain.explorerURL(txid: tx.txid),
                                onSpeedUp: (tx.direction == .outgoing && !tx.confirmed && !speedingUp)
                                    ? { speedUp(tx.txid) }
                                    : nil
                            )
                            if tx.id != store.transactions.last?.id {
                                Divider().padding(.leading, 68)
                            }
                        }
                    }
                }
                .refreshable { await store.refresh() }
            }
        }
    }

    private func speedUp(_ txid: String) {
        speedingUp = true
        Task {
            defer { speedingUp = false }
            do {
                _ = try await store.speedUp(txid: txid)
                Haptics.success()
            } catch {
                Haptics.warning()
                store.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    private var emptyActivity: some View {
        VStack(spacing: 10) {
            IconBubble(systemName: "sparkles", size: 46)
            Text("No activity yet")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
            Text("Tap **Receive** to share a payment\nrequest in this conversation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
    }
}

struct TransactionRow: View {
    @Environment(\.openURL) private var openURL
    let tx: WalletTransaction
    let explorerURL: URL
    var onSpeedUp: (() -> Void)?

    var body: some View {
        Button {
            openURL(explorerURL)
        } label: {
            HStack(spacing: 12) {
                IconBubble(
                    systemName: tx.direction == .incoming ? "arrow.down.left" : "arrow.up.right",
                    tint: tx.direction == .incoming ? .green : Brand.orange
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(tx.direction == .incoming ? "Received" : "Sent")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.primary)
                    if tx.confirmed {
                        Text(tx.timestamp.map { Format.relative($0) } ?? "Confirmed")
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

                VStack(alignment: .trailing, spacing: 3) {
                    Text((tx.direction == .incoming ? "+" : "−") + Format.sats(tx.amountSats))
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(tx.direction == .incoming ? .green : .primary)

                    if let onSpeedUp {
                        Button {
                            onSpeedUp()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "hare.fill").font(.system(size: 8))
                                Text("Speed Up")
                            }
                            .font(.system(.caption2, design: .rounded).weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Brand.orange.opacity(0.13)))
                            .foregroundStyle(Brand.orangeDeep)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Speed up this payment with a higher fee")
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(tx.direction == .incoming ? "Received" : "Sent") \(Format.sats(tx.amountSats)) sats, \(tx.confirmed ? "confirmed" : "pending")"
        )
    }
}
