import Foundation
import XCTest

@testable import WalletKit

final class BackupCryptoTests: XCTestCase {
    private let secrets = WalletSecrets(
        mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        network: .signet,
        scriptType: .bip84,
        receiveIndexHint: 7,
        changeIndexHint: 2,
        // Whole seconds: ISO8601 coding drops sub-second precision.
        createdAt: Date(timeIntervalSince1970: 1_751_000_000)
    )

    func testSealOpenRoundTrip() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let envelope = try BackupCrypto.seal(secrets, inputKeyMaterial: key, keyProvider: "synced-keychain")

        XCTAssertEqual(envelope.cipher, BackupCrypto.cipherIdentifier)
        XCTAssertEqual(envelope.network, .signet)

        let restored = try BackupCrypto.open(envelope, inputKeyMaterial: key)
        XCTAssertEqual(restored, secrets)
    }

    func testWrongKeyFails() throws {
        let envelope = try BackupCrypto.seal(secrets, inputKeyMaterial: Data(repeating: 1, count: 32), keyProvider: "t")
        XCTAssertThrowsError(try BackupCrypto.open(envelope, inputKeyMaterial: Data(repeating: 2, count: 32)))
    }

    func testCiphertextDoesNotContainMnemonic() throws {
        let key = Data(repeating: 9, count: 32)
        let envelope = try BackupCrypto.seal(secrets, inputKeyMaterial: key, keyProvider: "t")
        let json = String(data: try JSONEncoder().encode(envelope), encoding: .utf8)!
        XCTAssertFalse(json.contains("abandon"))
    }

    func testEnvelopesAreNotLinkableAcrossRewrites() throws {
        let key = Data(repeating: 3, count: 32)
        let a = try BackupCrypto.seal(secrets, inputKeyMaterial: key, keyProvider: "t")
        let b = try BackupCrypto.seal(secrets, inputKeyMaterial: key, keyProvider: "t")
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.sealed, b.sealed)
    }
}

final class PaymentRequestTests: XCTestCase {
    func testBip21URI() {
        let request = PaymentRequest(
            address: "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
            amountSats: 150_000,
            label: "Satchel Request"
        )
        XCTAssertEqual(
            request.bip21URI,
            "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?amount=0.00150000&label=Satchel%20Request"
        )
    }

    func testQueryItemRoundTrip() {
        let request = PaymentRequest(
            address: "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx",
            amountSats: 21,
            label: "coffee",
            txid: String(repeating: "ab", count: 32)
        )
        let restored = PaymentRequest(queryItems: request.queryItems())
        XCTAssertEqual(restored, request)
    }

    func testBtcFormatting() {
        XCTAssertEqual(PaymentRequest.btcString(sats: 1), "0.00000001")
        XCTAssertEqual(PaymentRequest.btcString(sats: 100_000_000), "1.00000000")
        XCTAssertEqual(PaymentRequest.btcString(sats: 123_456_789), "1.23456789")
    }

    func testParseBip21URI() {
        let parsed = PaymentRequest.parse(
            "bitcoin:BC1QAR0SRRR7XFKVY5L643LYDNW9RE59GTZZWF5MDQ?amount=0.00021&label=Coffee%20Fund"
        )
        XCTAssertEqual(parsed?.address, "BC1QAR0SRRR7XFKVY5L643LYDNW9RE59GTZZWF5MDQ")
        XCTAssertEqual(parsed?.amountSats, 21_000)
        XCTAssertEqual(parsed?.label, "Coffee Fund")
    }

    func testParseSchemeCaseInsensitiveAndNoParams() {
        XCTAssertEqual(
            PaymentRequest.parse("BITCOIN:tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx")?.address,
            "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        )
        XCTAssertNil(PaymentRequest.parse("bitcoin:")?.address)
    }

    func testParseBareAddressAndGarbage() {
        XCTAssertEqual(
            PaymentRequest.parse("  tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx \n")?.address,
            "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
        )
        XCTAssertNil(PaymentRequest.parse("hello world"))
        XCTAssertNil(PaymentRequest.parse("short"))
        XCTAssertNil(PaymentRequest.parse(""))
    }

    func testParseWholeBtcAmount() {
        XCTAssertEqual(
            PaymentRequest.parse("bitcoin:tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx?amount=1")?.amountSats,
            100_000_000
        )
    }
}

final class AddressSafetyTests: XCTestCase {
    func testDetectsLookalike() {
        let paid = "tb1qedc4ejt884yjht23eqnr82s4e7yhrztac4j0vt"
        let poisoned = "tb1qedc4xxxxxxxxxxxxxxxxxxxxxxxxxxac4j0vt"
        XCTAssertEqual(AddressSafety.poisoningSuspect(candidate: poisoned, history: [paid]), paid)
    }

    func testIgnoresExactRepeatAndUnrelated() {
        let paid = "tb1qedc4ejt884yjht23eqnr82s4e7yhrztac4j0vt"
        XCTAssertNil(AddressSafety.poisoningSuspect(candidate: paid, history: [paid]))
        XCTAssertNil(AddressSafety.poisoningSuspect(
            candidate: "tb1q9ykhcups7uw84jkvztgemta5lcehuzdjw48dpq",
            history: [paid]
        ))
    }
}

final class SmartAmountTests: XCTestCase {
    func testSatsForms() {
        XCTAssertEqual(SmartAmount.parse("21000"), .sats(21_000))
        XCTAssertEqual(SmartAmount.parse("21,000 sats"), .sats(21_000))
        XCTAssertEqual(SmartAmount.parse("21k sats"), .sats(21_000))
        XCTAssertEqual(SmartAmount.parse("1.5m"), .sats(1_500_000))
    }

    func testBtcForms() {
        XCTAssertEqual(SmartAmount.parse("0.5 btc"), .sats(50_000_000))
        XCTAssertEqual(SmartAmount.parse("₿0.001"), .sats(100_000))
    }

    func testUsdForms() {
        XCTAssertEqual(SmartAmount.parse("$5"), .usd(5))
        XCTAssertEqual(SmartAmount.parse("5 bucks"), .usd(5))
        XCTAssertEqual(SmartAmount.parse("12.50 usd"), .usd(12.5))
    }

    func testGarbage() {
        XCTAssertNil(SmartAmount.parse(""))
        XCTAssertNil(SmartAmount.parse("banana"))
        XCTAssertNil(SmartAmount.parse("$-5"))
    }
}

final class ClaimVoucherTests: XCTestCase {
    func testGenerateParseRoundTripDerivesSameAddress() throws {
        let voucher = try ClaimVoucher.generate(network: .signet, amountSats: 5_000)
        XCTAssertTrue(voucher.address.hasPrefix("tb1q"))

        let parsed = ClaimVoucher(queryItems: voucher.queryItems())
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.address, voucher.address, "address must re-derive from the secret")
        XCTAssertEqual(parsed?.amountSats, 5_000)
        XCTAssertEqual(parsed?.network, .signet)
    }

    func testMinimumGiftEnforced() {
        XCTAssertThrowsError(try ClaimVoucher.generate(network: .signet, amountSats: 500))
    }

    func testRejectsMalformedSecrets() {
        let items = [
            URLQueryItem(name: "m", value: "not a real mnemonic"),
            URLQueryItem(name: "sats", value: "5000"),
            URLQueryItem(name: "net", value: "signet"),
        ]
        XCTAssertNil(ClaimVoucher(queryItems: items))
    }
}

final class BackupVersioningTests: XCTestCase {
    private func makeSecrets(hint: UInt32) -> WalletSecrets {
        WalletSecrets(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            network: .signet,
            scriptType: .bip84,
            receiveIndexHint: hint,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000)
        )
    }

    /// Corrupting the main envelope must fall back to the previous
    /// generation instead of losing the wallet. (Test env has no iCloud,
    /// so this exercises the local-fallback path end to end.)
    func testCorruptMainFallsBackToPreviousEnvelope() async throws {
        let store = ICloudBackupStore()
        let key = Data(repeating: 5, count: 32)

        let older = try BackupCrypto.seal(makeSecrets(hint: 1), inputKeyMaterial: key, keyProvider: "t")
        try store.save(older)
        let newer = try BackupCrypto.seal(makeSecrets(hint: 2), inputKeyMaterial: key, keyProvider: "t")
        try store.save(newer) // `older` becomes the .previous copy

        // Sanity: intact main loads the newer envelope.
        let loaded = try await store.load()
        XCTAssertEqual(loaded, newer)

        // Corrupt the main file in place.
        let mainURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WalletBackupLocal")
            .appendingPathComponent(ICloudBackupStore.fileName)
        try Data("not json".utf8).write(to: mainURL)

        let recovered = try await store.load()
        XCTAssertEqual(recovered, older)
        XCTAssertTrue(store.backupExists())
    }
}

final class BackupStoreTests: XCTestCase {
    /// In the test environment there is no ubiquity container, so this
    /// exercises the local-fallback path end to end.
    func testFallbackSaveLoadRoundTrip() async throws {
        let store = ICloudBackupStore()
        XCTAssertFalse(store.isUsingICloud)

        let secrets = WalletSecrets(
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            network: .signet,
            scriptType: .bip84,
            createdAt: Date(timeIntervalSince1970: 1_751_000_000)
        )
        let envelope = try BackupCrypto.seal(
            secrets,
            inputKeyMaterial: Data(repeating: 7, count: 32),
            keyProvider: "test"
        )
        try store.save(envelope)
        XCTAssertTrue(store.backupExists())

        let loaded = try await store.load()
        XCTAssertEqual(loaded, envelope)
    }
}

final class StatusProbeTests: XCTestCase {
    func testAddressActivityParsing() async throws {
        let json = """
        {"address":"tb1q","chain_stats":{"funded_txo_sum":21000,"spent_txo_sum":0,"funded_txo_count":2,"spent_txo_count":0,"tx_count":2},
         "mempool_stats":{"funded_txo_sum":500,"spent_txo_sum":0,"funded_txo_count":1,"spent_txo_count":0,"tx_count":1}}
        """
        let probe = StatusProbe(session: MockURLProtocol.session(returning: json))
        let activity = try await probe.addressActivity(
            address: "tb1q",
            esploraURL: URL(string: "https://esplora.test/api")!
        )
        XCTAssertEqual(activity.confirmedReceivedSats, 21000)
        XCTAssertEqual(activity.mempoolReceivedSats, 500)
        XCTAssertTrue(activity.hasAny)
    }

    func testTxConfirmationParsing() async throws {
        let json = #"{"confirmed":true,"block_height":900,"block_hash":"x","block_time":1751000000}"#
        let probe = StatusProbe(session: MockURLProtocol.session(returning: json))
        let tx = try await probe.txConfirmation(
            txid: String(repeating: "ab", count: 32),
            esploraURL: URL(string: "https://esplora.test/api")!
        )
        XCTAssertTrue(tx.confirmed)
        XCTAssertEqual(tx.blockTime, Date(timeIntervalSince1970: 1_751_000_000))
    }
}

final class PriceOracleTests: XCTestCase {
    func testUSDParsingAndFormatting() async {
        let json = #"{"time":1751000000,"USD":100000,"EUR":92000}"#
        let oracle = PriceOracle(session: MockURLProtocol.session(returning: json))
        let price = await oracle.usdPerBTC()
        XCTAssertEqual(price, 100000)

        XCTAssertEqual(PriceOracle.usdString(sats: 100_000_000, usdPerBTC: 100_000), "$100,000.00")
        XCTAssertEqual(PriceOracle.usdString(sats: 1_000, usdPerBTC: 100_000), "$1.00")
    }

    func testReturnsNilOnFailure() async {
        let oracle = PriceOracle(session: MockURLProtocol.session(returning: "oops", status: 500))
        let price = await oracle.usdPerBTC()
        XCTAssertNil(price)
    }
}

/// Serves a canned response to any request on a private session.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var body = ""
    nonisolated(unsafe) static var status = 200

    static func session(returning body: String, status: Int = 200) -> URLSession {
        Self.body = body
        Self.status = status
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WalletEngineTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("walletkit-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func testGenerateProducesTwelveWords() {
        let secrets = WalletEngine.generateSecrets(network: .signet)
        XCTAssertEqual(secrets.mnemonic.split(separator: " ").count, 12)
        XCTAssertEqual(secrets.scriptType, .bip84)
    }

    func testDeterministicRestoreYieldsSameAddresses() throws {
        let secrets = WalletEngine.generateSecrets(network: .signet)

        let engineA = try WalletEngine(secrets: secrets, storageDirectory: tempDir())
        let a0 = try engineA.nextReceiveAddress()
        let a1 = try engineA.nextReceiveAddress()

        let engineB = try WalletEngine(secrets: secrets, storageDirectory: tempDir())
        let b0 = try engineB.nextReceiveAddress()
        let b1 = try engineB.nextReceiveAddress()

        XCTAssertEqual(a0.address, b0.address)
        XCTAssertEqual(a1.address, b1.address)
        XCTAssertEqual(a0.index, 0)
        XCTAssertEqual(a1.index, 1)
        XCTAssertTrue(a0.address.hasPrefix("tb1q"), "BIP84 signet addresses are bech32 tb1q…")
    }

    func testRestoreHintRevealsAddressesUpfront() throws {
        var secrets = WalletEngine.generateSecrets(network: .signet)
        secrets.receiveIndexHint = 5

        let engine = try WalletEngine(secrets: secrets, storageDirectory: tempDir())
        XCTAssertEqual(engine.revealedIndexes().receive, 5)
        XCTAssertEqual(try engine.nextReceiveAddress().index, 6)
    }

    func testAddressValidation() throws {
        let engine = try WalletEngine(
            secrets: WalletEngine.generateSecrets(network: .bitcoin),
            storageDirectory: tempDir()
        )
        XCTAssertTrue(engine.validateAddress("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"))
        XCTAssertFalse(engine.validateAddress("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"), "wrong network")
        XCTAssertFalse(engine.validateAddress("not-an-address"))
    }

    func testBip86ProducesTaprootAddresses() throws {
        let secrets = WalletSecrets(
            mnemonic: WalletEngine.generateSecrets(network: .bitcoin).mnemonic,
            network: .bitcoin,
            scriptType: .bip86
        )
        let engine = try WalletEngine(secrets: secrets, storageDirectory: tempDir())
        XCTAssertTrue(try engine.nextReceiveAddress().address.hasPrefix("bc1p"))
    }
}
