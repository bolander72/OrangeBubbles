import Foundation

/// A completed vault, persisted so it survives closing the sheet / app
/// relaunch — no re-running DKG. Holds this device's FROST key material
/// (secret) plus the shared public data needed to watch and spend.
struct VaultRecord: Codable, Identifiable, Equatable {
    let vaultID: String
    var name: String
    let memberIndex: UInt16
    let memberCount: UInt16
    let threshold: UInt16
    let keyPackage: String          // SECRET — this device's share
    let publicKeyPackage: String    // shared
    let vaultXonlyHex: String
    let address: String
    /// User-chosen emoji for the pot (falls back to a name-derived one).
    var emoji: String?
    /// Fingerprint of the iMessage chat this pot lives in, if it was created
    /// from within a conversation. Lets Home show "this chat has a pot".
    var chatKey: String?
    /// Debug transport host (test harness only).
    var relayHost: String?
    let createdAt: Date

    var id: String { vaultID }
    var thresholdLabel: String { "\(threshold) of \(memberCount)" }
}

/// Device-local persistence for vaults. Key material lives here, so it's a
/// keychain item (device-only, after-first-unlock), not iCloud — vault key
/// shares are per-device by design (each member holds a distinct share).
struct VaultStore {
    private let service = "com.bolandcompany.orangebubbles.vaults"

    func all() -> [VaultRecord] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[CFString: Any]] else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return items.compactMap { item in
            (item[kSecValueData] as? Data).flatMap { try? decoder.decode(VaultRecord.self, from: $0) }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func save(_ record: VaultRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: record.vaultID,
        ]
        SecItemDelete(base as CFDictionary)
        var attrs = base
        attrs[kSecValueData] = data
        attrs[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecAttrLabel] = "OrangeBubbles vault: \(record.name)"
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
