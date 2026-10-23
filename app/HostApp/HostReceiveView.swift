import SwiftUI
import WalletKit

/// Receive from the Home Screen app: hands out one of the addresses the
/// extension reserved for this process (the same pool Siri draws from),
/// records it as issued so it is never offered again, and shows it the way
/// the extension's Receive sheet does. Watch-only — no keys here.
struct HostReceiveView: View {
    let network: NetworkKind
    var onIssued: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address: String?
    @State private var exhausted = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let address {
                        qrCard(for: address)
                        addressChip(address)
                        ShareLink(item: URL(string: "bitcoin:\(address)")!, message: Text("Here's my bitcoin address")) {
                            Label("Share address", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(ProminentButtonStyle())

                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "leaf.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Text("Fresh address, never shown before. It's only ever offered once — open Receive again next time.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 6)
                    } else if exhausted {
                        VStack(spacing: 12) {
                            IconBubble(systemName: "message.badge.circle.fill", size: 56)
                            Text("Open OrangeBubbles in Messages once")
                                .font(.system(.headline, design: .rounded).weight(.bold))
                            Text("The addresses reserved for this screen have all been handed out. The wallet reserves more the next time it opens in a conversation.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 40)
                        .padding(.horizontal, 8)
                    } else {
                        ProgressView().tint(Brand.orange).padding(.top, 60)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Receive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
            }
        }
        .tint(Brand.orange)
        .onAppear(perform: issue)
    }

    private func issue() {
        guard address == nil else { return }
        if let issued = SharedSnapshot.load()?.issueReceiveAddress() {
            address = issued
            onIssued()
        } else {
            exhausted = true
        }
    }

    private func qrCard(for address: String) -> some View {
        VStack(spacing: 0) {
            if let qr = QRCodeGenerator.image(for: "bitcoin:\(address)") {
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
    }

    private func addressChip(_ address: String) -> some View {
        Button {
            UIPasteboard.general.string = address
            Haptics.tap()
            withAnimation(.spring(response: 0.3)) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation { copied = false }
            }
        } label: {
            HStack(spacing: 8) {
                Text(Format.shortAddress(address, prefix: 14, suffix: 10))
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
}
