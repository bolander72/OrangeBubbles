import Foundation
import Security

/// Device-local cache of the decrypted `WalletSecrets`, enabling the
/// auto-wallet model: the extension opens straight into the wallet with no
/// prompts, like a mailbox.
///
/// Storage: a non-synchronizable keychain item, `AfterFirstUnlockThisDeviceOnly`
/// — protected by the device passcode/Secure Enclave at rest, never in any
/// backup that leaves the device class, never synced. The *cloud* copy of
/// the secrets remains the encrypted envelope in iCloud (sealed by the
/// keychain or passkey provider); this cache only removes per-open
/// decryption prompts on a device that already restored once.
///
/// Security posture (ADR 0004): possession of the unlocked device grants
/// balance visibility and receiving — spending and seed reveal stay behind
/// Face ID at the app layer.
public struct LocalSecretsStore: Sendable {
    private let service: String
    private let legacyService: String?
    private let account = "wallet-secrets"

    public init(
        service: String = "com.bolandcompany.orangebubbles.local-secrets",
        legacyService: String? = "com.bolandcompany.satchel.local-secrets"
    ) {
        self.service = service
        self.legacyService = legacyService
    }

    public func load() -> WalletSecrets? {
        if let secrets = load(service: service) { return secrets }
        if let legacyService, let secrets = load(service: legacyService) {
            save(secrets) // re-home under the new service
            return secrets
        }
        return nil
    }

    private func load(service: String) -> WalletSecrets? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WalletSecrets.self, from: data)
    }

    public func save(_ secrets: WalletSecrets) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(secrets) else { return }

        let base: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(base as CFDictionary)

        var attributes = base
        attributes[kSecValueData] = data
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable] = false
        attributes[kSecAttrLabel] = "OrangeBubbles wallet (this device)"
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func clear() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
