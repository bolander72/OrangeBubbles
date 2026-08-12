import XCTest
@testable import WalletKit

/// Full 2-of-3 signing ceremony across FrostSigningSession instances, plus
/// the nonce-discipline guarantees that keep key shares safe.
final class FrostSigningSessionTests: XCTestCase {
    // Helper: run DKG in-process, return (keyPackages by index, pubkeyPkg).
    private func dkg(n: UInt16, k: UInt16) throws -> ([UInt16: String], String) {
        let mnemonics = (0..<Int(n)).map { _ in try! WalletEngine.generateSecrets(network: .signet).mnemonic }
        let ids = try (1...n).map { try FrostMemberIdentity(index: $0, mnemonic: mnemonics[Int($0)-1]) }
        let sessions = try ids.map { try FrostDKGSession(vaultID: "v", identity: $0, memberCount: n, threshold: k) }
        let r1 = sessions.map { $0.round1Message() }
        var r2: [FrostDKGSession.Round2Message] = []
        for i in 0..<Int(n) { for j in 0..<Int(n) where j != i {
            if let m = try sessions[i].receiveRound1(r1[j], identity: ids[i]) { r2.append(m) }
        } }
        for i in 0..<Int(n) { for m in r2 where m.fromIndex != ids[i].index {
            _ = try sessions[i].receiveRound2(m, identity: ids[i])
        } }
        var kps: [UInt16: String] = [:]
        for (i, s) in sessions.enumerated() { kps[UInt16(i+1)] = s.keyPackage! }
        return (kps, sessions[0].publicKeyPackage!)
    }

    func testTwoOfThreeSigningProducesValidSignatures() throws {
        let (kps, pub) = try dkg(n: 3, k: 2)
        let sighashes = [String(repeating: "0a", count: 32), String(repeating: "0b", count: 32)] // 2 inputs
        let signers: [UInt16] = [1, 3]

        let sessions = signers.map {
            FrostSigningSession(vaultID: "v", proposalID: "p1", selfIndex: $0, keyPackage: kps[$0]!, sighashes: sighashes)
        }
        // Round 1: collect commitments per input.
        var commitmentsByInput: [[UInt16: String]] = Array(repeating: [:], count: sighashes.count)
        for (s, session) in zip(signers, sessions) {
            let c = try session.commitments()
            for i in sighashes.indices { commitmentsByInput[i][s] = c[i] }
        }
        // Round 2: partials per input.
        var partialsByInput: [[UInt16: String]] = Array(repeating: [:], count: sighashes.count)
        for (s, session) in zip(signers, sessions) {
            let p = try session.sign(commitmentsByInputByIndex: commitmentsByInput)
            for i in sighashes.indices { partialsByInput[i][s] = p[i] }
        }
        let sigs = try FrostAggregator.aggregate(
            publicKeyPackage: pub, sighashes: sighashes,
            commitmentsByInputByIndex: commitmentsByInput, partialsByInputByIndex: partialsByInput)
        XCTAssertEqual(sigs.count, 2)
        XCTAssertTrue(sigs.allSatisfy { $0.count == 128 }, "64-byte BIP340 sigs")
    }

    func testCommitIsIdempotent_neverFreshNonces() throws {
        let (kps, _) = try dkg(n: 2, k: 2)
        let session = FrostSigningSession(vaultID: "v", proposalID: "p", selfIndex: 1,
                                          keyPackage: kps[1]!, sighashes: [String(repeating: "01", count: 32)])
        let first = try session.commitments()
        let second = try session.commitments()
        XCTAssertEqual(first, second, "re-committing must return identical commitments (same nonces), never fresh ones")
    }

    func testSignIsIdempotent_cachedPartialsNotResigned() throws {
        let (kps, _) = try dkg(n: 2, k: 2)
        let sighashes = [String(repeating: "02", count: 32)]
        let sessions = [1, 2].map { UInt16($0) }.map {
            FrostSigningSession(vaultID: "v", proposalID: "p", selfIndex: $0, keyPackage: kps[$0]!, sighashes: sighashes)
        }
        var byInput: [[UInt16: String]] = [[:]]
        for (idx, s) in zip([UInt16(1), 2], sessions) { byInput[0][idx] = try s.commitments()[0] }
        let p1 = try sessions[0].sign(commitmentsByInputByIndex: byInput)
        let p2 = try sessions[0].sign(commitmentsByInputByIndex: byInput)
        XCTAssertEqual(p1, p2, "re-signing must return the CACHED partial, never a second signature over the same nonce")
        XCTAssertEqual(sessions[0].phase, .signed)
    }
}
