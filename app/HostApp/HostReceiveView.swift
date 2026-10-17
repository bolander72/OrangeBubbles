import SwiftUI

/// Receive from the Home Screen app: hands out one of the addresses the
/// extension reserved for this process (the same pool Siri draws from),
/// records it as issued so it is never offered again, and shows it as a
/// QR with copy and share. Watch-only — no keys, no derivation here.
struct HostReceiveView: View {
    var onIssued: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address: String?
    @State private var exhausted = false
    @State private var copied = false

    private let orange = Color(red: 0.97, green: 0.58, blue: 0.10)
    private let orangeDeep = Color(red: 0.93, green: 0.42, blue: 0.05)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let address {
                        if let qr = QRCodeGenerator.image(for: "bitcoin:\(address)") {
                            Image(uiImage: qr)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 216)
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
                                .padding(5)
                                .background(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .fill(LinearGradient(colors: [orange, orangeDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .shadow(color: orange.opacity(0.25), radius: 14, y: 6)
                                )
                                .padding(.top, 6)
                        }
                        addressChip(address)
                        ShareLink(item: URL(string: "bitcoin:\(address)")!, message: Text("Here's my bitcoin address")) {
                            Label("Share address", systemImage: "square.and.arrow.up")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(LinearGradient(colors: [orange, orangeDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
                                )
                        }
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "leaf.fill").font(.caption2).foregroundStyle(.green)
                            Text("Fresh address, never shown before. It's only ever offered once — open Receive again next time.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                    } else if exhausted {
                        VStack(spacing: 10) {
                            Image(systemName: "message.badge.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(orange)
                            Text("Open OrangeBubbles in Messages once")
                                .font(.system(.headline, design: .rounded).weight(.bold))
                            Text("The addresses reserved for this screen have all been handed out. The wallet reserves more the next time it opens in a conversation.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 40)
                    } else {
                        ProgressView().padding(.top, 60)
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

    private func addressChip(_ address: String) -> some View {
        Button {
            UIPasteboard.general.string = address
            withAnimation(.spring(response: 0.3)) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                withAnimation { copied = false }
            }
        } label: {
            HStack(spacing: 8) {
                Text("\(address.prefix(14))…\(address.suffix(10))")
                    .font(.system(.footnote, design: .monospaced).weight(.medium))
                    .foregroundStyle(.primary)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(copied ? .green : orangeDeep)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Bitcoin address, tap to copy")
    }
}
