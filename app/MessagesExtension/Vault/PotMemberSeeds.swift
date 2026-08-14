import WalletKit

/// Derives a pot member's FROST seed from their wallet mnemonic and their
/// fixed member slot. Every device derives from its OWN wallet seed, so
/// distinct members get distinct seeds; the slot in the derivation keeps a
/// member's pot identity stable across app reinstalls (the slot is pinned
/// in the vault record at creation).
///
/// The vault test lab leans on the same derivation for the opposite trick:
/// one device standing in for several members by varying the index over a
/// single base seed.
enum PotMemberSeeds {
    static func seed(base: String, memberIndex: Int) -> String {
        (try? WalletEngine.deterministicMnemonic(from: "\(base)#frost-member-\(memberIndex)")) ?? base
    }
}
