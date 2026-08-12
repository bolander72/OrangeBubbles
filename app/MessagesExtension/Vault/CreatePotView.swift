import SwiftUI
import WalletKit

/// Delightful, plain-language pot creation. No "threshold", "member index",
/// or "DKG" — just: name it, pick how many people, pick who can approve.
struct CreatePotView: View {
    @ObservedObject var store: WalletStore
    /// Fingerprint of the chat this pot is being created in (nil outside a chat).
    var chatKey: String? = nil
    /// How many people are in the current chat — the pot's size is derived
    /// from this, so we never ask the user "how many people?".
    var chatParticipantCount: Int = 0
    let onReady: (VaultCoordinator) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var people = 3
    @State private var showRuleOptions = false

    /// Plain-language, size-aware summary of the current approval rule, e.g.
    /// "any 2 of you need to say yes" or "everyone needs to say yes".
    private var ruleSummary: String {
        let k = rule.threshold(of: people)
        if k >= people { return "everyone needs to say yes" }
        if k == 2 { return "any 2 of you need to say yes" }
        return "any \(k) of \(people) need to say yes"
    }

    /// True when opened inside a real group chat (2+ people) — lets us derive
    /// the pot size automatically instead of asking.
    private var inGroupChat: Bool { chatParticipantCount >= 2 }
    @State private var rule: Rule = .any2
    @State private var coordinator: VaultCoordinator?

    // Advanced (testing) — hidden by default.
    @State private var showAdvanced = false
    @State private var relayHost = "192.168.1.46"
    @State private var vaultID = ""
    @State private var memberIndex = 1

    enum Rule: String, CaseIterable, Identifiable {
        case everyone, any2, majority
        var id: String { rawValue }
        var title: String {
            switch self {
            case .everyone: return "Everyone must approve"
            case .any2: return "Any 2 of us"
            case .majority: return "Most of us"
            }
        }
        var subtitle: String {
            switch self {
            case .everyone: return "Every person has to say yes to spend. Safest, but if one phone is lost the money is stuck."
            case .any2: return "Any two people can approve a spend. One phone can be lost and the money's still safe. Recommended."
            case .majority: return "More than half must approve."
            }
        }
        var icon: String {
            switch self {
            case .everyone: return "person.3.fill"
            case .any2: return "person.2.fill"
            case .majority: return "person.crop.circle.badge.checkmark"
            }
        }
        func threshold(of n: Int) -> Int {
            switch self {
            case .everyone: return n
            case .any2: return min(2, n)
            case .majority: return n / 2 + 1
            }
        }
    }

    var body: some View {
        NavigationStack {
            if let c = coordinator {
                SettingUpView(coordinator: c, emoji: potEmoji(for: name)) {
                    dismiss(); onReady(c)
                }
            } else {
                form
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack {
                    Text(potEmoji(for: name.isEmpty ? "pot" : name)).font(.system(size: 30))
                    TextField("Name your pot (e.g. Ski Trip)", text: $name)
                        .font(.system(.body, design: .rounded))
                }
            } footer: {
                Text("Give it a name your group will recognize in the chat.")
            }

            if inGroupChat {
                Section {
                    HStack(spacing: 12) {
                        IconBubble(systemName: "person.2.fill", tint: Brand.orange, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Everyone in this chat")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            Text("\(people) people")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("This pot belongs to this group chat. Everyone here can chip in.")
                }
            } else {
                Section("How many people?") {
                    Stepper("\(people) people (including you)", value: $people, in: 2...5)
                        .onChange(of: people) { _, n in if rule == .any2 && n < 2 { rule = .everyone } }
                }
            }

            // Money-safety choice, but pre-set to a smart default and
            // collapsed to a single row — ignore it and tap Create, or open
            // it to change. Not buried in developer settings; it's a real
            // user preference, just not a demanding one.
            Section {
                DisclosureGroup(isExpanded: $showRuleOptions) {
                    ForEach(Rule.allCases) { r in
                        Button { rule = r; withAnimation { showRuleOptions = false } } label: {
                            HStack(spacing: 12) {
                                IconBubble(systemName: r.icon, tint: rule == r ? Brand.orange : .gray, size: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundStyle(.primary)
                                    Text(r.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if rule == r { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.orange) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    HStack(spacing: 12) {
                        IconBubble(systemName: rule.icon, tint: Brand.orange, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("To spend, \(ruleSummary)")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundStyle(.primary)
                            Text("Tap to change").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Approving a spend")
            }

            #if DEBUG
            Section {
                DisclosureGroup("Advanced (testing)", isExpanded: $showAdvanced) {
                    TextField("Relay host", text: $relayHost).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                    TextField("Pot ID (share with test devices)", text: $vaultID).autocorrectionDisabled()
                    Stepper("I am device \(memberIndex)", value: $memberIndex, in: 1...people)
                    Text("Leave Pot ID blank to generate one. Other test devices join with the same Pot ID and a different device number.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            #endif

            Section {
                Button {
                    start()
                } label: {
                    Label("Create pot", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(ProminentButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("New Pot")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .onAppear { if inGroupChat { people = min(max(chatParticipantCount, 2), 5) } }
    }

    private func start() {
        guard let seed = store.debugMnemonic else { return }
        let id = vaultID.isEmpty ? "pot-\(UUID().uuidString.prefix(8))" : vaultID
        let threshold = rule.threshold(of: people)
        let host = relayHost
        guard let url = URL(string: "http://\(host):8781") else { return }
        let cfg = VaultCoordinator.Config(
            vaultID: id, name: name.trimmingCharacters(in: .whitespaces),
            memberIndex: UInt16(memberIndex), memberCount: UInt16(people),
            threshold: UInt16(threshold),
            displayName: "Me")
        let memberSeed = FrostTestSeeds.seed(base: seed, memberIndex: memberIndex)
        guard let c = try? VaultCoordinator(config: cfg, transport: DebugRelayTransport(baseURL: url),
                                            chain: store.chain, mnemonic: memberSeed) else { return }
        let vs = VaultStore()
        let chat = chatKey
        c.onVaultReady = { r in var rec = r; rec.relayHost = host; rec.chatKey = chat; vs.save(rec) }
        c.onRosterChange = { roster in
            guard var rec = vs.all().first(where: { $0.vaultID == id }) else { return }
            rec.roster = roster.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }
            vs.save(rec)
        }
        coordinator = c
        Task { await c.start() }
    }
}

/// Friendly setup screen that watches the coordinator and calls onReady
/// once DKG completes.
private struct SettingUpView: View {
    @ObservedObject var coordinator: VaultCoordinator
    let emoji: String
    let onReady: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(emoji).font(.system(size: 60))
            ProgressView().controlSize(.large).tint(Brand.orange)
            Text(message)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
            Text("Your group's phones are securely setting up the pot together. No single phone ever holds the whole key.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: coordinator.stage) { _, st in if st == .ready { onReady() } }
    }

    private var message: String {
        switch coordinator.stage {
        case .dkgInProgress: return "Setting up your pot… 🔐"
        case .error(let e): return e
        default: return "Getting things ready…"
        }
    }
}
