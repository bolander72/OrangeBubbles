import CryptoKit
import Foundation
import OBFrost

/// Per-member cryptographic identity for a FROST vault (ADR 0008 frost-v1).
///
/// A member has two things beyond their integer index:
///   • a FROST key package (secret, produced by DKG)
///   • a static Curve25519 key for **pairwise encryption of DKG secret
///     shares** — the DKG round-2 packages are secrets addressed to a
///     specific recipient, but a group chat shows every message to
///     everyone, so each share is sealed to its recipient's public key.
///
/// The Curve25519 key derives deterministically from the member's wallet
/// seed, so it survives restore and never needs its own backup.
public struct FrostMemberIdentity: Sendable {
    public let index: UInt16
    public let agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    public var agreementPublicKeyBase64: String {
        agreementPrivateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Derives the encryption key from the seed (domain-separated from the
    /// wallet's spending keys via HKDF).
    public init(index: UInt16, mnemonic: String) throws {
        self.index = index
        let seedMaterial = Data(SHA256.hash(data: Data(
            "orangebubbles/frost/agreement/v1|\(mnemonic)".utf8
        )))
        self.agreementPrivateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seedMaterial)
    }
}

/// Seals/opens a DKG secret share for a specific recipient using
/// X25519 ECDH → HKDF → ChaCha20-Poly1305.
public enum PairwiseSeal {
    public static func seal(
        _ plaintext: String,
        from sender: FrostMemberIdentity,
        toPublicKeyBase64 recipientPub: String
    ) throws -> String {
        guard let rawPub = Data(base64Encoded: recipientPub) else {
            throw WalletKitError.internalError("bad recipient key")
        }
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawPub)
        let shared = try sender.agreementPrivateKey.sharedSecretFromKeyAgreement(with: recipient)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("orangebubbles/frost/dkg-share/v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        let box = try ChaChaPoly.seal(Data(plaintext.utf8), using: key)
        return box.combined.base64EncodedString()
    }

    public static func open(
        _ sealed: String,
        recipient: FrostMemberIdentity,
        fromPublicKeyBase64 senderPub: String
    ) throws -> String {
        guard let rawPub = Data(base64Encoded: senderPub),
              let combined = Data(base64Encoded: sealed) else {
            throw WalletKitError.internalError("bad sealed share")
        }
        let sender = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawPub)
        let shared = try recipient.agreementPrivateKey.sharedSecretFromKeyAgreement(with: sender)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("orangebubbles/frost/dkg-share/v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let opened = try ChaChaPoly.open(box, using: key)
        return String(decoding: opened, as: UTF8.self)
    }
}

/// Drives one member's side of the 3-round FROST DKG. Transport-agnostic:
/// it consumes and produces plain `Codable` messages, which the app wraps
/// in iMessage cards (or a debug relay). Persistable so a ceremony
/// survives the app being backgrounded/killed between rounds.
public final class FrostDKGSession: Codable {
    public enum Phase: String, Codable {
        case round1        // committed; waiting for peers' round-1 publics
        case round2        // sent encrypted shares; waiting for peers' shares
        case complete
    }

    public let vaultID: String
    public let selfIndex: UInt16
    public let memberCount: UInt16      // n
    public let threshold: UInt16        // k
    public private(set) var phase: Phase

    // Public identity broadcast to peers.
    public let selfAgreementPublicKey: String
    // Collected as peers announce (index -> agreement pubkey).
    public private(set) var peerAgreementKeys: [UInt16: String]

    // Round-1: our public package (broadcast) + peers' packages collected.
    public private(set) var round1Public: String
    public private(set) var peerRound1: [UInt16: String]

    // Local secrets (never transmitted in the clear).
    private var round1Secret: String
    private var round2Secret: String?

    // Round-2: encrypted shares we received, by sender index.
    public private(set) var peerRound2Sealed: [UInt16: String]

    // Result.
    public private(set) var keyPackage: String?
    public private(set) var publicKeyPackage: String?
    public private(set) var vaultXonlyHex: String?

    private enum CodingKeys: String, CodingKey {
        case vaultID, selfIndex, memberCount, threshold, phase
        case selfAgreementPublicKey, peerAgreementKeys
        case round1Public, peerRound1, round1Secret, round2Secret
        case peerRound2Sealed, keyPackage, publicKeyPackage, vaultXonlyHex
    }

    /// Begins the ceremony: runs DKG round 1 immediately.
    public init(
        vaultID: String,
        identity: FrostMemberIdentity,
        memberCount: UInt16,
        threshold: UInt16
    ) throws {
        self.vaultID = vaultID
        self.selfIndex = identity.index
        self.memberCount = memberCount
        self.threshold = threshold
        self.selfAgreementPublicKey = identity.agreementPublicKeyBase64
        self.peerAgreementKeys = [:]
        self.peerRound1 = [:]
        self.peerRound2Sealed = [:]

        let r1 = try dkgPart1(participantIndex: identity.index, maxSigners: memberCount, minSigners: threshold)
        self.round1Public = r1.publicPackage
        self.round1Secret = r1.secretPackage
        self.phase = .round1
    }

    /// The message every member broadcasts in round 1.
    public struct Round1Message: Codable {
        public let index: UInt16
        public let agreementKey: String
        public let publicPackage: String
    }

    public func round1Message() -> Round1Message {
        Round1Message(index: selfIndex, agreementKey: selfAgreementPublicKey, publicPackage: round1Public)
    }

    /// Ingest a peer's round-1 broadcast. When all n are in, advance to
    /// round 2 and return the encrypted shares to send.
    public func receiveRound1(_ msg: Round1Message, identity: FrostMemberIdentity) throws -> Round2Message? {
        guard msg.index != selfIndex else { return nil }
        peerAgreementKeys[msg.index] = msg.agreementKey
        peerRound1[msg.index] = msg.publicPackage
        guard peerRound1.count == Int(memberCount) - 1, phase == .round1 else { return nil }

        let r2 = try dkgPart2(round1Secret: round1Secret, round1PublicByIndex: peerRound1, maxSigners: memberCount)
        self.round2Secret = r2.secretPackage
        // Seal each outgoing share to its recipient.
        var sealed: [UInt16: String] = [:]
        for (recipientIndex, share) in r2.outgoing {
            guard let recipientPub = peerAgreementKeys[recipientIndex] else { continue }
            sealed[recipientIndex] = try PairwiseSeal.seal(share, from: identity, toPublicKeyBase64: recipientPub)
        }
        phase = .round2
        return Round2Message(fromIndex: selfIndex, sealedShares: sealed)
    }

    /// Round-2 broadcast: encrypted per-recipient shares (only the intended
    /// recipient can open their entry).
    public struct Round2Message: Codable {
        public let fromIndex: UInt16
        public let sealedShares: [UInt16: String]
    }

    /// Ingest a peer's round-2 message. When all shares addressed to us are
    /// in, finalize the vault key and return the shared public package.
    @discardableResult
    public func receiveRound2(_ msg: Round2Message, identity: FrostMemberIdentity) throws -> Bool {
        guard msg.fromIndex != selfIndex else { return false }
        guard let sealedForMe = msg.sealedShares[selfIndex],
              let senderPub = peerAgreementKeys[msg.fromIndex] else { return false }
        let opened = try PairwiseSeal.open(sealedForMe, recipient: identity, fromPublicKeyBase64: senderPub)
        peerRound2Sealed[msg.fromIndex] = opened  // store the OPENED share

        guard peerRound2Sealed.count == Int(memberCount) - 1, phase == .round2,
              let round2Secret else { return false }

        let result = try dkgPart3(
            round2Secret: round2Secret,
            round1PublicByIndex: peerRound1,
            round2SecretByIndex: peerRound2Sealed
        )
        self.keyPackage = result.keyPackage
        self.publicKeyPackage = result.publicKeyPackage
        self.vaultXonlyHex = result.xonlyPubkeyHex
        self.phase = .complete
        return true
    }
}
