import BitcoinDevKit
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
            label: "OrangeBubbles Request"
        )
        XCTAssertEqual(
            request.bip21URI,
            "bitcoin:bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq?amount=0.00150000&label=OrangeBubbles%20Request"
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

final class SeedEntropyTests: XCTestCase {
    /// The canonical BIP39 vector: 16 zero bytes must yield the known
    /// mnemonic. Proves the entropy → words encoding path is faithful.
    func testKnownBip39VectorEncodesCorrectly() throws {
        let mnemonic = try Mnemonic.fromEntropy(entropy: [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(
            mnemonic.description,
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        )
    }

    func testGenerateLengthAndUniqueness() throws {
        let a = try SeedEntropy.generate(byteCount: 32)
        let b = try SeedEntropy.generate(byteCount: 32)
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(b.count, 32)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, Data(count: 32), "must never be all zeros")

        let c = try SeedEntropy.generate(byteCount: 16)
        XCTAssertEqual(c.count, 16)
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

    func testGenerateProducesTwentyFourWords() throws {
        let secrets = try WalletEngine.generateSecrets(network: .signet)
        XCTAssertEqual(secrets.mnemonic.split(separator: " ").count, 24, "main wallets are 256-bit")
        XCTAssertEqual(secrets.scriptType, .bip84)
    }

    func testGiftStrengthProducesTwelveWords() throws {
        let secrets = try WalletEngine.generateSecrets(network: .signet, strength: .standard)
        XCTAssertEqual(secrets.mnemonic.split(separator: " ").count, 12)
    }

    func testDeterministicRestoreYieldsSameAddresses() throws {
        let secrets = try WalletEngine.generateSecrets(network: .signet)

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
        var secrets = try WalletEngine.generateSecrets(network: .signet)
        secrets.receiveIndexHint = 5

        let engine = try WalletEngine(secrets: secrets, storageDirectory: tempDir())
        XCTAssertEqual(engine.revealedIndexes().receive, 5)
        XCTAssertEqual(try engine.nextReceiveAddress().index, 6)
    }

    /// Regression: this used to reveal three fresh addresses on every call,
    /// so the watched set (and the request cost of every sync) grew without
    /// bound. Repeated calls must return the same addresses.
    func testUpcomingAddressesAreIdempotent() throws {
        let secrets = try WalletEngine.generateSecrets(network: .signet)
        let engine = try WalletEngine(secrets: secrets, storageDirectory: tempDir())

        let first = try engine.revealUpcomingReceiveAddresses(count: 3)
        let watchedAfterFirst = engine.watchedScriptPubkeyCount
        for _ in 0..<10 {
            XCTAssertEqual(try engine.revealUpcomingReceiveAddresses(count: 3), first)
        }
        XCTAssertEqual(engine.watchedScriptPubkeyCount, watchedAfterFirst)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(Set(first).count, 3, "three distinct addresses")

        // An address shown in Receive is handed out: it is never offered
        // again, so it stays out of the reserved list.
        let shown = try engine.nextReceiveAddress().address
        XCTAssertFalse(try engine.revealUpcomingReceiveAddresses(count: 3).contains(shown))
        XCTAssertEqual(engine.unusedReceiveAddressCount, 3)
    }

    /// A restore hint far beyond anything this cache has seen is the old
    /// runaway reveal, not hundreds of handed-out addresses: it is capped so
    /// a restore does not start life with a 350-request sync.
    func testRestoreHintIsCapped() throws {
        var secrets = try WalletEngine.generateSecrets(network: .signet)
        secrets.receiveIndexHint = 350
        secrets.changeIndexHint = 200

        let engine = try WalletEngine(secrets: secrets, storageDirectory: tempDir())
        XCTAssertEqual(engine.revealedIndexes().receive, 30)
        XCTAssertEqual(engine.revealedIndexes().change, 30)
    }

    func testAddressValidation() throws {
        let engine = try WalletEngine(
            secrets: try WalletEngine.generateSecrets(network: .bitcoin),
            storageDirectory: tempDir()
        )
        XCTAssertTrue(engine.validateAddress("bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq"))
        XCTAssertFalse(engine.validateAddress("tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"), "wrong network")
        XCTAssertFalse(engine.validateAddress("not-an-address"))
    }

    func testBip86ProducesTaprootAddresses() throws {
        let secrets = WalletSecrets(
            mnemonic: try WalletEngine.generateSecrets(network: .bitcoin).mnemonic,
            network: .bitcoin,
            scriptType: .bip86
        )
        let engine = try WalletEngine(secrets: secrets, storageDirectory: tempDir())
        XCTAssertTrue(try engine.nextReceiveAddress().address.hasPrefix("bc1p"))
    }
}

/// No address is ever handed out twice: once shown (Receive) or issued
/// (Siri), it leaves every list that could offer it again.
final class AddressReuseTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("walletkit-reuse-\(UUID().uuidString)", isDirectory: true)
    }

    func testReceiveSheetAddressesNeverRepeatAndLeaveTheReservedList() throws {
        let engine = try WalletEngine(secrets: try WalletEngine.generateSecrets(network: .signet), storageDirectory: tempDir())
        let reserved = try engine.revealUpcomingReceiveAddresses(count: 3)

        // Receive and Siri drain the same ordered queue: Receive takes the
        // reserved addresses first (nothing is wasted), then reveals more.
        var shown: [String] = []
        for _ in 0..<5 { shown.append(try engine.nextReceiveAddress().address) }
        XCTAssertEqual(Set(shown).count, 5, "every Receive open gets a new address")
        XCTAssertEqual(Array(shown.prefix(3)), reserved)

        let reservedAfter = try engine.revealUpcomingReceiveAddresses(count: 3)
        XCTAssertEqual(reservedAfter.count, 3)
        XCTAssertTrue(Set(reservedAfter).isDisjoint(with: shown), "a shown address is never offered to Siri")
        XCTAssertEqual(engine.handedOutReceiveIndex, 4)
    }

    func testExcludedAddressesAreSkippedButStillCountAsHandedOut() throws {
        let engine = try WalletEngine(secrets: try WalletEngine.generateSecrets(network: .signet), storageDirectory: tempDir())
        let reserved = try engine.revealUpcomingReceiveAddresses(count: 3)
        // Siri issued the first reserved address; the extension hasn't
        // reconciled yet. Receive must step over it.
        let next = try engine.nextReceiveAddress(excluding: [reserved[0]])
        XCTAssertEqual(next.address, reserved[1])
        XCTAssertFalse(try engine.revealUpcomingReceiveAddresses(count: 3).contains(reserved[0]),
                       "the stepped-over address sits below the high-water mark and is gone for good")
    }

    func testHandedOutMarkSurvivesRelaunchAndRestore() throws {
        var secrets = try WalletEngine.generateSecrets(network: .signet)
        let dir = tempDir()
        let shown: String
        let reserved: [String]
        do {
            let engine = try WalletEngine(secrets: secrets, storageDirectory: dir)
            shown = try engine.nextReceiveAddress().address
            reserved = try engine.revealUpcomingReceiveAddresses(count: 3)
            try engine.markReceiveAddressHandedOut(reserved[0])
            // What the store persists on every hand-out.
            secrets.receiveIndexHint = engine.revealedIndexes().receive
            secrets.handedOutReceiveIndex = engine.handedOutReceiveIndex
        }
        // Relaunch: same cache. BDK forgets its in-memory "used" flags.
        let relaunched = try WalletEngine(secrets: secrets, storageDirectory: dir)
        let afterRelaunch = try relaunched.revealUpcomingReceiveAddresses(count: 3)
        XCTAssertFalse(afterRelaunch.contains(shown))
        XCTAssertFalse(afterRelaunch.contains(reserved[0]))
        XCTAssertEqual(Array(afterRelaunch.prefix(2)), Array(reserved[1...2]))

        // Restore on a new device: fresh cache, hints from the backup.
        let restored = try WalletEngine(secrets: secrets, storageDirectory: tempDir())
        let afterRestore = try restored.revealUpcomingReceiveAddresses(count: 3)
        XCTAssertFalse(afterRestore.contains(shown))
        XCTAssertFalse(afterRestore.contains(reserved[0]))
        XCTAssertEqual(afterRestore, afterRelaunch)
    }

    func testIssuedAddressIsReplacedNotRepeated() throws {
        let engine = try WalletEngine(secrets: try WalletEngine.generateSecrets(network: .signet), storageDirectory: tempDir())
        let reserved = try engine.revealUpcomingReceiveAddresses(count: 3)
        let issued = reserved[0]

        XCTAssertTrue(try engine.markReceiveAddressHandedOut(issued))
        let next = try engine.revealUpcomingReceiveAddresses(count: 3)
        XCTAssertFalse(next.contains(issued))
        XCTAssertEqual(next.count, 3)
        XCTAssertEqual(Set(next).intersection(reserved).count, 2, "the two untouched reservations stay; one fresh address joins")

        let mark = engine.handedOutReceiveIndex
        XCTAssertTrue(try engine.markReceiveAddressHandedOut(issued), "idempotent")
        XCTAssertEqual(engine.handedOutReceiveIndex, mark, "re-marking changes nothing")
        XCTAssertFalse(try engine.markReceiveAddressHandedOut("tb1qn3q8pvyhesvl4zrzuzcvwlykr7hqeju30yckpm"), "not ours")
    }

    func testHandedOutAddressesStayWatched() throws {
        let engine = try WalletEngine(secrets: try WalletEngine.generateSecrets(network: .signet), storageDirectory: tempDir())
        let before = engine.watchedScriptPubkeyCount
        _ = try engine.nextReceiveAddress()
        _ = try engine.revealUpcomingReceiveAddresses(count: 3)
        try engine.markReceiveAddressHandedOut(try engine.revealUpcomingReceiveAddresses(count: 3)[0])
        // Handing out marks used but never un-reveals: the watched set only grows.
        XCTAssertGreaterThan(engine.watchedScriptPubkeyCount, before)
    }
}

/// A pending payment the mempool has dropped must leave history and the
/// pending balance; a confirmed one can't be evicted.
final class EvictionTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("walletkit-evict-\(UUID().uuidString)", isDirectory: true)
    }

    /// A minimal serialized transaction paying `sats` to `address`.
    private func fakeIncomingTx(to address: String, sats: UInt64) throws -> Transaction {
        let spk = try Address(address: address, network: .signet).scriptPubkey().toBytes()
        var raw: [UInt8] = [0x02, 0, 0, 0]              // version 2
        raw += [0x01]                                  // 1 input
        raw += [UInt8](repeating: 0xab, count: 32)     // prev txid (fake)
        raw += [0, 0, 0, 0]                            // vout
        raw += [0x00]                                  // empty scriptSig
        raw += [0xff, 0xff, 0xff, 0xff]                // sequence
        raw += [0x01]                                  // 1 output
        raw += withUnsafeBytes(of: sats.littleEndian) { Array($0) }
        raw += [UInt8(spk.count)] + spk
        raw += [0, 0, 0, 0]                            // locktime
        return try Transaction(transactionBytes: raw)
    }

    func testEvictedIncomingLeavesHistoryAndPendingBalance() throws {
        let dir = tempDir()
        let secrets = try WalletEngine.generateSecrets(network: .signet)
        let engine = try WalletEngine(secrets: secrets, storageDirectory: dir)
        let address = try engine.nextReceiveAddress().address
        let tx = try fakeIncomingTx(to: address, sats: 50_000)
        try engine.applyUnconfirmed(tx)
        let txid = tx.computeTxid().description

        XCTAssertEqual(engine.balance().pendingSats, 50_000)
        XCTAssertEqual(engine.transactions().map(\.txid), [txid])

        engine.evict(txid: txid)
        XCTAssertTrue(engine.isEvicted(txid: txid))
        XCTAssertEqual(engine.balance().pendingSats, 0)
        XCTAssertTrue(engine.transactions().isEmpty)

        // Eviction survives a relaunch of the same cache …
        let again = try WalletEngine(secrets: secrets, storageDirectory: dir)
        XCTAssertTrue(again.isEvicted(txid: txid))
        XCTAssertEqual(again.balance().pendingSats, 0)
        // … and is forgotten with the cache (a rebuild only knows the chain).
        let rebuilt = try WalletEngine(secrets: secrets, storageDirectory: dir, cacheDiscriminator: "g2")
        XCTAssertFalse(rebuilt.isEvicted(txid: txid))
    }
}


final class CustomEndpointTests: XCTestCase {
    func testCustomEndpointGoesFirstAndDropsThirdPartyFees() {
        let node = URL(string: "https://node.example/api")!
        let custom = ChainConfig.mainnet.withCustomEsplora(node)
        XCTAssertEqual(custom.esploraURL, node)
        XCTAssertEqual(custom.esploraURLs.count, ChainConfig.mainnet.esploraURLs.count + 1)
        XCTAssertNil(custom.feesURL, "fee estimates come from the node; no third party")
        XCTAssertEqual(custom.network, .bitcoin)
        // Idempotent: setting the same node twice doesn't duplicate it.
        XCTAssertEqual(custom.withCustomEsplora(node).esploraURLs, custom.esploraURLs)
    }

    func testEndpointNormalisation() {
        XCTAssertEqual(EsploraEndpointCheck.normalize("node.example/api/")?.absoluteString, "https://node.example/api")
        XCTAssertEqual(EsploraEndpointCheck.normalize(" http://umbrel.local:3006/api ")?.absoluteString, "http://umbrel.local:3006/api")
        XCTAssertNil(EsploraEndpointCheck.normalize(""))
        XCTAssertNil(EsploraEndpointCheck.normalize("ftp://node.example"))
        XCTAssertNil(EsploraEndpointCheck.normalize("not a url"))
    }

    func testGenesisHashesPerNetwork() {
        XCTAssertEqual(ChainConfig.mainnet.genesisHash.prefix(10), "0000000000")
        XCTAssertEqual(ChainConfig.signet.genesisHash, "00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6")
        XCTAssertNotEqual(ChainConfig.mainnet.genesisHash, ChainConfig.signet.genesisHash)
    }
}
