import XCTest
@testable import WalletKit
import OBFrost

/// Exercises the full offline path: DKG -> vault address -> build a spend
/// over synthetic UTXOs -> 2-of-3 sign the sighashes -> finalize into a
/// broadcast-ready raw tx. No network: proves the assembly end to end.
final class FrostVaultEngineTests: XCTestCase {
    func testVaultAddressAndFinalizedSpendAssembles() throws {
        // DKG (in-process, three members).
        let n: UInt16 = 3, k: UInt16 = 2
        let mnemonics = (0..<3).map { _ in try! WalletEngine.generateSecrets(network: .signet).mnemonic }
        let ids = try (1...n).map { try FrostMemberIdentity(index: $0, mnemonic: mnemonics[Int($0)-1]) }
        let ds = try ids.map { try FrostDKGSession(vaultID: "v", identity: $0, memberCount: n, threshold: k) }
        let r1 = ds.map { $0.round1Message() }
        var r2: [FrostDKGSession.Round2Message] = []
        for i in 0..<3 { for j in 0..<3 where j != i { if let m = try ds[i].receiveRound1(r1[j], identity: ids[i]) { r2.append(m) } } }
        for i in 0..<3 { for m in r2 where m.fromIndex != ids[i].index { _ = try ds[i].receiveRound2(m, identity: ids[i]) } }
        let vaultKey = ds[0].vaultXonlyHex!
        let pub = ds[0].publicKeyPackage!
        let kps: [UInt16: String] = [1: ds[0].keyPackage!, 2: ds[1].keyPackage!, 3: ds[2].keyPackage!]

        // Vault address is a real signet p2tr.
        let engine = FrostVaultEngine(vaultXonlyHex: vaultKey, network: .signet)
        let addr = try engine.address()
        XCTAssertTrue(addr.hasPrefix("tb1p"), "FROST vault is a Taproot address")

        // Build a spend over a synthetic UTXO via the FFI directly.
        let dest = "tb1qz2f38n9fzqr3xp34a7vya5rzgr5sy2227yq4mz"
        let plan = try frostBuildSpend(
            xonlyHex: vaultKey,
            utxos: [FrostUtxo(txid: String(repeating: "ab", count: 32), vout: 0, valueSats: 10_000)],
            destAddress: dest, amountSats: 0, feeSats: 300, network: "signet")
        XCTAssertEqual(plan.sighashesHex.count, 1)

        // 2-of-3 sign the sighash(es).
        let signers: [UInt16] = [1, 2]
        let sessions = signers.map {
            FrostSigningSession(vaultID: "v", proposalID: "p", selfIndex: $0, keyPackage: kps[$0]!, sighashes: plan.sighashesHex)
        }
        var commByInput: [[UInt16: String]] = Array(repeating: [:], count: plan.sighashesHex.count)
        for (s, sess) in zip(signers, sessions) { let c = try sess.commitments(); for i in plan.sighashesHex.indices { commByInput[i][s] = c[i] } }
        var partByInput: [[UInt16: String]] = Array(repeating: [:], count: plan.sighashesHex.count)
        for (s, sess) in zip(signers, sessions) { let p = try sess.sign(commitmentsByInputByIndex: commByInput); for i in plan.sighashesHex.indices { partByInput[i][s] = p[i] } }
        let sigs = try FrostAggregator.aggregate(publicKeyPackage: pub, sighashes: plan.sighashesHex, commitmentsByInputByIndex: commByInput, partialsByInputByIndex: partByInput)

        // Finalize into a broadcast-ready raw tx.
        let signedHex = try frostFinalizeSpend(unsignedTxHex: plan.unsignedTxHex, signaturesHex: sigs)
        XCTAssertTrue(signedHex.count > plan.unsignedTxHex.count, "witness added")
        XCTAssertTrue(signedHex.hasPrefix("020000000001"), "segwit-serialized signed tx")
    }
}
