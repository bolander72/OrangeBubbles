import Foundation
import Security

/// Source of the input key material that encrypts the iCloud backup.
///
/// Two implementations: `PasskeyPRFKeyProvider` (app layer, iOS 18+ —
/// Face ID assertion → PRF extension output → HKDF; preferred, requires the
/// AASA file live on the relying-party domain) and
/// `SyncedKeychainKeyProvider` (fallback). The envelope's `keyProvider`
/// field records which one sealed a backup — see
/// docs/decisions/0002-encryption-path.md.
public protocol BackupKeyProvider: Sendable {
    /// Stable identifier recorded in the envelope so restore knows which
    /// provider to ask for the key.
    var identifier: String { get }
    /// Returns key material, creating it if this is first run.
    func keyMaterial() async throws -> Data
    /// Returns key material only if it already exists (restore path).
    func existingKeyMaterial() async throws -> Data?
}

/// A random 32-byte secret in the *synchronized* (iCloud) Keychain.
///
/// Because the item syncs via iCloud Keychain, a reinstall or a new iPhone
/// on the same Apple ID can decrypt the backup with no seed phrase. Face ID
/// is enforced at the app layer (LocalAuthentication) before this provider
/// is asked for the key — synchronizable items cannot carry a
/// biometry-bound access control, which is exactly the trade the V0 spec
/// accepts. The backup file (iCloud Drive) and this key (iCloud Keychain)
/// travel in different Apple systems; iCloud Keychain additionally requires
/// device passcode trust to join, which is what gates a brand-new device.
public struct SyncedKeychainKeyProvider: BackupKeyProvider {
    public let identifier = "synced-keychain"

    private let service: String
    /// Pre-rename wallets stored their key under this service; read-only.
    private let legacyService: String?
    private let account: String

    public init(
        service: String = "com.bolandcompany.orangebubbles.backup-key",
        legacyService: String? = "com.bolandcompany.satchel.backup-key",
        account: String = "primary"
    ) {
        self.service = service
        self.legacyService = legacyService
        self.account = account
    }

    public func keyMaterial() async throws -> Data {
        if let existing = try await existingKeyMaterial() { return existing }

        var bytes = Data(count: 32)
        let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else {
            throw WalletKitError.keyUnavailable("SecRandomCopyBytes failed (\(result))")
        }

        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: bytes,
            kSecAttrSynchronizable: Self.synchronizable,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel: "OrangeBubbles backup key",
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Lost a race with another device/process — use the winner's key.
            if let existing = try await existingKeyMaterial() { return existing }
        }
        guard status == errSecSuccess else {
            throw WalletKitError.keyUnavailable("keychain add failed (\(status))")
        }
        return bytes
    }

    /// iCloud Keychain sync requires an app-identifier entitlement that
    /// simulator builds don't carry (SecItem returns -34018), and simulator
    /// keychains never actually sync — so only mark items synchronizable on
    /// real devices.
    private static var synchronizable: Bool {
        #if targetEnvironment(simulator)
            return false
        #else
            return true
        #endif
    }

    public func existingKeyMaterial() async throws -> Data? {
        if let data = try read(service: service) {
            return data
        }
        // Legacy fallback: a pre-rename wallet's key. Found keys keep
        // working from their old home; new keys are created under the
        // new service.
        if let legacyService, let data = try read(service: legacyService) {
            return data
        }
        return nil
    }

    private func read(service: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else {
                throw WalletKitError.keyUnavailable("keychain item empty")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw WalletKitError.keyUnavailable("keychain read failed (\(status))")
        }
    }
}
