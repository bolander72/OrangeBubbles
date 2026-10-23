import SwiftUI
import WalletKit

/// The one way amounts are typed anywhere in the app: a big sats number
/// with live BTC and ≈USD underneath, and a "$ · ₿" affordance that
/// accepts dollars, BTC, or words ("$5", "0.001 btc", "21k sats"),
/// parsed on device.
struct AmountField: View {
    @Binding var text: String
    @ObservedObject var store: WalletStore
    var tint: Color = Brand.orange
    /// Shown under the number while it is empty.
    var emptyHint: String? = nil

    @FocusState private var focused: Bool
    @State private var showSmart = false
    @State private var smartText = ""

    private var sats: UInt64? {
        UInt64(text.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("0", text: $text)
                    .keyboardType(.numberPad)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: true, vertical: false)
                    .focused($focused)
                    .accessibilityLabel("Amount in sats")
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { focused = false }
                                .font(.system(.body, design: .rounded).weight(.semibold))
                        }
                    }
                Text("sats")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Group {
                if let sats {
                    HStack(spacing: 8) {
                        Text("\(Format.btc(sats)) BTC")
                            .font(.system(.caption, design: .monospaced))
                        if let usd = store.usdApprox(sats) {
                            Text(usd)
                                .font(.system(.caption, design: .rounded).weight(.medium))
                        }
                    }
                } else if let emptyHint {
                    Text(emptyHint)
                        .font(.system(.caption, design: .rounded))
                }
            }
            .foregroundStyle(.secondary)
            .frame(minHeight: 16)
            .animation(.easeOut(duration: 0.15), value: sats)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { focused = true }
        .overlay(alignment: .topTrailing) {
            Button {
                showSmart = true
            } label: {
                Text("$ · ₿")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(tint.opacity(0.13)))
                    .foregroundStyle(tint)
            }
            .buttonStyle(PressableStyle())
            .padding(8)
            .accessibilityLabel("Type the amount in dollars, BTC, or words")
        }
        .alert("Describe the amount", isPresented: $showSmart) {
            TextField("e.g. $5, 0.001 btc, 21k sats", text: $smartText)
            Button("Use") {
                let typed = smartText
                smartText = ""
                Task {
                    if let parsed = await SmartAmountAI.parse(typed, store: store) {
                        text = String(parsed)
                        Haptics.tap()
                    } else {
                        store.lastError = "Couldn't understand that amount. Try \"$5\", \"0.001 btc\", or \"21000 sats\"."
                    }
                }
            }
            Button("Cancel", role: .cancel) { smartText = "" }
        } message: {
            Text("Dollars, BTC, or sats — parsed on your device.")
        }
    }
}
