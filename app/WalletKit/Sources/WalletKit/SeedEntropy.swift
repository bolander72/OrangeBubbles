import BitcoinDevKit
import CryptoKit
import Foundation

/// Entropy for seed generation, hardened against the failure mode that
/// drained Coldcard wallets in 2026: a single silently-broken RNG path.
///
/// Three sources are combined with HKDF-SHA256:
///   1. `SecRandomCopyBytes` — Apple's kernel CSPRNG (Fortuna), seeded by
///      the Secure Enclave's hardware TRNG. The primary source; failure
///      throws (fail closed, never degrade).
///   2. CryptoKit `SymmetricKey` — an independent code path into the
///      system RNG (guards against a bug in how we call source 1).
///   3. BitcoinDevKit's internal Rust RNG — a genuinely separate
///      library/toolchain path (rust getrandom), mixed in WITHOUT being
///      trusted.
///
/// HKDF's extractor guarantees: if AT LEAST ONE source is uniformly
/// random, the output is uniformly random. A Coldcard-style regression
/// in any single path — ours, Apple's API surface, or BDK's — can no
/// longer produce predictable seeds.
public enum SeedEntropy {
    public static func generate(byteCount: Int) throws -> Data {
        precondition(byteCount == 16 || byteCount == 32, "BIP39 entropy is 16 or 32 bytes")

        // Source 1: kernel CSPRNG — mandatory, fail closed.
        var source1 = Data(count: 32)
        let status = source1.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw WalletKitError.internalError("Secure random generator unavailable (\(status)) — refusing to create a wallet.")
        }

        // Source 2: CryptoKit path into the system RNG.
        let source2 = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

        // Source 3: BDK's Rust RNG, via a throwaway mnemonic's words.
        // Untrusted — merely additional input keying material.
        let source3 = Data(Mnemonic(wordCount: .words24).description.utf8)

        let combined = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: source1 + source2 + source3),
            salt: Data(count: 0),
            info: Data("orangebubbles seed entropy v1".utf8),
            outputByteCount: byteCount
        )
        return combined.withUnsafeBytes { Data($0) }
    }
}
