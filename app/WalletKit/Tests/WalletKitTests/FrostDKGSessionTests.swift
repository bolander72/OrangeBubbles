import XCTest
@testable import WalletKit

/// Runs the full 3-round DKG across three FrostDKGSession instances —
/// exactly as three devices would, passing Codable messages between them.
/// Proves they converge on ONE vault key and that a JSON round-trip
/// (persistence across app kills) doesn't break the ceremony.
final class FrostDKGSessionTests: XCTestCase {
    func test3PartyDKGConverges() throws {
        let n: UInt16 = 3, k: UInt16 = 2
        let mnemonics = (0..<3).map { _ in try! WalletEngine.generateSecrets(network: .signet).mnemonic }
        let ids = try (1...n).map { try FrostMemberIdentity(index: $0, mnemonic: mnemonics[Int($0)-1]) }
        var sessions = try ids.map { try FrostDKGSession(vaultID: "v1", identity: $0, memberCount: n, threshold: k) }

        // Round 1: everyone broadcasts; collect the round-2 messages produced.
        let r1msgs = sessions.map { $0.round1Message() }
        var r2msgs: [FrostDKGSession.Round2Message] = []
        for i in 0..<3 {
            for j in 0..<3 where j != i {
                if let r2 = try sessions[i].receiveRound1(r1msgs[j], identity: ids[i]) {
                    r2msgs.append(r2)
                }
            }
        }
        XCTAssertEqual(r2msgs.count, 3, "each member emits one round-2 message once it has all round-1")

        // Persistence check: serialize/deserialize mid-ceremony.
        let data = try JSONEncoder().encode(sessions[0])
        sessions[0] = try JSONDecoder().decode(FrostDKGSession.self, from: data)

        // Round 2: deliver every round-2 message to every other member.
        for i in 0..<3 {
            for r2 in r2msgs where r2.fromIndex != ids[i].index {
                _ = try sessions[i].receiveRound2(r2, identity: ids[i])
            }
        }

        // All complete, all agree on the vault key.
        let keys = sessions.map { $0.vaultXonlyHex }
        XCTAssertTrue(keys.allSatisfy { $0 != nil }, "every member finished DKG")
        XCTAssertEqual(Set(keys.map { $0! }).count, 1, "all members derived the SAME vault key")
        XCTAssertEqual(keys[0]!.count, 64)

        // Each member holds a distinct private key package (their share).
        let pkgs = sessions.compactMap { $0.keyPackage }
        XCTAssertEqual(Set(pkgs).count, 3, "each member has a unique key share")
    }

    func testSealedSharesAreRecipientOnly() throws {
        let mA = try WalletEngine.generateSecrets(network: .signet).mnemonic
        let mB = try WalletEngine.generateSecrets(network: .signet).mnemonic
        let mC = try WalletEngine.generateSecrets(network: .signet).mnemonic
        let a = try FrostMemberIdentity(index: 1, mnemonic: mA)
        let b = try FrostMemberIdentity(index: 2, mnemonic: mB)
        let c = try FrostMemberIdentity(index: 3, mnemonic: mC)

        let secret = "top-secret-share"
        let sealed = try PairwiseSeal.seal(secret, from: a, toPublicKeyBase64: b.agreementPublicKeyBase64)
        // B (intended) opens it.
        XCTAssertEqual(try PairwiseSeal.open(sealed, recipient: b, fromPublicKeyBase64: a.agreementPublicKeyBase64), secret)
        // C (eavesdropper in the group chat) cannot.
        XCTAssertThrowsError(try PairwiseSeal.open(sealed, recipient: c, fromPublicKeyBase64: a.agreementPublicKeyBase64))
    }
}
