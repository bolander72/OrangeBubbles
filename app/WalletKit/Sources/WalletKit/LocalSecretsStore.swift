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
///
/// One slot per network: a wallet created by a signet (test) build must
/// never be handed to a mainnet build — BDK aborts the process when a
/// wallet's chain and the Esplora it syncs against disagree ("remote
/// esplora should have same genesis block"), which is exactly what the
/// first mainnet TestFlight did on a phone that had run the signet beta.
/// Mainnet keeps the original account name; other networks are suffixed.
public struct LocalSecretsStore: Sendable {
    private let service: String
    private let network: NetworkKind

    public init(network: NetworkKind, service: String = "com.bolandcompany.orangebubbles.local-secrets") {
        self.service = service
        self.network = network
    }

    private static let legacyAccount = "wallet-secrets"

    private func account(for network: NetworkKind) -> String {
        network == .bitcoin ? Self.legacyAccount : "\(Self.legacyAccount).\(network.rawValue)"
    }

    private var account: String { account(for: network) }

    /// This network's cached wallet, or nil. A wallet found in the slot
    /// whose network field disagrees is never returned (see
    /// `relocateLegacyItemIfForeign` for the pre-slot migration).
    public func load() -> WalletSecrets? {
        guard let secrets = read(account: account), secrets.network == network else { return nil }
        return secrets
    }

    private func read(account: String) -> WalletSecrets? {
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

    /// Moves a pre-slot wallet (stored under the mainnet-named account
    /// before slots existed) that belongs to a non-mainnet network into
    /// that network's slot. Any store may call this at startup — a new
    /// signet build must find the signet beta's wallet just as a mainnet
    /// build must get it out of the way.
    ///
    /// Transactional: the legacy item is removed only after the target
    /// slot has been re-read and holds exactly the migrated payload. If
    /// the target slot already holds a *different* wallet, the legacy one
    /// is preserved under an orphan account rather than discarded — seed
    /// material is never the thing that loses a race. Returns the network
    /// relocated, if any.
    @discardableResult
    public func relocateLegacyItemIfForeign() -> NetworkKind? {
        guard let legacy = read(account: Self.legacyAccount), legacy.network != .bitcoin else { return nil }
        let targetAccount = account(for: legacy.network)
        let destination: String
        if let existing = read(account: targetAccount), existing != legacy {
            destination = "\(targetAccount).orphan-\(Int(Date().timeIntervalSince1970))"
        } else {
            destination = targetAccount
        }
        guard write(legacy, account: destination), read(account: destination) == legacy else {
            return nil // leave the legacy item exactly where it was
        }
        delete(account: Self.legacyAccount)
        return legacy.network
    }

    /// Writes this network's cached wallet. Returns false when the
    /// keychain refused the write (callers that must know, such as the
    /// migration, check it; the auto-wallet path logs and carries on,
    /// since the iCloud envelope remains the durable copy).
    @discardableResult
    public func save(_ secrets: WalletSecrets) -> Bool {
        let ok = write(secrets, account: account)
        if !ok { NSLog("LocalSecretsStore: keychain write failed for %@", account) }
        return ok
    }

    private func write(_ secrets: WalletSecrets, account: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(secrets) else { return false }

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
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    public func clear() { delete(account: account) }

    private func delete(account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
