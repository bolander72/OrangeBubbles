import Foundation
import WalletKit

/// Drives a pot ceremony over **real iMessage** (no server). It owns the active
/// `VaultCoordinator` wired to an `IMessageTransport`, turns the coordinator's
/// outgoing messages into the evolving ceremony card (via `ExtensionBridge`),
/// and feeds tapped/received cards back in. Member slots come from the chat's
/// participant order — deterministic and collision-free, no negotiation.
@MainActor
final class PotCeremonyController: ObservableObject {
    /// The active pot's coordinator — present the pot UI when non-nil.
    @Published private(set) var coordinator: VaultCoordinator?

    private let store: WalletStore
    private let bridge: ExtensionBridge
    private var transport: IMessageTransport?
    private var meta: (vaultID: String, name: String, emoji: String, n: UInt16, k: UInt16)?

    init(store: WalletStore, bridge: ExtensionBridge) {
        self.store = store
        self.bridge = bridge
        bridge.onCeremonyCard = { [weak self] card in self?.receive(card) }
    }

    /// True when we're in a chat that can host a pot.
    var canStart: Bool { bridge.memberSlot != nil }

    /// Start a brand-new pot in the current chat. Approval defaults to "any 2".
    func create(name: String, emoji: String) {
        guard let slot = bridge.memberSlot, let seed = store.debugMnemonic else { return }
        let vaultID = "pot-\(UUID().uuidString.prefix(8))"
        let k = UInt16(min(2, Int(slot.count)))
        start(vaultID: vaultID, name: name, emoji: emoji,
              index: slot.index, n: slot.count, k: k, seed: seed, initial: nil)
    }

    /// A ceremony card was tapped/received: join it (if new) or ingest its state.
    func receive(_ card: PotCeremonyCard) {
        guard let seed = store.debugMnemonic else { return }
        if coordinator != nil, meta?.vaultID == card.vaultID {
            transport?.ingest(card.messages)
            return
        }
        guard let slot = bridge.memberSlot else { return }
        start(vaultID: card.vaultID, name: card.name, emoji: card.emoji,
              index: slot.index, n: card.memberCount, k: card.threshold,
              seed: seed, initial: card.messages)
    }

    /// Leave the active pot view (keeps the persisted vault).
    func close() { coordinator = nil; transport = nil; meta = nil }

    private func start(vaultID: String, name: String, emoji: String,
                       index: UInt16, n: UInt16, k: UInt16, seed: String,
                       initial: [[String: Any]]?) {
        let t = IMessageTransport()
        // Per-member seed derivation: incorporates the index, so members get
        // distinct entropy whether or not their wallet seeds differ (true on
        // real devices; identical in the Simulator harness). Trustless either
        // way — each member's share stays on their own device.
        let memberSeed = FrostTestSeeds.seed(base: seed, memberIndex: Int(index))
        let cfg = VaultCoordinator.Config(vaultID: vaultID, name: name, memberIndex: index,
                                          memberCount: n, threshold: k, emoji: emoji)
        guard let c = try? VaultCoordinator(config: cfg, transport: t,
                                            chain: store.chain, mnemonic: memberSeed) else { return }
        let chat = bridge.chatKey
        let vs = VaultStore()
        c.onVaultReady = { r in var rec = r; rec.chatKey = chat; vs.save(rec) }
        t.onOutgoing = { [weak self] msgs in
            self?.bridge.updateCeremonyCard(
                PotCeremonyCard(vaultID: vaultID, name: name, emoji: emoji,
                                memberCount: n, threshold: k, messages: msgs))
        }
        transport = t
        meta = (vaultID, name, emoji, n, k)
        coordinator = c
        if let initial { t.ingest(initial) }   // catch up on the card's state
        Task { await c.start() }
    }
}
