import SwiftUI
import WalletKit

/// Opens when anyone taps a gift card (ADR 0005). Checks the chain and
/// offers the right action for the viewer: recipients claim; the sender
/// (recognized by their local gift ledger) can cancel or reclaim.
struct ClaimCardView: View {
    @ObservedObject var store: WalletStore
    let voucher: ClaimVoucher

    @Environment(\.dismiss) private var dismiss
    @State private var status: Status = .checking
    @State private var redeeming = false
    @State private var claimedSats: UInt64?

    private enum Status: Equatable {
        case checking
        case waitingForFunding
        case claimable
        case alreadySwept
        case unknown
    }

    private var isSender: Bool { store.isOwnGift(voucher) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    detailsCard
                    actions
                }
                .padding(20)
            }
            .navigationTitle("Bitcoin gift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
            }
        }
        .task { await check() }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 10) {
            if let claimedSats {
                IconBubble(systemName: "checkmark", tint: .green, size: 72)
                Text("+\(Format.sats(claimedSats)) sats")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text(isSender ? "Returned to your wallet." : "Added to your Satchel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                switch status {
                case .checking:
                    ProgressView().controlSize(.large).tint(Brand.orange)
                        .frame(width: 72, height: 72)
                    Text("Checking the gift…")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                case .waitingForFunding:
                    IconBubble(systemName: "hourglass", tint: Brand.orange, size: 72)
                    Text("On its way")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("The gift payment hasn't reached the network yet — try again in a moment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .claimable:
                    IconBubble(systemName: "gift.fill", tint: .purple, size: 72)
                    Text("\(Format.sats(voucher.amountSats)) sats")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                    Text(isSender
                        ? "Your gift is waiting to be claimed."
                        : "Someone sent you bitcoin.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .alreadySwept:
                    IconBubble(systemName: "checkmark", tint: .green, size: 72)
                    Text("Already claimed")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text("This gift has been swept — a claim card only works once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .unknown:
                    IconBubble(systemName: "wifi.slash", tint: .gray, size: 72)
                    Text("Couldn't check the gift")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                }
            }
        }
        .padding(.top, 8)
        .animation(.spring(response: 0.35), value: status)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            row("Amount", "\(Format.sats(voucher.amountSats)) sats")
            Divider().padding(.horizontal, 16)
            row(
                voucher.isExpired ? "Expired" : "Expires",
                voucher.expiresAt.formatted(date: .abbreviated, time: .omitted)
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var actions: some View {
        if claimedSats == nil, status == .claimable {
            VStack(spacing: 10) {
                Button {
                    Task { await redeem() }
                } label: {
                    if redeeming {
                        ProgressView().tint(.white)
                    } else if isSender {
                        Label(
                            voucher.isExpired ? "Reclaim gift" : "Cancel gift & take it back",
                            systemImage: "arrow.uturn.backward"
                        )
                    } else {
                        Label("Claim \(Format.sats(voucher.amountSats)) sats", systemImage: "gift.fill")
                    }
                }
                .buttonStyle(ProminentButtonStyle())
                .disabled(redeeming)

                Text(isSender
                    ? "Anyone with this message can still claim it until you take it back."
                    : "A small network fee comes out of the gift when you claim.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - Actions

    private func check() async {
        let probe = StatusProbe()
        for (index, esplora) in store.chain.esploraURLs.enumerated() {
            do {
                let activity = try await probe.addressActivity(address: voucher.address, esploraURL: esplora)
                if activity.wasSwept {
                    status = .alreadySwept
                } else if activity.hasAny {
                    status = .claimable
                } else {
                    status = .waitingForFunding
                }
                return
            } catch {
                if index == store.chain.esploraURLs.count - 1 { status = .unknown }
            }
        }
    }

    private func redeem() async {
        redeeming = true
        defer { redeeming = false }
        do {
            claimedSats = try await store.redeem(voucher)
            Haptics.success()
        } catch {
            Haptics.warning()
            store.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            await check()
        }
    }
}
