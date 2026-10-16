import SwiftUI
import WalletKit

struct SendView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject var bridge: ExtensionBridge
    let prefill: PaymentRequest?
    /// Chosen by the caller: Home's Send tile vs Gift tile. A prefilled
    /// request (tapped card) is always an address send.
    var mode: SendMode = .address

    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case compose
        case review(SignedSend)
        case reviewGift(ClaimVoucher, SignedSend)
        case broadcasting
        case sent(txid: String, details: PreparedSend)
        case sentGift(ClaimVoucher)
    }

    enum SendMode {
        case address
        case gift
    }

    private var isGift: Bool { prefill == nil && mode == .gift }

    @State private var stage: Stage = .compose
    @State private var address = ""
    @State private var amountText = ""
    @State private var feeChoice: FeeChoice = .normal
    @State private var working = false
    /// Send Max: sweep every UTXO; the fee comes out of the total.
    @State private var sendMax = false
    @State private var showScanner = false
    @State private var detailTxid: String?

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
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { code in
                apply(scannedOrPasted: code)
            }
        }
        .interactiveDismissDisabled(isMidFlight)
    }

    /// Accepts a bare address or a BIP21 URI (from the scanner, the Paste
    /// button, or typed into the field) and fills the form from it.
    private func apply(scannedOrPasted raw: String) {
        guard let parsed = PaymentRequest.parse(raw) else {
            address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        address = parsed.address
        if let sats = parsed.amountSats, sats > 0 {
            amountText = String(sats)
            sendMax = false
        }
    }

    private var navigationTitle: String {
        switch stage {
        case .compose: return isGift ? "Send a Gift" : "Send"
        case .review, .reviewGift: return "Confirm"
        case .broadcasting: return ""
        case .sent: return "Sent"
        case .sentGift: return "Gift ready"
        }
    }

    private var doneButtonTitle: String {
        switch stage {
        case .sent, .sentGift: return "Done"
        default: return "Cancel"
        }
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
        case .reviewGift(let voucher, let send):
            reviewGiftSheet(voucher, send)
        case .sentGift(let voucher):
            sentGiftView(voucher)
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
                if isGift {
                    giftIntro
                }

                // Destination
                if !isGift {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("To")
                    HStack(spacing: 8) {
                        TextField("Bitcoin address", text: $address, axis: .vertical)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .lineLimit(2)

                        if address.isEmpty {
                            Button {
                                showScanner = true
                            } label: {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: 16, weight: .semibold))
                                    .padding(6)
                                    .background(Circle().fill(Brand.orange.opacity(0.13)))
                                    .foregroundStyle(Brand.orangeDeep)
                            }
                            .accessibilityLabel("Scan a Bitcoin QR code")

                            Button {
                                if let pasted = UIPasteboard.general.string {
                                    apply(scannedOrPasted: pasted)
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
                    .onChange(of: address) { _, newValue in
                        // Typing/pasting a full BIP21 URI into the field
                        // normalizes it to address + amount.
                        if newValue.lowercased().hasPrefix("bitcoin:") {
                            apply(scannedOrPasted: newValue)
                        }
                    }

                    if let prefill, prefill.address == address, let label = prefill.label, !label.isEmpty {
                        Text("Requested by \(label)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }

                    if addressIsValid, let lookalike = store.poisoningSuspect(for: address) {
                        InfoBanner(
                            systemName: "exclamationmark.shield.fill",
                            text: "This address looks deceptively similar to one you've paid before (\(Format.shortAddress(lookalike))) but is NOT the same. This is a known scam pattern — verify the full address with the recipient before sending.",
                            tint: .red
                        )
                    }
                }
                }

                // Amount
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(isGift ? "Gift amount" : "Amount")

                    if sendMax {
                        sendMaxField
                    } else {
                        AmountField(text: $amountText, store: store, tint: isGift ? .purple : Brand.orange)
                    }

                    HStack {
                        Text("Available: \(Format.sats(store.balance.spendableSats)) sats")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !isGift {
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
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel(sendMax ? "Switch to entering an amount" : "Send entire balance")
                        }
                    }
                    .padding(.horizontal, 4)

                    if dustWarning, !isGift {
                        Text("Minimum send is \(Format.sats(dustLimitSats)) sats.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 4)
                    }
                    if giftTooSmall {
                        Text("Minimum gift is \(Format.sats(ClaimVoucher.minimumSats)) sats — it has to cover its own claim fee.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.leading, 4)
                    }
                }

                // Fee
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel("Network fee")
                    AdaptiveStack(spacing: 8) {
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
                        Label(isGift ? "Review gift with Face ID" : "Review with Face ID", systemImage: "faceid")
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

    /// What a gift is, in one breath, before the amount is asked for.
    private var giftIntro: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBubble(systemName: "gift.fill", tint: .purple, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("No address needed")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                Text("The claim rides inside the message — they don't need a wallet yet. Anyone who can read this chat can claim it, so keep it casual-sized. Take it back any time before it's claimed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.purple.opacity(0.08))
        )
    }

    /// Replaces the amount field while Send Max is on.
    private var sendMaxField: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Everything")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.gradient)
                Text("−fee")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text("\(Format.sats(store.balance.spendableSats)) sats minus the network fee")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(fieldBackground)
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
        if isGift {
            return parsedAmount.map { $0 >= ClaimVoucher.minimumSats } ?? false
        }
        return addressIsValid && (sendMax || (parsedAmount.map { $0 >= dustLimitSats } ?? false))
    }

    private var giftTooSmall: Bool {
        guard isGift, let sats = parsedAmount else { return false }
        return sats < ClaimVoucher.minimumSats
    }

    private var isLargeSend: Bool {
        if sendMax { return true }
        guard let sats = parsedAmount, store.balance.spendableSats > 0 else { return false }
        return Double(sats) / Double(store.balance.spendableSats) > 0.75
    }

    private func prepare() async {
        guard sendMax || parsedAmount != nil else { return }
        working = true
        defer { working = false }
        do {
            if isGift, let sats = parsedAmount {
                let (voucher, send) = try await store.prepareGift(
                    amountSats: sats,
                    feeRateSatPerVb: feeChoice.satPerVb(store.feeTiers)
                )
                withAnimation { stage = .reviewGift(voucher, send) }
            } else {
                let send = try await store.prepareSend(
                    to: address.trimmingCharacters(in: .whitespacesAndNewlines),
                    amountSats: parsedAmount ?? 0,
                    feeRateSatPerVb: feeChoice.satPerVb(store.feeTiers),
                    drain: sendMax
                )
                withAnimation { stage = .review(send) }
            }
        } catch {
            Haptics.warning()
            store.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Gift review / sent

    private func reviewGiftSheet(_ voucher: ClaimVoucher, _ send: SignedSend) -> some View {
        VStack(spacing: 20) {
            IconBubble(systemName: "gift.fill", tint: .purple, size: 56)

            DetailCard(rows: [
                DetailRow(title: "Gift amount", value: "\(Format.sats(send.details.amountSats)) sats"),
                DetailRow(title: "Network fee", value: "\(Format.sats(send.details.feeSats)) sats"),
                DetailRow(title: "Total", value: "\(Format.sats(send.details.totalSats)) sats", emphasized: true),
            ])

            Text("The recipient pays a small claim fee out of the gift. Unclaimed gifts can be taken back — this one expires \(voucher.expiresAt.formatted(date: .abbreviated, time: .omitted)).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await fundGift(voucher, send) }
            } label: {
                Label("Create gift", systemImage: "gift.fill")
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

    private func fundGift(_ voucher: ClaimVoucher, _ send: SignedSend) async {
        withAnimation { stage = .broadcasting }
        do {
            _ = try await store.fundGift(voucher, send: send)
            Haptics.success()
            withAnimation(.spring(response: 0.4)) { stage = .sentGift(voucher) }
        } catch {
            Haptics.warning()
            store.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            withAnimation { stage = .reviewGift(voucher, send) }
        }
    }

    private func sentGiftView(_ voucher: ClaimVoucher) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 10)

            IconBubble(systemName: "gift.fill", tint: .purple, size: 84)

            VStack(spacing: 4) {
                Text("Gift of \(Format.sats(voucher.amountSats)) sats ready")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                Text("Add the card to the chat and hit send —\nthey can claim it the moment they get OrangeBubbles.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                bridge.insertClaimCard(for: voucher)
                dismiss()
            } label: {
                Label("Add gift card to chat", systemImage: "message.fill")
            }
            .buttonStyle(ProminentButtonStyle())
            .padding(.horizontal)

            Text("You can take the gift back from your wallet's home screen until it's claimed.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer(minLength: 10)
        }
        .padding(20)
    }

    // MARK: - Review

    private func reviewSheet(_ send: SignedSend) -> some View {
        VStack(spacing: 20) {
            IconBubble(systemName: "paperplane.fill", size: 56)

            DetailCard(rows: [
                DetailRow(title: "To", value: Format.shortAddress(send.details.destinationAddress, prefix: 14, suffix: 10), monospaced: true),
                DetailRow(title: "Amount", value: "\(Format.sats(send.details.amountSats)) sats"),
                DetailRow(title: "Network fee", value: "\(Format.sats(send.details.feeSats)) sats"),
                DetailRow(title: "Total", value: "\(Format.sats(send.details.totalSats)) sats", emphasized: true),
            ])

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

            Button {
                detailTxid = txid
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("View transaction")
                }
                .font(.system(.subheadline, design: .rounded).weight(.medium))
            }
            .sheet(item: Binding(get: { detailTxid.map(TxidBox.init) }, set: { detailTxid = $0?.id })) { box in
                TransactionDetailView(store: store, txid: box.id)
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


/// Identifiable wrapper so a txid can drive `.sheet(item:)`.
struct TxidBox: Identifiable {
    let id: String
}
