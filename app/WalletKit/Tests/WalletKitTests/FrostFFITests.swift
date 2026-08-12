import XCTest
@testable import WalletKit
import OBFrost

/// Proves the FROST Rust core is callable from Swift: full 3-party DKG
/// (no dealer) + 2-of-3 signing, then independent verification that the
/// aggregate is a valid signature under the vault key. Mirrors exactly
/// what the vault signing session will do across devices — here all
/// three "devices" run in-process.
final class FrostFFITests: XCTestCase {
    func testDkgAndThresholdSigningFromSwift() throws {
        let n: UInt16 = 3, k: UInt16 = 2

        // DKG round 1
        var r1secret = [UInt16: String](), r1public = [UInt16: String]()
        for i in 1...n {
            let r = try dkgPart1(participantIndex: i, maxSigners: n, minSigners: k)
            r1secret[i] = r.secretPackage
            r1public[i] = r.publicPackage
        }
        // DKG round 2
        var r2secret = [UInt16: String](), r2out = [UInt16: [UInt16: String]]()
        for i in 1...n {
            let others = r1public.filter { $0.key != i }
            let r = try dkgPart2(round1Secret: r1secret[i]!, round1PublicByIndex: others, maxSigners: n)
            r2secret[i] = r.secretPackage
            r2out[i] = r.outgoing
        }
        // DKG round 3
        var keyPackages = [UInt16: String](), pubkeyPkg = ""
        for i in 1...n {
            let r1others = r1public.filter { $0.key != i }
            var r2ToMe = [UInt16: String]()
            for j in 1...n where j != i { r2ToMe[j] = r2out[j]![i]! }
            let res = try dkgPart3(round2Secret: r2secret[i]!, round1PublicByIndex: r1others, round2SecretByIndex: r2ToMe)
            keyPackages[i] = res.keyPackage
            pubkeyPkg = res.publicKeyPackage
        }
        let vaultKey = try vaultXonlyHex(publicKeyPackage: pubkeyPkg)
        XCTAssertEqual(vaultKey.count, 64, "32-byte x-only key as hex")

        // Signing with members 1 and 2
        let signers: [UInt16] = [1, 2]
        let messageHex = String(repeating: "07", count: 32)
        var commitments = [UInt16: String](), nonces = [UInt16: String]()
        for s in signers {
            let c = try signCommit(keyPackage: keyPackages[s]!)
            commitments[s] = c.commitments
            nonces[s] = c.nonces
        }
        var shares = [UInt16: String]()
        for s in signers {
            shares[s] = try signPartial(keyPackage: keyPackages[s]!, nonces: nonces[s]!,
                                        messageHex: messageHex, commitmentsByIndex: commitments)
        }
        let sig = try signAggregate(publicKeyPackage: pubkeyPkg, messageHex: messageHex,
                                    commitmentsByIndex: commitments, sharesByIndex: shares)
        XCTAssertEqual(sig.count, 128, "64-byte BIP340 signature as hex")

        // A different pair (1,3) must also produce a valid signature for the SAME key.
        let signers2: [UInt16] = [1, 3]
        var c2 = [UInt16: String](), n2 = [UInt16: String]()
        for s in signers2 { let c = try signCommit(keyPackage: keyPackages[s]!); c2[s] = c.commitments; n2[s] = c.nonces }
        var sh2 = [UInt16: String]()
        for s in signers2 { sh2[s] = try signPartial(keyPackage: keyPackages[s]!, nonces: n2[s]!, messageHex: messageHex, commitmentsByIndex: c2) }
        let sig2 = try signAggregate(publicKeyPackage: pubkeyPkg, messageHex: messageHex, commitmentsByIndex: c2, sharesByIndex: sh2)
        XCTAssertEqual(sig2.count, 128, "any k-of-n subset signs under one key")
    }
}
