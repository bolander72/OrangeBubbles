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
    /// Members who have left / gone inactive (by index). Erodes the pot's
    /// redundancy buffer; drives the health warning + Refresh nudge (ADR 0009).
    var inactiveMembers: [UInt16] = []
    /// This device left the pot (Leave = archive, share kept so we can still be
    /// asked for one last signature, and can Rejoin). Hidden from the main list.
    var archived: Bool = false
    /// Opt-in "max security, no cloud backup": keep this share device-only so a
    /// lost phone loses it. Default is OFF — shares are iCloud-Keychain backed so
    /// device loss is recoverable (ADR 0009 Layer 1).
    var deviceOnly: Bool = false
    let createdAt: Date

    var id: String { vaultID }
    var thresholdLabel: String { "\(threshold) of \(memberCount)" }
    /// Live signers = members minus those who left; buffer = live − threshold.
    var liveCount: Int { Int(memberCount) - inactiveMembers.count }
    var redundancyBuffer: Int { liveCount - Int(threshold) }
}

/// Keychain persistence for vaults (this device's FROST share). By default the
/// item is **iCloud-Keychain synced** (kSecAttrSynchronizable) so a lost phone
/// can restore its share on a new device — device loss no longer loses the share
/// (ADR 0009 Layer 1). E2E-encrypted by iCloud Keychain; an attacker still needs
/// k separate members' iClouds. A record may opt into device-only for max
/// security (no cloud backup). Reads/deletes match both via `SynchronizableAny`.
struct VaultStore {
    private let service = "com.bolandcompany.orangebubbles.vaults"

    func all() -> [VaultRecord] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
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
        // Remove any prior copy (synced or device-only) before re-adding.
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: record.vaultID,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ] as CFDictionary)
        var attrs: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: record.vaultID,
            kSecValueData: data,
            kSecAttrLabel: "OrangeBubbles vault: \(record.name)",
        ]
        // Default: sync to iCloud Keychain (recoverable). Opt-out: device-only.
        attrs[kSecAttrSynchronizable] = record.deviceOnly ? kCFBooleanFalse : kCFBooleanTrue
        attrs[kSecAttrAccessible] = record.deviceOnly
            ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            : kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func delete(vaultID: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: vaultID,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
        ] as CFDictionary)
    }
}
