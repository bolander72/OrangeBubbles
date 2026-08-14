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
    /// Rebuild redundancy: re-key the chat's current members (handled by the
    /// ceremony controller in HomeView, which can start a new pot).
    var onRefresh: ((VaultRecord) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private let vaultStore = VaultStore()
    @State private var saved: [VaultRecord] = []
    @State private var showCreate = false
    @State private var active: VaultCoordinator?

    var body: some View {
        NavigationStack {
            Group {
                if let c = active {
                    PotDetailView(store: store, coordinator: c, chatParticipantCount: chatParticipantCount,
                                  onBack: { active = nil; reload() },
                                  onArchive: { archive(c) },
                                  onRefresh: onRefresh == nil ? nil : {
                                      if let rec = vaultStore.all().first(where: { $0.vaultID == c.config.vaultID }) {
                                          onRefresh?(rec)
                                      }
                                  })
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
                if sortedForChat.isEmpty && archivedPots.isEmpty {
                    emptyState
                } else {
                    if let chatKey, sortedForChat.contains(where: { $0.chatKey == chatKey }) {
                        Text("In this chat")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(sortedForChat) { record in
                        PotCard(record: record,
                                inThisChat: record.chatKey != nil && record.chatKey == chatKey,
                                onTap: { resume(record) },
                                onDelete: { remove(record) })
                    }
                    if !archivedPots.isEmpty { archivedSection }
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

    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archived")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            ForEach(archivedPots) { record in
                HStack(spacing: 12) {
                    Text(record.emoji ?? potEmoji(for: record.name))
                        .font(.system(size: 24)).frame(width: 44, height: 44)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                        .opacity(0.7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.name).font(.system(.subheadline, design: .rounded).weight(.semibold))
                        Text("Archived · share kept").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Rejoin") { rejoin(record) }
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .buttonStyle(.borderedProminent).tint(Brand.orange)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
            }
        }
    }

    /// Active (non-archived) pots, with the current chat's pots floated to top.
    private var sortedForChat: [VaultRecord] {
        let live = saved.filter { !$0.archived }
        guard let chatKey else { return live }
        return live.sorted { ($0.chatKey == chatKey ? 0 : 1) < ($1.chatKey == chatKey ? 0 : 1) }
    }
    private var archivedPots: [VaultRecord] { saved.filter { $0.archived } }

    private func reload() { saved = vaultStore.all() }

    private func remove(_ record: VaultRecord) {
        vaultStore.delete(vaultID: record.vaultID)
        Haptics.tap()
        reload()
    }

    /// Archive = hide it, keep the share, rejoin anytime. Silent (ADR 0009).
    private func archive(_ c: VaultCoordinator) {
        if var rec = vaultStore.all().first(where: { $0.vaultID == c.config.vaultID }) {
            rec.archived = true
            vaultStore.save(rec)
        }
        active = nil
        Haptics.tap()
        reload()
    }

    private func rejoin(_ record: VaultRecord) {
        var rec = record
        rec.archived = false
        vaultStore.save(rec)
        reload()
        resume(rec)
    }

    private func resume(_ record: VaultRecord) {
        guard let seed = store.debugMnemonic else { return }
        let memberSeed = FrostTestSeeds.seed(base: seed, memberIndex: Int(record.memberIndex))
        // Resumed pots watch for spends + departures over CloudKit (the shipping
        // transport), not the dev relay.
        guard let c = try? VaultCoordinator(resuming: record, transport: CloudKitTransport(),
                                            chain: store.chain, mnemonic: memberSeed) else { return }
        let vs = vaultStore
        c.onInactiveChange = { inactive in
            guard var rec = vs.all().first(where: { $0.vaultID == record.vaultID }) else { return }
            rec.inactiveMembers = Array(inactive)
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
    var onDelete: (() -> Void)? = nil
    @State private var confirmDelete = false

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
        .contextMenu {
            if onDelete != nil {
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("Remove pot", systemImage: "trash")
                }
            }
        }
        .confirmationDialog("Remove “\(record.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove pot", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the pot from this phone. Any bitcoin still in it stays safe — you'll need at least one other member to move it.")
        }
    }

    private var peopleLine: String {
        "\(record.memberCount) people · any \(record.threshold) can approve"
    }
    private func emoji(for name: String) -> String { record.emoji ?? potEmoji(for: name) }
}

func potEmoji(for name: String) -> String {
    potEmojis[abs(name.hashValue) % potEmojis.count]
}

/// A compact row of anonymous member faces — no names (iMessage shows the
/// real people; we just show how many share the pot).
struct RosterStrip: View {
    let record: VaultRecord
    private let palette: [Color] = [.orange, .pink, .purple, .blue, .green, .teal]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<Int(record.memberCount), id: \.self) { i in
                Image(systemName: "person.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(palette[i % palette.count]))
            }
            Text("\(record.memberCount) people").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 2)
        }
        .padding(.top, 1)
    }
}
