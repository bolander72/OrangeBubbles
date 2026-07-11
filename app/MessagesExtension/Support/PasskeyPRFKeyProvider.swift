import AuthenticationServices
import CryptoKit
import Foundation
import WalletKit

enum WalletIdentity {
    /// Relying party for the wallet passkey. The domain must serve an AASA
    /// file with `webcredentials` listing this app (server/ has the route;
    /// static hosting works too). Until it does, passkey registration fails
    /// at runtime and WalletStore falls back to the synced-keychain provider.
    static let relyingParty = "wallet.taprootwizards.com"
}

/// ADR 0002's end state: the backup encryption key comes from the PRF
/// (pseudo-random function) extension of a passkey scoped to our domain.
/// Decrypting the backup then *cryptographically requires* a platform
/// authenticator assertion (Face ID) — not just keychain access — and the
/// passkey syncs across the user's devices via iCloud Keychain, so restore
/// on a new iPhone still works.
///
/// The PRF output for a fixed salt is stable per credential, which is what
/// makes it usable as key material.
@available(iOS 18.0, *)
final class PasskeyPRFKeyProvider: NSObject, BackupKeyProvider, @unchecked Sendable {
    let identifier = "passkey-prf"

    /// Fixed, public PRF evaluation salt. Not secret — security comes from
    /// the credential; the salt just domain-separates this use.
    // Frozen forever: PRF output depends on this salt; renaming the product
    // to Satchel must not change it or passkey-sealed backups break.
    private static let prfSalt = Data(SHA256.hash(data: Data("wizard-imessage-wallet/backup-key/v1".utf8)))

    private let relyingParty: String
    private let anchor: @MainActor () -> ASPresentationAnchor?
    /// Stable passkey user handle, kept in the synced keychain so
    /// re-registration replaces the credential instead of piling up
    /// duplicates in the user's passkey list.
    private let userIDStore = SyncedKeychainKeyProvider(
        service: "com.taprootwizards.imessagewallet.passkey-user-id"
    )

    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var activeController: ASAuthorizationController?

    init(relyingParty: String = WalletIdentity.relyingParty, anchor: @escaping @MainActor () -> ASPresentationAnchor?) {
        self.relyingParty = relyingParty
        self.anchor = anchor
    }

    // MARK: - BackupKeyProvider

    /// Asserts against an existing passkey, registering one first if needed.
    func keyMaterial() async throws -> Data {
        if let existing = try? await assertPRF() {
            return existing
        }
        return try await registerAndDerive()
    }

    /// Assertion only — restore must never mint a fresh credential, because
    /// a new passkey has a new PRF output and could not decrypt the backup.
    func existingKeyMaterial() async throws -> Data? {
        do {
            return try await assertPRF()
        } catch let error as ASAuthorizationError where error.code == .canceled {
            throw WalletKitError.keyUnavailable(
                "Passkey sign-in was canceled or no wallet passkey is on this device yet. Passkeys sync via iCloud Keychain — make sure it's enabled, then try again."
            )
        } catch {
            return nil
        }
    }

    // MARK: - WebAuthn plumbing

    private func registerAndDerive() async throws -> Data {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
        let request = provider.createCredentialRegistrationRequest(
            challenge: Self.randomBytes(32),
            name: "Satchel",
            userID: try await userIDStore.keyMaterial()
        )
        request.userVerificationPreference = .required
        request.prf = .inputValues(.init(saltInput1: Self.prfSalt))

        let authorization = try await perform(request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
            throw WalletKitError.keyUnavailable("Unexpected passkey registration result.")
        }
        if let first = credential.prf?.first {
            return first.withUnsafeBytes { Data($0) }
        }
        // Some authenticators only evaluate PRF on assertion, not creation.
        return try await assertPRF()
    }

    private func assertPRF() async throws -> Data {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
        let request = provider.createCredentialAssertionRequest(challenge: Self.randomBytes(32))
        request.userVerificationPreference = .required
        request.prf = .inputValues(.init(saltInput1: Self.prfSalt))

        let authorization = try await perform(request)
        guard
            let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
            let first = credential.prf?.first
        else {
            throw WalletKitError.keyUnavailable(
                "This device's passkey did not return PRF output; cannot derive the backup key."
            )
        }
        return first.withUnsafeBytes { Data($0) }
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            Task { @MainActor in
                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                self.activeController = controller
                controller.performRequests()
            }
        }
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return bytes
    }
}

@available(iOS 18.0, *)
extension PasskeyPRFKeyProvider: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        continuation?.resume(returning: authorization)
        continuation = nil
        activeController = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
        activeController = nil
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor() ?? ASPresentationAnchor() }
    }
}
