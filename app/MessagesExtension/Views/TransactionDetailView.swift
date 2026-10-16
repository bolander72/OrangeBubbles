import SwiftUI
import WalletKit

/// One transaction, in-app — so tapping a row never throws the user out
/// of Messages into Safari. The explorer stays one tap away at the bottom.
struct TransactionDetailView: View {
    @ObservedObject var store: WalletStore
    let txid: String

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var speedingUp = false

    private var tx: WalletTransaction? {
        store.transactions.first { $0.txid == txid }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let tx {
                        header(tx)
                        DetailCard(rows: rows(tx))
                        txidChip
                        if tx.direction == .outgoing, !tx.confirmed {
                            speedUpButton
                        }
                    } else {
                        // Just broadcast and not yet in the list, or gone.
                        IconBubble(systemName: "clock.fill", tint: Brand.orange, size: 72)
                        Text("Waiting for the network")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        txidChip
                    }
                    Link(destination: store.chain.explorerURL(txid: txid)) {
                        HStack(spacing: 5) {
                            Image(systemName: "safari")
                            Text("View on explorer")
                        }
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                    }
                    .padding(.top, 2)
                }
                .padding(20)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
            }
        }
    }

    private var title: String {
        guard let tx else { return "Transaction" }
        if tx.direction == .outgoing, tx.amountSats == 0 { return "Sent to yourself" }
        return tx.direction == .incoming ? "Received" : "Sent"
    }

    private func header(_ tx: WalletTransaction) -> some View {
        VStack(spacing: 10) {
            IconBubble(
                systemName: tx.confirmed
                    ? (tx.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
                    : "clock.fill",
                tint: tx.confirmed ? (tx.direction == .incoming ? .green : Brand.orange) : Brand.orange,
                size: 72
            )
            Text(amountLine(tx))
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(tx.direction == .incoming ? .green : .primary)
                .monospacedDigit()
            if let usd = store.usdApprox(tx.amountSats) {
                Text(usd)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(tx.confirmed ? "Confirmed" : "Pending — waiting to be mined")
                .font(.footnote)
                .foregroundStyle(tx.confirmed ? Color.secondary : Brand.orangeDeep)
        }
        .padding(.top, 8)
    }

    private func amountLine(_ tx: WalletTransaction) -> String {
        if tx.direction == .outgoing, tx.amountSats == 0 {
            return tx.feeSats.map { "−\(Format.sats($0)) sats fee" } ?? "±0 sats"
        }
        return (tx.direction == .incoming ? "+" : "−") + Format.sats(tx.amountSats) + " sats"
    }

    private func rows(_ tx: WalletTransaction) -> [DetailRow] {
        var rows: [DetailRow] = []
        if let when = tx.timestamp {
            rows.append(DetailRow(
                title: tx.confirmed ? "Confirmed" : "First seen",
                value: when.formatted(date: .abbreviated, time: .shortened)
            ))
        } else {
            rows.append(DetailRow(title: "Status", value: tx.confirmed ? "Confirmed" : "Pending"))
        }
        rows.append(DetailRow(title: "Amount", value: "\(Format.sats(tx.amountSats)) sats"))
        rows.append(DetailRow(title: "In BTC", value: "\(Format.btc(tx.amountSats))", monospaced: true))
        if let fee = tx.feeSats, tx.direction == .outgoing {
            rows.append(DetailRow(title: "Network fee", value: "\(Format.sats(fee)) sats"))
        }
        return rows
    }

    private var txidChip: some View {
        Button {
            UIPasteboard.general.string = txid
            Haptics.tap()
            withAnimation(.spring(response: 0.3)) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation { copied = false }
            }
        } label: {
            HStack(spacing: 8) {
                Text("\(txid.prefix(12))…\(txid.suffix(10))")
                    .font(.system(.footnote, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(copied ? .green : Brand.orangeDeep)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Transaction ID, tap to copy")
    }

    private var speedUpButton: some View {
        Button {
            speedingUp = true
            Task {
                defer { speedingUp = false }
                do {
                    _ = try await store.speedUp(txid: txid)
                    Haptics.success()
                    dismiss()
                } catch {
                    Haptics.warning()
                    store.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        } label: {
            if speedingUp {
                ProgressView().tint(.white)
            } else {
                Label("Speed up with a higher fee", systemImage: "hare.fill")
            }
        }
        .buttonStyle(ProminentButtonStyle())
        .disabled(speedingUp)
    }
}
