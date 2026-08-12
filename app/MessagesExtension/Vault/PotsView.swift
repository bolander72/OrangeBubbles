import SwiftUI
import WalletKit

// The product vault experience — "Pots": shared pots of bitcoin in a
// group chat. All FROST/threshold/DKG language is hidden behind plain,
// playful wording. Testing knobs (relay host, member #) live in a
// collapsed Advanced area so the 3-device relay test still works.

private let potEmojis = ["🍯", "🐷", "🎉", "✈️", "🏠", "🎁", "🍕", "⚽️", "🌮", "🏖️"]

struct PotsView: View {
    @ObservedObject var store: WalletStore
    /// Fingerprint of the chat the app is open in (nil outside a chat).
    var chatKey: String? = nil
    /// People in the current chat, for deriving pot size automatically.
    var chatParticipantCount: Int = 0
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
                CreatePotView(store: store, chatKey: chatKey, chatParticipantCount: chatParticipantCount) { coordinator in
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
                    if let chatKey, saved.contains(where: { $0.chatKey == chatKey }) {
                        Text("In this chat")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(sortedForChat) { record in
                        PotCard(record: record, inThisChat: record.chatKey != nil && record.chatKey == chatKey) { resume(record) }
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

    /// Pots in this chat float to the top so the relevant one is obvious.
    private var sortedForChat: [VaultRecord] {
        guard let chatKey else { return saved }
        return saved.sorted { ($0.chatKey == chatKey ? 0 : 1) < ($1.chatKey == chatKey ? 0 : 1) }
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
    var inThisChat: Bool = false
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
                    RosterStrip(record: record)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Brand.orange.opacity(inThisChat ? 0.9 : 0), lineWidth: 2)
            )
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

/// A compact row of member faces (colored initials) + names, so you can see
/// who's in a pot straight from the list. Empty slots read "waiting".
struct RosterStrip: View {
    let record: VaultRecord

    private var names: [String] {
        (1...Int(record.memberCount)).map { record.roster[String($0)] ?? "" }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Avatar(name: name)
            }
            Text(summary).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 2)
        }
        .padding(.top, 1)
    }

    private var summary: String {
        let joined = names.filter { !$0.isEmpty }
        if joined.count == record.memberCount { return joined.joined(separator: ", ") }
        return "\(joined.count)/\(record.memberCount) joined"
    }

    struct Avatar: View {
        let name: String
        private let palette: [Color] = [.orange, .pink, .purple, .blue, .green, .teal]
        private var initial: String { name.first.map { String($0).uppercased() } ?? "?" }
        private var color: Color { name.isEmpty ? Color.gray.opacity(0.4) : palette[abs(name.hashValue) % palette.count] }
        var body: some View {
            Text(initial)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(color))
        }
    }
}
