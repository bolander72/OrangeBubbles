import SwiftUI
import WalletKit

struct ReceiveView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject var bridge: ExtensionBridge
    @Environment(\.dismiss) private var dismiss

    @State private var request: PaymentRequest?
    @State private var amountText = ""
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let request {
                        qrCard(for: request)
                        addressChip(for: request)
                        amountField
                        shareButton(for: request)

                        Label(
                            "Fresh address, never used before. Address reuse hurts privacy — tap Receive again next time.",
                            systemImage: "leaf.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 6)
                    } else {
                        ProgressView().padding(.top, 60)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Receive Bitcoin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
            }
        }
        .task { await deriveAddress() }
    }

    // MARK: - Pieces

    private func qrCard(for request: PaymentRequest) -> some View {
        VStack(spacing: 0) {
            if let qr = QRCodeGenerator.image(for: request.bip21URI) {
                Image(uiImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 216)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
            }
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Brand.gradient)
                .shadow(color: Brand.orange.opacity(0.25), radius: 14, y: 6)
        )
        .padding(.top, 6)
        .animation(.spring(response: 0.35), value: request.amountSats)
    }

    private func addressChip(for request: PaymentRequest) -> some View {
        Button {
            UIPasteboard.general.string = request.address
            Haptics.tap()
            withAnimation(.spring(response: 0.3)) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation { copied = false }
            }
        } label: {
            HStack(spacing: 8) {
                Text(Format.shortAddress(request.address, prefix: 14, suffix: 10))
                    .font(.system(.footnote, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Bitcoin address, tap to copy")
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(copied ? .green : Brand.orangeDeep)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
            .overlay(alignment: .center) {
                if copied {
                    Text("Copied")
                        .font(.system(.caption2, design: .rounded).weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.green))
                        .offset(y: -34)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var amountField: some View {
        VStack(spacing: 6) {
            TextField("Amount in sats (optional)", text: $amountText)
                .keyboardType(.numberPad)
                .font(.system(.body, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .onChange(of: amountText) { _, _ in applyAmount() }

            if let sats = request?.amountSats, sats > 0 {
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

    private func shareButton(for request: PaymentRequest) -> some View {
        Button {
            var final = request
            final.label = "Satchel"
            bridge.insertCard(for: final, kind: .request)
            dismiss()
        } label: {
            Label("Share in chat", systemImage: "message.fill")
        }
        .buttonStyle(ProminentButtonStyle())
    }

    // MARK: - Data

    private func deriveAddress() async {
        guard request == nil else { return }
        do {
            request = try await store.makeReceiveRequest(amountSats: nil, label: nil)
        } catch {
            store.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            dismiss()
        }
    }

    private func applyAmount() {
        guard var current = request else { return }
        current.amountSats = UInt64(amountText.filter(\.isNumber))
        request = current
    }
}
