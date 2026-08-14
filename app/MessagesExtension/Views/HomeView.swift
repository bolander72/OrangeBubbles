import SwiftUI
import WalletKit

struct HomeView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject var bridge: ExtensionBridge
    @StateObject private var ceremony: PotCeremonyController

    init(store: WalletStore, bridge: ExtensionBridge) {
        _store = ObservedObject(wrappedValue: store)
        _bridge = ObservedObject(wrappedValue: bridge)
        _ceremony = StateObject(wrappedValue: PotCeremonyController(store: store, bridge: bridge))
    }

    @State private var showStartPot = false
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showSettings = false
    @State private var showPots = false
    private var pots: [VaultRecord] { VaultStore().all() }
    /// Every pot bound to the chat the app is currently open in.
    private var chatPots: [VaultRecord] {
        guard let key = bridge.chatKey else { return [] }
        return pots.filter { $0.chatKey == key }
    }
    /// Pots not already surfaced as this chat's banners.
    private var otherPots: [VaultRecord] {
        let here = Set(chatPots.map(\.id))
        return pots.filter { !here.contains($0.id) }
    }

    private var potsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(chatPots.isEmpty ? "Shared Pots" : "Other Pots")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Button("See all") { showPots = true }
                    .font(.system(.caption, design: .rounded).weight(.semibold))
            }
            .padding(.horizontal, 20)
            ForEach(otherPots.prefix(3)) { record in
                Button { showPots = true } label: {
                    HStack(spacing: 12) {
                        Text(potEmoji(for: record.name))
                            .font(.system(size: 26))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Brand.subtleGradient))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(record.memberCount) people · any \(record.threshold) approve")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.quaternary)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
    private func chatPotBanner(_ pot: VaultRecord, showEyebrow: Bool = true) -> some View {
        Button { showPots = true } label: {
            HStack(spacing: 12) {
                Text(potEmoji(for: pot.name))
                    .font(.system(size: 30))
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.25)))
                VStack(alignment: .leading, spacing: 2) {
                    if showEyebrow {
                        HStack(spacing: 6) {
                            Text("This chat's pot")
                                .font(.system(.caption2, design: .rounded).weight(.bold))
                                .foregroundStyle(.white.opacity(0.9)).textCase(.uppercase)
                            if bridge.chatParticipantCount > 0 {
                                Text("· \(bridge.chatParticipantCount) here")
                                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                    }
                    Text(pot.name)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                    RosterStrip(record: pot)
                        .environment(\.colorScheme, .dark)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.9))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Brand.gradient))
        }
        .buttonStyle(.plain)
    }

    @AppStorage("passkeyNudgeDismissed.v1") private var passkeyNudgeDismissed = false
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
                            Image(systemName: "gearshape")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(Color(.secondaryLabel))
                                .frame(width: 36, height: 36)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Wallet settings")
                        .padding(.top, 10)
                        .padding(.trailing, 12)
                    }
                }

            actionRow
                .padding(.horizontal, 20)
                .padding(.top, 16)

            // This chat has one or more pots → surface them right by the
            // balance, the first thing you'd look for when the group is
            // talking money.
            if !chatPots.isEmpty, !bridge.isCompact {
                VStack(spacing: 10) {
                    if chatPots.count > 1 {
                        Text("This chat's pots")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(chatPots) { pot in chatPotBanner(pot, showEyebrow: chatPots.count == 1) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            // Start a pot right here in the chat, over iMessage (no server).
            if ceremony.canStart, chatPots.isEmpty, !bridge.isCompact {
                Button { showStartPot = true } label: {
                    Label("Start a pot in this chat", systemImage: "plus.circle.fill")
                }
                .buttonStyle(ProminentButtonStyle())
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            if !store.backupInICloud {
                InfoBanner(
                    systemName: "icloud.slash.fill",
                    text: "Heads up: iCloud isn't reachable, so this wallet is only backed up on this device for now.",
                    tint: .blue
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            // Passkey sealing can't be the silent default (registration
            // always shows a system sheet, in the host app) — so it
            // advertises itself until done or dismissed. ADR 0002/0004.
            if store.canUpgradeToPasskey, !passkeyNudgeDismissed, !bridge.isCompact {
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
                    Button("Upgrade") {
                        bridge.openHostApp("upgrade")
                    }
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    Button {
                        passkeyNudgeDismissed = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(.tertiaryLabel))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }

            if !bridge.isCompact, !store.outstandingGifts.isEmpty {
                giftsSection
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            if !bridge.isCompact, !otherPots.isEmpty {
                potsSection
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            if !bridge.isCompact {
                activity
                    .padding(.top, 18)
            }

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showPots) { PotsView(store: store, chatKey: bridge.chatKey, chatParticipantCount: bridge.chatParticipantCount) }
        .sheet(isPresented: $showStartPot) {
            StartPotSheet { name, emoji in ceremony.create(name: name, emoji: emoji) }
        }
        .sheet(isPresented: Binding(
            get: { ceremony.presentSetup },
            set: { if !$0 { ceremony.dismissSetup() } }
        )) {
            if let c = ceremony.coordinator {
                SettingUpPotView(
                    coordinator: c,
                    emoji: c.config.emoji ?? potEmoji(for: c.config.name),
                    onOpen: { ceremony.dismissSetup() },
                    onClose: { ceremony.dismissSetup() })
            }
        }
        // Note: we intentionally do NOT cover the compose field with the pot
        // detail while a ceremony is in flight — the user needs to tap Send on
        // the staged invite card. The pot appears in "This chat's pots" once
        // setup completes; tap it there to open the detail.
        .sheet(isPresented: $showReceive) {
            ReceiveView(store: store, bridge: bridge)
        }
        .sheet(isPresented: $showSend) {
            SendView(store: store, bridge: bridge, prefill: nil)
        }
        .sheet(item: incomingCard) { card in
            switch card.kind {
            case .payment(let request, let isReceipt):
                CardStatusView(store: store, bridge: bridge, request: request, isReceipt: isReceipt)
            case .claim(let voucher):
                ClaimCardView(store: store, voucher: voucher)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store, bridge: bridge)
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

    @State private var giftToManage: ClaimVoucher?

    private var giftsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Outstanding gifts")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(store.outstandingGifts) { gift in
                Button {
                    giftToManage = gift.voucher
                } label: {
                    HStack(spacing: 10) {
                        IconBubble(systemName: "gift.fill", tint: .purple, size: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(Format.sats(gift.voucher.amountSats)) sats")
                                .font(.system(.footnote, design: .rounded).weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(gift.voucher.isExpired
                                ? "Expired — tap to reclaim"
                                : "Unclaimed · expires \(Format.relative(gift.voucher.expiresAt))")
                                .font(.caption2)
                                .foregroundStyle(gift.voucher.isExpired ? Color.orange : Color.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: giftBinding) { voucher in
            ClaimCardView(store: store, voucher: voucher)
        }
    }

    private var giftBinding: Binding<ClaimVoucher?> {
        Binding(get: { giftToManage }, set: { giftToManage = $0 })
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

    /// An outgoing tx whose outputs all came back to us — a self-transfer.
    private var isSelfTransfer: Bool {
        tx.direction == .outgoing && tx.amountSats == 0
    }

    private var rowTitle: String {
        if isSelfTransfer { return "Sent to yourself" }
        return tx.direction == .incoming ? "Received" : "Sent"
    }

    private var amountLabel: String {
        if isSelfTransfer {
            return tx.feeSats.map { "−\(Format.sats($0)) fee" } ?? "±0"
        }
        return (tx.direction == .incoming ? "+" : "−") + Format.sats(tx.amountSats)
    }

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
                    Text(rowTitle)
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
                    Text(amountLabel)
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
