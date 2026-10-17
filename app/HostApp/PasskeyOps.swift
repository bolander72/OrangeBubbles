import AuthenticationServices
import Foundation
import WalletKit

/// Passkey ceremonies run in the HOST APP because iOS's WebAuthn
/// association check misbehaves inside Messages extensions (error 1004
/// despite a valid AASA). The host and extension share the keychain
/// group and App Group, so work done here is immediately visible in
/// Messages: same LocalSecretsStore, same backup store, same provider
/// flag.
@MainActor
final class PasskeyOps: ObservableObject {
    enum WalletState: Equatable {
        case checking
        case noWallet
        case upgradable          // wallet present, keychain-sealed backup
        case passkeyActive       // wallet present, passkey-sealed
        case lockedPasskeyBackup // no local wallet, passkey-sealed envelope in iCloud
        case working(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var state: WalletState = .checking

    private let localSecrets = LocalSecretsStore(network: ChainConfig.fromBundle().network)
    private let backupStore = ICloudBackupStore(network: ChainConfig.fromBundle().network)
    var anchor: @MainActor () -> ASPresentationAnchor? = { nil }

    /// Shared with the extension via the App Group.
    static var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: SharedSnapshot.appGroupID)
    }

    static var knownProvider: String? {
        get { groupDefaults?.string(forKey: "backupKeyProvider.v1") }
        set { groupDefaults?.set(newValue, forKey: "backupKeyProvider.v1") }
    }

    func determineState() async {
        state = .checking
        if localSecrets.load() != nil {
            state = Self.knownProvider == "passkey-prf" ? .passkeyActive : .upgradable
            return
        }
        let store = backupStore
        let exists = (try? await Task.detached { store.backupExists() }.value) ?? false
        if exists {
            let envelope = try? await Task.detached { try await store.load() }.value
            state = envelope?.keyProvider == "passkey-prf" ? .lockedPasskeyBackup : .noWallet
        } else {
            state = .noWallet
        }
    }

    /// Registers the wallet passkey and reseals the backup with its PRF
    /// output — ADR 0002's end state, executed in app context.
    func upgrade() async {
        guard #available(iOS 18.0, *) else {
            state = .failed("Passkey protection needs iOS 18 or later.")
            return
        }
        guard let secrets = localSecrets.load() else {
            state = .failed("Open OrangeBubbles in Messages first so the wallet exists on this device.")
            return
        }
        state = .working("Creating your passkey…")
        do {
            let prf = PasskeyPRFKeyProvider(anchor: anchor)
            let material = try await prf.keyMaterial()
            let envelope = try BackupCrypto.seal(
                secrets,
                inputKeyMaterial: material,
                keyProvider: prf.identifier
            )
            let store = backupStore
            try await Task.detached { try store.save(envelope) }.value
            Self.knownProvider = prf.identifier
            state = .done("Passkey protection is active. Your backup now requires Face ID to decrypt — on any device.")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            state = .failed(message)
        }
    }

    /// Fresh-device unlock for passkey-sealed backups: assert, decrypt,
    /// hand the secrets to the extension via the shared local store.
    func unlock() async {
        guard #available(iOS 18.0, *) else {
            state = .failed("This backup is protected by a passkey and needs iOS 18 or later.")
            return
        }
        state = .working("Unlocking with your passkey…")
        do {
            let store = backupStore
            let envelope = try await Task.detached { try await store.load() }.value
            let prf = PasskeyPRFKeyProvider(anchor: anchor)
            guard let material = try await prf.existingKeyMaterial() else {
                throw WalletKitError.keyUnavailable(
                    "Couldn't reach the wallet passkey. Check that iCloud Keychain is on and try again."
                )
            }
            let secrets = try BackupCrypto.open(envelope, inputKeyMaterial: material)
            localSecrets.save(secrets)
            Self.knownProvider = envelope.keyProvider
            state = .done("Wallet unlocked. Open OrangeBubbles in Messages — it's ready.")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            state = .failed(message)
        }
    }
}
