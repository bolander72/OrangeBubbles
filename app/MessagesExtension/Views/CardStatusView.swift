import SwiftUI
import WalletKit

/// Opens when anyone taps a payment card in the transcript. Checks the
/// chain live and shows where the payment stands; unpaid requests offer
/// Pay, and settled ones offer sharing an updated card that replaces the
/// original bubble (same MSSession).
struct CardStatusView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject var bridge: ExtensionBridge
    let card: IncomingCard

    @Environment(\.dismiss) private var dismiss
    @State private var status: Status = .checking
    @State private var showPay = false

    private enum Status: Equatable {
        case checking
        case awaitingPayment
        case inMempool(sats: UInt64)
        case paidConfirmed(sats: UInt64)
        case txPending
        case txConfirmed(when: Date?)
        case unknown(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    statusHeader
                    detailsCard
                    actions
                }
                .padding(20)
            }
            .navigationTitle(card.isReceipt ? "Payment" : "Payment request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
            }
        }
        .task { await check() }
        .sheet(isPresented: $showPay) {
            SendView(store: store, bridge: bridge, prefill: card.request)
        }
    }

    // MARK: - Pieces

    private var statusHeader: some View {
        VStack(spacing: 10) {
            statusIcon
            Text(statusTitle)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .multilineTextAlignment(.center)
            if let subtitle = statusSubtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
        .animation(.spring(response: 0.35), value: status)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .checking:
            ProgressView().controlSize(.large).tint(Brand.orange)
                .frame(width: 72, height: 72)
        case .awaitingPayment:
            IconBubble(systemName: "hourglass", tint: Brand.orange, size: 72)
        case .inMempool, .txPending:
            IconBubble(systemName: "clock.fill", tint: Brand.orange, size: 72)
        case .paidConfirmed, .txConfirmed:
            IconBubble(systemName: "checkmark", tint: .green, size: 72)
        case .unknown:
            IconBubble(systemName: "wifi.slash", tint: .gray, size: 72)
        }
    }

    private var statusTitle: String {
        switch status {
        case .checking: return "Checking the network…"
        case .awaitingPayment: return "Awaiting payment"
        case .inMempool: return "Payment on its way"
        case .paidConfirmed: return "Paid"
        case .txPending: return "Pending confirmation"
        case .txConfirmed: return "Confirmed"
        case .unknown: return "Couldn't check status"
        }
    }

    private var statusSubtitle: String? {
        switch status {
        case .checking:
            return nil
        case .awaitingPayment:
            return card.request.amountSats.map { "Requesting \(Format.sats($0)) sats" } ?? "No payment seen yet"
        case .inMempool(let sats):
            return "\(Format.sats(sats)) sats in the mempool — usually confirms within the hour."
        case .paidConfirmed(let sats):
            return "\(Format.sats(sats)) sats received and confirmed."
        case .txPending:
            return "Broadcast and waiting to be mined."
        case .txConfirmed(let when):
            return when.map { "Confirmed \(Format.relative($0))." } ?? "Confirmed on-chain."
        case .unknown(let why):
            return why
        }
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            if let sats = card.request.amountSats {
                row("Amount", "\(Format.sats(sats)) sats")
                Divider().padding(.horizontal, 16)
            }
            row("Address", Format.shortAddress(card.request.address, prefix: 14, suffix: 10), monospaced: true)
            if let txid = card.request.txid {
                Divider().padding(.horizontal, 16)
                row("Transaction", "\(txid.prefix(10))…\(txid.suffix(8))", monospaced: true)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func row(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced
                    ? .system(.footnote, design: .monospaced).weight(.medium)
                    : .system(.subheadline, design: .rounded).weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            // Unpaid request → the primary action is paying it.
            if !card.isReceipt, case .awaitingPayment = status {
                Button {
                    showPay = true
                } label: {
                    Label("Pay with Wizard Wallet", systemImage: "bitcoinsign.circle.fill")
                }
                .buttonStyle(ProminentButtonStyle())
                .disabled(store.balance.totalSats == 0)
                .opacity(store.balance.totalSats == 0 ? 0.45 : 1)
            }

            // Settled either way → offer replacing the card with its outcome.
            if canShareUpdate {
                Button {
                    var updated = card.request
                    updated.label = nil
                    bridge.insertCard(for: updated, kind: .sent, updateSelectedCard: true)
                    dismiss()
                } label: {
                    Label("Share updated status", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(QuietButtonStyle())
            }

            if let txid = card.request.txid {
                Link(destination: store.chain.explorerURL(txid: txid)) {
                    HStack(spacing: 5) {
                        Image(systemName: "safari")
                        Text("View on explorer")
                    }
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                }
                .padding(.top, 2)
            }
        }
    }

    private var canShareUpdate: Bool {
        switch status {
        case .paidConfirmed, .txConfirmed:
            return true
        default:
            return false
        }
    }

    // MARK: - Chain check

    private func check() async {
        let probe = StatusProbe()
        do {
            if let txid = card.request.txid {
                let tx = try await probe.txConfirmation(txid: txid, esploraURL: store.chain.esploraURL)
                status = tx.confirmed ? .txConfirmed(when: tx.blockTime) : .txPending
            } else {
                let activity = try await probe.addressActivity(
                    address: card.request.address,
                    esploraURL: store.chain.esploraURL
                )
                if activity.hasConfirmed {
                    status = .paidConfirmed(sats: activity.confirmedReceivedSats)
                } else if activity.hasPending {
                    status = .inMempool(sats: activity.mempoolReceivedSats)
                } else {
                    status = .awaitingPayment
                }
            }
        } catch {
            status = .unknown("Check your connection and try again.")
        }
    }
}
