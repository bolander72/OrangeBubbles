import SwiftUI
import WalletKit

struct SendView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject var bridge: ExtensionBridge
    let prefill: PaymentRequest?

    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case compose
        case review(SignedSend)
        case broadcasting
        case sent(txid: String, details: PreparedSend)
    }

    @State private var stage: Stage = .compose
    @State private var address = ""
    @State private var amountText = ""
    @State private var feeChoice: FeeChoice = .normal
    @State private var working = false
    /// Send Max: sweep every UTXO; the fee comes out of the total.
    @State private var sendMax = false

    enum FeeChoice: String, CaseIterable, Identifiable {
        case slow = "Slow"
        case normal = "Normal"
        case fast = "Fast"
        var id: String { rawValue }

        var eta: String {
            switch self {
            case .slow: return "~1 hour"
            case .normal: return "~30 min"
            case .fast: return "next block"
            }
        }

        var icon: String {
            switch self {
            case .slow: return "tortoise.fill"
            case .normal: return "figure.walk"
            case .fast: return "hare.fill"
            }
        }

        func satPerVb(_ tiers: FeeTiers) -> UInt64 {
            switch self {
            case .slow: return max(tiers.hourFee, tiers.minimumFee)
            case .normal: return max(tiers.halfHourFee, tiers.minimumFee)
            case .fast: return max(tiers.fastestFee, tiers.minimumFee)
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(doneButtonTitle) { dismiss() }
                            .font(.system(.body, design: .rounded).weight(.medium))
                    }
                }
        }
        .onAppear {
            if let prefill {
                address = prefill.address
                if let sats = prefill.amountSats { amountText = String(sats) }
            }
        }
        .interactiveDismissDisabled(isMidFlight)
    }

    private var navigationTitle: String {
        switch stage {
        case .compose: return "Send Bitcoin"
        case .review: return "Confirm"
        case .broadcasting: return ""
        case .sent: return "Sent"
        }
    }

    private var doneButtonTitle: String {
        if case .sent = stage { return "Done" }
        return "Cancel"
    }

    private var isMidFlight: Bool {
        switch stage {
        case .broadcasting: return true
        default: return working
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .compose:
            composeForm
        case .review(let send):
            reviewSheet(send)
        case .broadcasting:
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(Brand.orange)
                Text("Broadcasting…")
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .sent(let txid, let details):
            sentView(txid: txid, details: details)
        }
    }

    // MARK: - Compose

    private var addressIsValid: Bool {
        store.isValidAddress(address)
    }

    private var composeForm: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Destination
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("To")
                    HStack(spacing: 8) {
                        TextField("Bitcoin address", text: $address, axis: .vertical)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .lineLimit(2)

                        if address.isEmpty {
                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    address = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Text("Paste")
                                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(Brand.orange.opacity(0.13)))
                                    .foregroundStyle(Brand.orangeDeep)
                            }
                        } else {
                            Image(systemName: addressIsValid ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(addressIsValid ? .green : .red)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .padding(14)
                    .background(fieldBackground)

                    if let prefill, prefill.address == address, let label = prefill.label, !label.isEmpty {
                        Text("Requested by \(label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                }

                // Amount
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Amount")
                    VStack(spacing: 4) {
                        if sendMax {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("Everything")
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .foregroundStyle(Brand.gradient)
                                Text("−fee")
                                    .font(.system(.callout, design: .rounded).weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            Text("\(Format.sats(store.balance.confirmedSats)) sats minus the network fee")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                TextField("0", text: $amountText)
                                    .keyboardType(.numberPad)
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .accessibilityLabel("Amount in sats")
                                Text("sats")
                                    .font(.system(.callout, design: .rounded).weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)

                            if let sats = parsedAmount {
                                HStack(spacing: 8) {
                                    Text("\(Format.btc(sats)) BTC")
                                        .font(.system(.caption, design: .monospaced))
                                    if let usd = store.usdApprox(sats) {
                                        Text(usd)
                                            .font(.system(.caption, design: .rounded).weight(.medium))
                                    }
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 14)
                    .background(fieldBackground)

                    HStack {
                        Text("Available: \(Format.sats(store.balance.confirmedSats)) sats")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.25)) { sendMax.toggle() }
                            Haptics.tap()
                        } label: {
                            Text(sendMax ? "Enter amount" : "Max")
                                .font(.system(.caption, design: .rounded).weight(.bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(sendMax ? Brand.orange.opacity(0.25) : Brand.orange.opacity(0.13)))
                                .foregroundStyle(Brand.orangeDeep)
                        }
                        .accessibilityLabel(sendMax ? "Switch to entering an amount" : "Send entire balance")
                    }
                    .padding(.horizontal, 4)

                    if dustWarning {
                        Text("Minimum send is \(Format.sats(dustLimitSats)) sats.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 4)
                    }
                }

                // Fee
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Network fee")
                    HStack(spacing: 8) {
                        ForEach(FeeChoice.allCases) { choice in
                            feeOption(choice)
                        }
                    }
                }

                if isLargeSend {
                    InfoBanner(
                        systemName: "exclamationmark.triangle.fill",
                        text: "This sends most of your balance. Bitcoin payments can't be reversed — double-check the address."
                    )
                }

                Button {
                    Task { await prepare() }
                } label: {
                    if working {
                        ProgressView().tint(.white)
                    } else {
                        Label("Review with Face ID", systemImage: "faceid")
                    }
                }
                .buttonStyle(ProminentButtonStyle())
                .disabled(!canReview || working)
                .opacity(canReview ? 1 : 0.45)
                .padding(.top, 4)
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.leading, 4)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.secondarySystemBackground))
    }

    private func feeOption(_ choice: FeeChoice) -> some View {
        let selected = feeChoice == choice
        return Button {
            withAnimation(.spring(response: 0.25)) { feeChoice = choice }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: choice.icon)
                    .font(.footnote.weight(.semibold))
                Text(choice.rawValue)
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                Text(choice.eta)
                    .font(.system(size: 10, design: .rounded))
                Text("\(choice.satPerVb(store.feeTiers)) sat/vB")
                    .font(.system(size: 9, design: .monospaced))
                    .opacity(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Brand.subtleGradient) : AnyShapeStyle(Color(.secondarySystemBackground)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Brand.orange : .clear, lineWidth: 1.5)
            )
            .foregroundStyle(selected ? Brand.orangeDeep : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.rawValue) fee, \(choice.eta), \(choice.satPerVb(store.feeTiers)) sats per virtual byte")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var parsedAmount: UInt64? {
        UInt64(amountText.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
    }

    private var dustWarning: Bool {
        guard !sendMax, let sats = parsedAmount else { return false }
        return sats < dustLimitSats
    }

    private var canReview: Bool {
        addressIsValid && (sendMax || (parsedAmount.map { $0 >= dustLimitSats } ?? false))
    }

    private var isLargeSend: Bool {
        if sendMax { return true }
        guard let sats = parsedAmount, store.balance.confirmedSats > 0 else { return false }
        return Double(sats) / Double(store.balance.confirmedSats) > 0.75
    }

    private func prepare() async {
        guard sendMax || parsedAmount != nil else { return }
        working = true
        defer { working = false }
        do {
            let send = try await store.prepareSend(
                to: address.trimmingCharacters(in: .whitespacesAndNewlines),
                amountSats: parsedAmount ?? 0,
                feeRateSatPerVb: feeChoice.satPerVb(store.feeTiers),
                drain: sendMax
            )
            withAnimation { stage = .review(send) }
        } catch {
            Haptics.warning()
            store.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Review

    private func reviewSheet(_ send: SignedSend) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 0) {
                receiptRow("To", Format.shortAddress(send.details.destinationAddress, prefix: 14, suffix: 10), monospaced: true)
                Divider().padding(.horizontal, 16)
                receiptRow("Amount", "\(Format.sats(send.details.amountSats)) sats")
                Divider().padding(.horizontal, 16)
                receiptRow("Network fee", "\(Format.sats(send.details.feeSats)) sats")
                Divider().padding(.horizontal, 16)
                receiptRow("Total", "\(Format.sats(send.details.totalSats)) sats", emphasized: true)
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )

            Text("Signed and ready. Nothing is sent until you confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await broadcast(send) }
            } label: {
                Label("Send now", systemImage: "paperplane.fill")
            }
            .buttonStyle(ProminentButtonStyle())

            Button("Back") {
                withAnimation { stage = .compose }
            }
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func receiptRow(_ title: String, _ value: String, monospaced: Bool = false, emphasized: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(
                    monospaced
                        ? .system(.footnote, design: .monospaced).weight(.medium)
                        : .system(.subheadline, design: .rounded).weight(emphasized ? .bold : .semibold)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func broadcast(_ send: SignedSend) async {
        withAnimation { stage = .broadcasting }
        do {
            let txid = try await store.broadcast(send)
            Haptics.success()
            withAnimation(.spring(response: 0.4)) { stage = .sent(txid: txid, details: send.details) }
        } catch {
            Haptics.warning()
            store.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            withAnimation { stage = .review(send) }
        }
    }

    // MARK: - Sent

    private func sentView(txid: String, details: PreparedSend) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 10)

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: "checkmark")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)
            }
            .transition(.scale.combined(with: .opacity))

            VStack(spacing: 4) {
                Text("Sent \(Format.sats(details.amountSats)) sats")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text("On its way — usually confirms within the hour.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Link(destination: store.chain.explorerURL(txid: txid)) {
                HStack(spacing: 5) {
                    Image(systemName: "safari")
                    Text("View transaction")
                }
                .font(.system(.subheadline, design: .rounded).weight(.medium))
            }

            Button {
                let receipt = PaymentRequest(
                    address: details.destinationAddress,
                    amountSats: details.amountSats,
                    txid: txid
                )
                bridge.insertCard(for: receipt, kind: .sent)
                dismiss()
            } label: {
                Label("Share receipt in chat", systemImage: "message.fill")
            }
            .buttonStyle(ProminentButtonStyle())

            Spacer(minLength: 10)
        }
        .padding(20)
    }
}
