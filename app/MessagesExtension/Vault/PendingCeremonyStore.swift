import Foundation

/// A DKG-in-progress, persisted so a member can close the app mid-setup and
/// finish on reopen (or via the container app's background push handler). Holds
/// the config, the member's derived seed (so the container app can resume
/// without loading wallet secrets), and the coordinator's persistable DKG state
/// (encoded session + which rounds were already folded in). Secret material —
/// keychain, device-only, shared access group.
struct PendingCeremony: Codable, Identifiable, Equatable {
    let vaultID: String
    let name: String
    let emoji: String
    let memberIndex: UInt16
    let memberCount: UInt16
    let threshold: UInt16
    let chatKey: String?
    /// Member's per-index seed (FrostTestSeeds.seed(base:index:)) — lets the
    /// background handler resume without touching wallet secrets.
    let memberSeed: String
    var sessionData: Data
    var seenKeys: [String]
    var id: String { vaultID }

    var config: VaultCoordinator.Config {
        VaultCoordinator.Config(vaultID: vaultID, name: name, memberIndex: memberIndex,
                                memberCount: memberCount, threshold: threshold, emoji: emoji)
    }
}

struct PendingCeremonyStore {
    private let service = "com.bolandcompany.orangebubbles.pending-ceremonies"

    func all() -> [PendingCeremony] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[CFString: Any]] else { return [] }
        let decoder = JSONDecoder()
        return items.compactMap { ($0[kSecValueData] as? Data).flatMap { try? decoder.decode(PendingCeremony.self, from: $0) } }
    }

    func save(_ c: PendingCeremony) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: c.vaultID,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData] = data
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func delete(vaultID: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: vaultID,
        ] as CFDictionary)
    }
}
