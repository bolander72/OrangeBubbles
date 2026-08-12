import Foundation
import OBFrost

/// One signer's side of a FROST threshold-signing ceremony for a single
/// spend proposal (ADR 0008 frost-v1, task 3).
///
/// # Nonce discipline (the part that loses funds if wrong)
/// FROST/Schnorr threshold signing leaks the secret share if a nonce is
/// ever used to produce two different signatures. This type makes that
/// **impossible by construction**:
///   • Nonces are generated exactly once, at `commitments()`, and bound to
///     this session (one session == one proposal == one fixed set of
///     input sighashes). Calling `commitments()` again returns the SAME
///     commitments — never fresh nonces.
///   • `sign(...)` produces each input's partial signature exactly once
///     and caches it. Calling `sign(...)` again returns the cached
///     partials verbatim — it never re-runs round 2. So a user re-tapping
///     a signing card, or the app relaunching mid-ceremony, can never
///     produce a second signature under the same nonce.
///   • The message set is fixed at init. A different spend is a different
///     session with fresh nonces — signing a changed message is not
///     possible on this object.
///
/// Codable so an in-flight ceremony survives app backgrounding/kills with
/// its nonce commitment intact.
public final class FrostSigningSession: Codable {
    public enum Phase: String, Codable {
        case created      // nothing committed yet
        case committed    // nonces generated, commitments broadcast
        case signed       // partials produced (terminal for this signer)
    }

    public let vaultID: String
    public let proposalID: String
    public let selfIndex: UInt16
    /// One 32-byte sighash (hex) per transaction input, fixed forever.
    public let sighashes: [String]
    public private(set) var phase: Phase

    private let keyPackage: String
    /// SECRET nonces, one per input. Zeroed once `signed`.
    private var nonces: [String]?
    /// Our public commitments, one per input. Persist so re-commit is stable.
    public private(set) var commitmentsPerInput: [String]?
    /// Cached partial signatures, one per input. The ONLY signing output.
    public private(set) var partialsPerInput: [String]?

    private enum CodingKeys: String, CodingKey {
        case vaultID, proposalID, selfIndex, sighashes, phase
        case keyPackage, nonces, commitmentsPerInput, partialsPerInput
    }

    public init(vaultID: String, proposalID: String, selfIndex: UInt16, keyPackage: String, sighashes: [String]) {
        self.vaultID = vaultID
        self.proposalID = proposalID
        self.selfIndex = selfIndex
        self.keyPackage = keyPackage
        self.sighashes = sighashes
        self.phase = .created
    }

    /// Round 1 — idempotent. Generates nonces + commitments the first time;
    /// thereafter returns the identical commitments. Never mints new nonces
    /// for a session that already has them.
    public func commitments() throws -> [String] {
        if let existing = commitmentsPerInput { return existing }
        var nonceList: [String] = []
        var commitList: [String] = []
        for _ in sighashes {
            let c = try signCommit(keyPackage: keyPackage)
            nonceList.append(c.nonces)
            commitList.append(c.commitments)
        }
        self.nonces = nonceList
        self.commitmentsPerInput = commitList
        self.phase = .committed
        return commitList
    }

    /// Round 2 — idempotent. Produces each input's partial signature once,
    /// caches it, and zeroes the nonces. A second call returns the cached
    /// partials without touching the (now destroyed) nonces.
    ///
    /// - Parameter commitmentsByInputByIndex: for each input position, the
    ///   map of signer index → that signer's commitment for this input.
    public func sign(commitmentsByInputByIndex: [[UInt16: String]]) throws -> [String] {
        if let cached = partialsPerInput { return cached }
        guard let nonces, phase == .committed else {
            throw WalletKitError.internalError("must commit before signing")
        }
        guard commitmentsByInputByIndex.count == sighashes.count else {
            throw WalletKitError.internalError("commitment set does not match inputs")
        }
        var partials: [String] = []
        for (i, sighash) in sighashes.enumerated() {
            let partial = try signPartial(
                keyPackage: keyPackage,
                nonces: nonces[i],
                messageHex: sighash,
                commitmentsByIndex: commitmentsByInputByIndex[i]
            )
            partials.append(partial)
        }
        self.partialsPerInput = partials
        self.nonces = nil          // burn the nonces — cannot sign again
        self.phase = .signed
        return partials
    }
}

/// Coordinator-side aggregation (runs on whichever member's app finalizes
/// the spend). Combines the collected commitments and partial signatures
/// into one 64-byte BIP340 signature per input.
public enum FrostAggregator {
    public static func aggregate(
        publicKeyPackage: String,
        sighashes: [String],
        commitmentsByInputByIndex: [[UInt16: String]],
        partialsByInputByIndex: [[UInt16: String]]
    ) throws -> [String] {
        precondition(
            sighashes.count == commitmentsByInputByIndex.count
                && sighashes.count == partialsByInputByIndex.count,
            "per-input arrays must align"
        )
        var signatures: [String] = []
        for i in sighashes.indices {
            let sig = try signAggregate(
                publicKeyPackage: publicKeyPackage,
                messageHex: sighashes[i],
                commitmentsByIndex: commitmentsByInputByIndex[i],
                sharesByIndex: partialsByInputByIndex[i]
            )
            signatures.append(sig)
        }
        return signatures
    }
}
