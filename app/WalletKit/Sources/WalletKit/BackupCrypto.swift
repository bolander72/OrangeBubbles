import CryptoKit
import Foundation

/// Seals/opens the `WalletSecrets` bundle with ChaCha20-Poly1305.
///
/// The AEAD key is never used raw: whatever the key provider hands us
/// (a random 32-byte keychain secret or a passkey PRF output) goes through
/// HKDF-SHA256 with a per-backup random salt, so envelopes are not linkable
/// across rewrites and a future provider migration only changes the input
/// key material.
public enum BackupCrypto {
    public static let cipherIdentifier = "chacha20poly1305+hkdf-sha256"
    // Frozen forever: this string is baked into every existing backup's
    // key derivation. The product was renamed to Satchel; this stays.
    private static let hkdfInfo = Data("wizard-imessage-wallet backup v1".utf8)

    public static func seal(
        _ secrets: WalletSecrets,
        inputKeyMaterial: Data,
        keyProvider: String
    ) throws -> BackupEnvelope {
        var salt = Data(count: 32)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else {
            throw WalletKitError.internalError("SecRandomCopyBytes failed (\(result))")
        }

        let key = deriveKey(inputKeyMaterial: inputKeyMaterial, salt: salt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(secrets)
        let box = try ChaChaPoly.seal(plaintext, using: key)

        return BackupEnvelope(
            cipher: cipherIdentifier,
            keyProvider: keyProvider,
            salt: salt.base64EncodedString(),
            sealed: box.combined.base64EncodedString(),
            network: secrets.network,
            scriptType: secrets.scriptType,
            createdAt: secrets.createdAt
        )
    }

    public static func open(_ envelope: BackupEnvelope, inputKeyMaterial: Data) throws -> WalletSecrets {
        guard envelope.cipher == cipherIdentifier else {
            throw WalletKitError.backupCorrupted("unknown cipher \(envelope.cipher)")
        }
        guard let salt = Data(base64Encoded: envelope.salt),
              let sealed = Data(base64Encoded: envelope.sealed)
        else {
            throw WalletKitError.backupCorrupted("envelope fields are not valid base64")
        }

        let key = deriveKey(inputKeyMaterial: inputKeyMaterial, salt: salt)
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed)
            let plaintext = try ChaChaPoly.open(box, using: key)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WalletSecrets.self, from: plaintext)
        } catch let error as WalletKitError {
            throw error
        } catch {
            throw WalletKitError.backupCorrupted("decryption failed — wrong key or damaged data")
        }
    }

    static func deriveKey(inputKeyMaterial: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: hkdfInfo,
            outputByteCount: 32
        )
    }
}
