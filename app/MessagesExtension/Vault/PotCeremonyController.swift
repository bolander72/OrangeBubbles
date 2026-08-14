import Foundation
import WalletKit

/// Drives a pot ceremony over **CloudKit** (no server we run; no cards sent
/// back). The creator sends ONE iMessage invite card; everyone else just taps
/// it to join. Each member's DKG rounds sync silently over the pot's CloudKit
/// record. Member slots come from the chat's participant order — deterministic
/// and collision-free, no negotiation.
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
    private var activeVaultID: String?

    init(store: WalletStore, bridge: ExtensionBridge) {
        self.store = store
        self.bridge = bridge
        bridge.onPotInvite = { [weak self] invite in self?.join(invite) }
        Task { await refreshCloudStatus() }
    }

    func refreshCloudStatus() async {
        cloudAvailable = await CloudKitTransport.accountAvailable()
    }

    /// True when we're in a chat that can host a pot AND CloudKit is usable.
    var canStart: Bool { bridge.memberSlot != nil && cloudAvailable }

    /// Create a new pot in the current chat: start our DKG over CloudKit and
    /// drop the single invite card for everyone else to tap. Approval defaults
    /// to "any 2".
    func create(name: String, emoji: String) {
        guard let slot = bridge.memberSlot, cloudAvailable else { return }
        let vaultID = "pot-\(UUID().uuidString.prefix(12))"
        let k = UInt16(min(2, Int(slot.count)))
        start(vaultID: vaultID, name: name, emoji: emoji,
              index: slot.index, n: slot.count, k: k)
        bridge.insertInviteCard(for: PotInvite(
            vaultID: vaultID, name: name, emoji: emoji,
            memberCount: slot.count, threshold: k, relayHost: ""))
    }

    /// A member tapped the invite card: start our DKG over CloudKit. Nothing is
    /// sent back — our round syncs through the pot's CloudKit record.
    private func join(_ invite: PotInvite) {
        guard coordinator == nil || activeVaultID != invite.vaultID else { return }
        guard let slot = bridge.memberSlot, cloudAvailable else { return }
        start(vaultID: invite.vaultID, name: invite.name, emoji: invite.emoji,
              index: slot.index, n: invite.memberCount, k: invite.threshold)
        presentSetup = true   // show "Joining…" while the round syncs over CloudKit
    }

    /// Dismiss the setup sheet (after it's ready, or if the user closes it).
    func dismissSetup() { presentSetup = false; close() }

    /// Leave the active pot view (keeps the persisted vault).
    func close() { coordinator = nil; activeVaultID = nil }

    private func start(vaultID: String, name: String, emoji: String,
                       index: UInt16, n: UInt16, k: UInt16) {
        guard let seed = store.debugMnemonic else { return }
        // Per-member seed derivation: incorporates the index, so members get
        // distinct entropy whether or not their wallet seeds differ (true on
        // real devices). Trustless — each member's share stays on their device.
        let memberSeed = FrostTestSeeds.seed(base: seed, memberIndex: Int(index))
        let cfg = VaultCoordinator.Config(vaultID: vaultID, name: name, memberIndex: index,
                                          memberCount: n, threshold: k, emoji: emoji)
        guard let c = try? VaultCoordinator(config: cfg, transport: CloudKitTransport(),
                                            chain: store.chain, mnemonic: memberSeed) else { return }
        let chat = bridge.chatKey
        let vs = VaultStore()
        c.onVaultReady = { r in var rec = r; rec.chatKey = chat; vs.save(rec) }
        activeVaultID = vaultID
        coordinator = c
        Task { await c.start() }
    }
}
