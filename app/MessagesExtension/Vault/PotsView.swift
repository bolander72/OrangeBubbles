import SwiftUI
import WalletKit

// The product vault experience — "Pots": shared pots of bitcoin in a
// group chat. All FROST/threshold/DKG language is hidden behind plain,
// playful wording. Testing knobs (relay host, member #) live in a
// collapsed Advanced area so the 3-device relay test still works.

private let potEmojis = ["🍯", "🐷", "🎉", "✈️", "🏠", "🎁", "🍕", "⚽️", "🌮", "🏖️"]

struct PotsView: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    private let vaultStore = VaultStore()
    @State private var saved: [VaultRecord] = []
    @State private var showCreate = false
    @State private var active: VaultCoordinator?

    var body: some View {
        NavigationStack {
            Group {
                if let c = active {
                    PotDetailView(store: store, coordinator: c, onBack: { active = nil; reload() })
                } else {
                    home
                }
            }
            .navigationTitle(active == nil ? "Shared Pots" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(active == nil ? "Done" : "Back") {
                        if active == nil { dismiss() } else { active = nil; reload() }
                    }
                }
            }
            .onAppear(perform: reload)
            .sheet(isPresented: $showCreate) {
                CreatePotView(store: store) { coordinator in
                    active = coordinator
                }
            }
        }
    }

    private var home: some View {
        ScrollView {
            VStack(spacing: 16) {
                if saved.isEmpty {
                    emptyState
                } else {
                    ForEach(saved) { record in
                        PotCard(record: record) { resume(record) }
                    }
                }
                Button {
                    showCreate = true
                } label: {
                    Label("New shared pot", systemImage: "plus.circle.fill")
                }
                .buttonStyle(ProminentButtonStyle())
                .padding(.top, 4)
            }
            .padding(20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("🍯").font(.system(size: 56))
            Text("Start a shared pot")
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text("Pool bitcoin with friends or family, right in your group chat. Everyone chips in — and you decide together how it's spent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 8)
    }

    private func reload() { saved = vaultStore.all() }

    private func resume(_ record: VaultRecord) {
        guard let seed = store.debugMnemonic,
              let url = URL(string: "http://\(record.relayHost ?? "127.0.0.1"):8781") else { return }
        let memberSeed = FrostTestSeeds.seed(base: seed, memberIndex: Int(record.memberIndex))
        guard let c = try? VaultCoordinator(resuming: record, transport: DebugRelayTransport(baseURL: url),
                                            chain: store.chain, mnemonic: memberSeed) else { return }
        let vs = vaultStore
        c.onRosterChange = { roster in
            guard var rec = vs.all().first(where: { $0.vaultID == record.vaultID }) else { return }
            rec.roster = roster.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }
            vs.save(rec)
        }
        active = c
        Task { await c.resume() }
    }
}

/// A pot in the list — playful card with emoji, name, balance, people.
private struct PotCard: View {
    let record: VaultRecord
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Text(emoji(for: record.name))
                    .font(.system(size: 34))
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Brand.subtleGradient))
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(.primary)
                    Text(peopleLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }

    private var peopleLine: String {
        "\(record.memberCount) people · any \(record.threshold) can approve"
    }
    private func emoji(for name: String) -> String {
        potEmojis[abs(name.hashValue) % potEmojis.count]
    }
}

func potEmoji(for name: String) -> String {
    potEmojis[abs(name.hashValue) % potEmojis.count]
}
