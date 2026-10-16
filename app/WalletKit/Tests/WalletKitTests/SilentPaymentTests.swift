import Foundation
import XCTest

@testable import WalletKit

/// Runs the sending half of the official BIP352 test vectors
/// (bip-0352/send_and_receive_test_vectors.json) through our implementation.
final class SilentPaymentTests: XCTestCase {
    private struct Vector: Decodable {
        struct Sending: Decodable {
            struct Given: Decodable {
                struct Vin: Decodable {
                    struct Prevout: Decodable {
                        struct SPK: Decodable { let hex: String }
                        let scriptPubKey: SPK
                    }
                    let txid: String
                    let vout: UInt32
                    let scriptSig: String
                    let txinwitness: String
                    let prevout: Prevout
                    let private_key: String
                }
                struct Recipient: Decodable {
                    let address: String
                    let scan_pub_key: String
                    let spend_pub_key: String
                    /// Some vectors pay the same address many times.
                    let count: Int?
                }
                let vin: [Vin]
                let recipients: [Recipient]
            }
            struct Expected: Decodable {
                let outputs: [[String]]
                let shared_secrets: [String?]?
                let input_private_key_sum: String?
            }
            let given: Given
            let expected: Expected
        }
        let comment: String
        let sending: [Sending]
    }

    private func loadVectors() throws -> [Vector] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "bip352_send_and_receive_test_vectors", withExtension: "json", subdirectory: "Resources"
        ) ?? Bundle.module.url(forResource: "bip352_send_and_receive_test_vectors", withExtension: "json"))
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }

    /// Witness as serialised in the vectors: varint count, then varint-length items.
    private func parseWitness(_ hex: String) -> [[UInt8]] {
        let bytes = Hex.bytes(hex)
        guard !bytes.isEmpty else { return [] }
        var i = 0
        func readVarint() -> Int {
            let b = Int(bytes[i]); i += 1
            if b < 0xfd { return b }
            if b == 0xfd { let v = Int(bytes[i]) | Int(bytes[i+1]) << 8; i += 2; return v }
            fatalError("witness too large for test vectors")
        }
        let count = readVarint()
        var items: [[UInt8]] = []
        for _ in 0..<count {
            let len = readVarint()
            items.append(Array(bytes[i..<(i + len)]))
            i += len
        }
        return items
    }

    func testAddressRoundTrip() throws {
        for vector in try loadVectors() {
            for recipient in vector.sending[0].given.recipients {
                let parsed = try XCTUnwrap(SilentPaymentAddress(string: recipient.address), vector.comment)
                XCTAssertEqual(Hex.string(parsed.scanKey), recipient.scan_pub_key, vector.comment)
                XCTAssertEqual(Hex.string(parsed.spendKey), recipient.spend_pub_key, vector.comment)
                XCTAssertEqual(parsed.string, recipient.address, vector.comment)
                XCTAssertTrue(parsed.isMainnet)
            }
        }
        XCTAssertNil(SilentPaymentAddress(string: "tb1qn3q8pvyhesvl4zrzuzcvwlykr7hqeju30yckpm"))
        XCTAssertNil(SilentPaymentAddress(string: "sp1qqnotanaddress"))
        // A testnet address built from the first vector's keys.
        let v = try loadVectors()[0].sending[0].given.recipients[0]
        let tsp = try XCTUnwrap(SilentPaymentAddress(
            scanKey: Hex.bytes(v.scan_pub_key), spendKey: Hex.bytes(v.spend_pub_key), hrp: "tsp"))
        XCTAssertTrue(tsp.string.hasPrefix("tsp1q"))
        XCTAssertEqual(SilentPaymentAddress(string: tsp.string), tsp)
        XCTAssertTrue(tsp.matches(network: .signet))
        XCTAssertFalse(tsp.matches(network: .bitcoin))
    }

    func testSendingVectors() throws {
        var ran = 0
        for vector in try loadVectors() {
            let sending = vector.sending[0]
            let inputs: [SilentPaymentInput] = sending.given.vin.compactMap { vin in
                let spk = Hex.bytes(vin.prevout.scriptPubKey.hex)
                let classified = SilentPaymentSender.classify(
                    prevoutScriptPubkey: spk,
                    scriptSig: Hex.bytes(vin.scriptSig),
                    witness: parseWitness(vin.txinwitness)
                )
                guard classified.eligible else { return nil }
                return SilentPaymentInput(
                    txidHex: vin.txid, vout: vin.vout,
                    privateKey: Hex.bytes(vin.private_key), isTaproot: classified.isTaproot
                )
            }
            let recipients = try sending.given.recipients.flatMap { r -> [SilentPaymentAddress] in
                let address = try XCTUnwrap(SilentPaymentAddress(string: r.address))
                return Array(repeating: address, count: r.count ?? 1)
            }
            let allOutpoints = sending.given.vin.map {
                SilentPaymentInput(txidHex: $0.txid, vout: $0.vout, privateKey: [UInt8](repeating: 1, count: 32), isTaproot: false).outpoint
            }
            let expectedOutputs = sending.expected.outputs

            if inputs.isEmpty {
                XCTAssertTrue(expectedOutputs.isEmpty || expectedOutputs == [[]], vector.comment)
                XCTAssertThrowsError(try SilentPaymentSender.outputs(inputs: inputs, recipients: recipients, transactionOutpoints: allOutpoints), vector.comment)
                ran += 1
                continue
            }
            if vector.comment.contains("point at infinity") {
                XCTAssertThrowsError(try SilentPaymentSender.outputs(inputs: inputs, recipients: recipients, transactionOutpoints: allOutpoints), vector.comment) {
                    XCTAssertEqual($0 as? SilentPaymentError, .inputKeysSumToZero)
                }
                ran += 1
                continue
            }
            if vector.comment.contains("K_max") {
                XCTAssertThrowsError(try SilentPaymentSender.outputs(inputs: inputs, recipients: recipients, transactionOutpoints: allOutpoints), vector.comment) {
                    XCTAssertEqual($0 as? SilentPaymentError, .tooManyRecipientsForOneScanKey)
                }
                ran += 1
                continue
            }

            let outputs = try SilentPaymentSender.outputs(inputs: inputs, recipients: recipients, transactionOutpoints: allOutpoints)
            let produced = Set(outputs.map { Hex.string($0.xOnlyKey) })
            // The vectors list the acceptable output sets (any one of them may
            // be produced, depending on recipient ordering within a scan-key
            // group). Ours is deterministic in recipient order; the first
            // listed set corresponds to that order in every vector.
            let expectedSets = expectedOutputs.map(Set.init)
            XCTAssertTrue(expectedSets.contains(produced),
                          "\(vector.comment): produced \(produced.sorted()) not in \(expectedSets.map { $0.sorted() })")
            XCTAssertEqual(outputs.count, recipients.count, vector.comment)
            for output in outputs {
                XCTAssertEqual(output.scriptPubkey.count, 34)
                XCTAssertEqual(output.scriptPubkey.prefix(2), [0x51, 0x20])
            }
            ran += 1
        }
        XCTAssertEqual(ran, 28)
    }

    func testScalarArithmetic() {
        let one = Scalar(bytes: [UInt8](repeating: 0, count: 31) + [1])!
        let nMinusOne = Scalar(bytes: Hex.bytes("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364140"))!
        XCTAssertTrue(one.adding(nMinusOne).isZero)
        XCTAssertEqual(one.negated(), nMinusOne)
        XCTAssertEqual(nMinusOne.negated(), one)
        XCTAssertNil(Scalar(bytes: Hex.bytes("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")))
        XCTAssertEqual(Scalar.zero.negated(), Scalar.zero)
    }

    func testHash160MatchesKnownVector() {
        // hash160 of the compressed generator point.
        let g = Hex.bytes("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")
        XCTAssertEqual(Hex.string(Hash160.hash(g)), "751e76e8199196d454941c45d1b3a323f1433bd6")
    }
}
