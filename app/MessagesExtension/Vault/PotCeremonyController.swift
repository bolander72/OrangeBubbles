import Foundation
import WalletKit

/// Drives a pot ceremony over **CloudKit** (no server we run; no cards sent
/// back). The creator sends ONE iMessage invite card; everyone else just taps
/// it to join, and each member's DKG rounds sync over the pot's CloudKit record.
///
/// The in-progress DKG is persisted after every round (PendingCeremonyStore), so
/// a member can close the app mid-setup and it finishes on reopen — resumed here
/// via `resumePending()`, or by the container app's background push handler.
@MainActor
final class PotCeremonyController: ObservableObject {
    /// The active pot's coordinator — present the pot UI when non-nil.
    @Published private(set) var coordinator: VaultCoordinator?
    /// Drives the "Joining…/Setting up…" sheet for someone who tapped Join.
    @Published var presentSetup = false
    /// Whether the local user can use CloudKit (signed into iCloud). Pots are
    /// an all-iMessage/Apple-ecosystem feature; without this we don't offer it.
    @Published private(set) var cloudAvailable = false

    private let store: WalletStore
    private let bridge: ExtensionBridge
    private let pendingStore = PendingCeremonyStore()
    private var activeVaultID: String?
    /// Background coordinators finishing stuck ceremonies on open (kept alive).
    private var resumers: [VaultCoordinator] = []

    init(store: WalletStore, bridge: ExtensionBridge) {
        self.store = store
        self.bridge = bridge
        bridge.onPotInvite = { [weak self] invite in self?.join(invite) }
        Task {
            await refreshCloudStatus()
            resumePending()   // finish any DKG left in-progress from a prior open
        }
    }

    func refreshCloudStatus() async {
        cloudAvailable = await CloudKitTransport.accountAvailable()
    }

    /// True when we're in a chat that can host a pot AND CloudKit is usable.
    var canStart: Bool { bridge.memberSlot != nil && cloudAvailable }

    // MARK: - Create / Join

    /// Create a new pot: start our DKG over CloudKit and drop the single invite
    /// card. Approval defaults to "any 2".
    func create(name: String, emoji: String) {
        guard let slot = bridge.memberSlot, cloudAvailable else { return }
        let vaultID = "pot-\(UUID().uuidString.prefix(12))"
        let k = UInt16(min(2, Int(slot.count)))
        guard let c = spawn(vaultID: vaultID, name: name, emoji: emoji,
                            index: slot.index, n: slot.count, k: k) else { return }
        activeVaultID = vaultID
        coordinator = c
        Task { await c.start() }
        bridge.insertInviteCard(for: PotInvite(
            vaultID: vaultID, name: name, emoji: emoji,
            memberCount: slot.count, threshold: k, relayHost: ""))
    }

    /// A member tapped the invite card: start (or resume) our DKG over CloudKit.
    /// Nothing is sent back — our round syncs through the pot's CloudKit record.
    private func join(_ invite: PotInvite) {
        guard coordinator == nil || activeVaultID != invite.vaultID else { return }
        guard let slot = bridge.memberSlot, cloudAvailable else { return }
        if let pending = pendingStore.all().first(where: { $0.vaultID == invite.vaultID }) {
            resume(pending, asActive: true)
        } else if let c = spawn(vaultID: invite.vaultID, name: invite.name, emoji: invite.emoji,
                                index: slot.index, n: invite.memberCount, k: invite.threshold) {
            activeVaultID = invite.vaultID
            coordinator = c
            Task { await c.start() }
        }
        presentSetup = true
    }

    /// Finish any ceremonies left in-progress (e.g. the creator's later round
    /// after a joiner contributed while the app was closed).
    func resumePending() {
        guard cloudAvailable else { return }
        for pending in pendingStore.all() where pending.vaultID != activeVaultID {
            resume(pending, asActive: false)
        }
    }

    func dismissSetup() { presentSetup = false; close() }
    func close() { coordinator = nil; activeVaultID = nil }

    // MARK: - Coordinator wiring

    /// Build a fresh-DKG coordinator with persistence hooks wired.
    private func spawn(vaultID: String, name: String, emoji: String,
                       index: UInt16, n: UInt16, k: UInt16) -> VaultCoordinator? {
        guard let seed = store.debugMnemonic else { return nil }
        // Per-member seed: incorporates the index, so members get distinct
        // entropy whether or not their wallet seeds differ. Trustless — each
        // member's share stays on their device.
        let memberSeed = FrostTestSeeds.seed(base: seed, memberIndex: Int(index))
        let cfg = VaultCoordinator.Config(vaultID: vaultID, name: name, memberIndex: index,
                                          memberCount: n, threshold: k, emoji: emoji)
        guard let c = try? VaultCoordinator(config: cfg, transport: CloudKitTransport(),
                                            chain: store.chain, mnemonic: memberSeed) else { return nil }
        wire(c, memberSeed: memberSeed)
        return c
    }

    /// Rebuild an in-progress coordinator from its persisted DKG state.
    private func resume(_ p: PendingCeremony, asActive: Bool) {
        guard let c = try? VaultCoordinator(
            resumingDKG: p.config, sessionData: p.sessionData, seenKeys: p.seenKeys,
            transport: CloudKitTransport(), chain: store.chain, mnemonic: p.memberSeed) else { return }
        wire(c, memberSeed: p.memberSeed)
        if asActive { activeVaultID = p.vaultID; coordinator = c }
        else { resumers.append(c) }
        Task { await c.resumeDKG() }
    }

    /// Persist DKG progress after every round; save the vault + clear pending on
    /// completion.
    private func wire(_ c: VaultCoordinator, memberSeed: String) {
        let cfg = c.config
        let chat = bridge.chatKey
        // Wake the container app on later changes so it can finish in the
        // background (BackgroundCeremonyResumer) even if we've closed the app.
        Task { try? await CloudKitTransport.subscribe(vaultID: cfg.vaultID) }
        let vaults = VaultStore()
        let pending = pendingStore
        c.onDKGProgress = { data, keys in
            pending.save(PendingCeremony(
                vaultID: cfg.vaultID, name: cfg.name, emoji: cfg.emoji ?? "🍯",
                memberIndex: cfg.memberIndex, memberCount: cfg.memberCount, threshold: cfg.threshold,
                chatKey: chat, memberSeed: memberSeed, sessionData: data, seenKeys: keys))
        }
        c.onVaultReady = { r in
            var rec = r; rec.chatKey = chat
            vaults.save(rec)
            pending.delete(vaultID: cfg.vaultID)
        }
    }
}
