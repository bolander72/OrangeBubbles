import BitcoinDevKit
import Foundation

/// Thin wrapper around a BitcoinDevKit descriptor wallet. All chain logic —
/// derivation, coin selection, PSBT construction, signing — is BDK's; this
/// type just adapts it to `WalletSecrets` and app-friendly value types.
///
/// BDK calls are blocking; callers run engine methods off the main actor.
/// `@unchecked Sendable`: the underlying uniffi/BDK objects synchronize
/// internally (Rust `Mutex`/`Arc`), and the app uses one engine per session.
public final class WalletEngine: @unchecked Sendable {
    public let network: NetworkKind
    public let scriptType: ScriptType

    private let wallet: Wallet
    private let connection: Connection

    // MARK: - Creation

    public static func generateSecrets(
        network: NetworkKind,
        scriptType: ScriptType = .bip84
    ) -> WalletSecrets {
        let mnemonic = Mnemonic(wordCount: .words12)
        return WalletSecrets(
            mnemonic: mnemonic.description,
            network: network,
            scriptType: scriptType
        )
    }

    /// Builds (or reopens) the wallet for the given secrets. `storageDirectory`
    /// holds BDK's local chain cache — deletable at any time, resyncable.
    ///
    /// `cacheDiscriminator` must identify the chain *backend* (e.g. the
    /// Esplora host): two different signet-family chains (standard signet
    /// vs Mutinynet) share a network name but have incompatible histories,
    /// and reusing one's cache for the other fails with CannotConnectError.
    public init(secrets: WalletSecrets, storageDirectory: URL, cacheDiscriminator: String = "") throws {
        self.network = secrets.network
        self.scriptType = secrets.scriptType

        let bdkNetwork = secrets.network.bdkNetwork
        let mnemonic = try Mnemonic.fromString(mnemonic: secrets.mnemonic)
        let secretKey = DescriptorSecretKey(network: bdkNetwork, mnemonic: mnemonic, password: nil)

        let descriptor: Descriptor
        let changeDescriptor: Descriptor
        switch secrets.scriptType {
        case .bip84:
            descriptor = Descriptor.newBip84(secretKey: secretKey, keychain: .external, network: bdkNetwork)
            changeDescriptor = Descriptor.newBip84(secretKey: secretKey, keychain: .internal, network: bdkNetwork)
        case .bip86:
            descriptor = Descriptor.newBip86(secretKey: secretKey, keychain: .external, network: bdkNetwork)
            changeDescriptor = Descriptor.newBip86(secretKey: secretKey, keychain: .internal, network: bdkNetwork)
        }

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let safeDiscriminator = cacheDiscriminator.replacingOccurrences(of: "/", with: "_")
        let dbName = safeDiscriminator.isEmpty
            ? "bdk-\(secrets.network.rawValue).sqlite"
            : "bdk-\(secrets.network.rawValue)-\(safeDiscriminator).sqlite"
        let dbPath = storageDirectory.appendingPathComponent(dbName).path

        self.connection = try Connection(path: dbPath)
        do {
            self.wallet = try Wallet.load(
                descriptor: descriptor,
                changeDescriptor: changeDescriptor,
                connection: connection
            )
        } catch {
            self.wallet = try Wallet(
                descriptor: descriptor,
                changeDescriptor: changeDescriptor,
                network: bdkNetwork,
                connection: connection
            )
        }

        // Restore hint: make sure previously revealed addresses are watched
        // before the first sync.
        if secrets.receiveIndexHint > 0 {
            _ = wallet.revealAddressesTo(keychain: .external, index: secrets.receiveIndexHint)
        }
        if secrets.changeIndexHint > 0 {
            _ = wallet.revealAddressesTo(keychain: .internal, index: secrets.changeIndexHint)
        }
        try persist()
    }

    // MARK: - Addresses

    /// Reveals and returns the next unused receive address.
    public func nextReceiveAddress() throws -> (address: String, index: UInt32) {
        let info = wallet.revealNextAddress(keychain: .external)
        try persist()
        return (info.address.description, info.index)
    }

    /// Highest revealed indexes — stored in the backup as restore hints.
    public func revealedIndexes() -> (receive: UInt32, change: UInt32) {
        let receive = wallet.derivationIndex(keychain: .external) ?? 0
        let change = wallet.derivationIndex(keychain: .internal) ?? 0
        return (receive, change)
    }

    // MARK: - Chain state

    public func balance() -> WalletBalance {
        let b = wallet.balance()
        let confirmed = b.confirmed.toSat()
        let pending = b.trustedPending.toSat() + b.untrustedPending.toSat() + b.immature.toSat()
        return WalletBalance(confirmedSats: confirmed, pendingSats: pending)
    }

    public func transactions() -> [WalletTransaction] {
        wallet.transactions().map { canonical in
            let tx = canonical.transaction
            let values = wallet.sentAndReceived(tx: tx)
            let sent = values.sent.toSat()
            let received = values.received.toSat()
            let fee = (try? wallet.calculateFee(tx: tx).toSat())

            let direction: WalletTransaction.Direction = sent > received ? .outgoing : .incoming
            let net = sent > received ? sent - received : received - sent
            // For outgoing txs the "amount" users expect excludes the fee.
            let amount = direction == .outgoing ? net - min(fee ?? 0, net) : net

            var confirmed = false
            var timestamp: Date?
            switch canonical.chainPosition {
            case .confirmed(let blockTime, _):
                confirmed = true
                timestamp = Date(timeIntervalSince1970: TimeInterval(blockTime.confirmationTime))
            case .unconfirmed(let ts):
                if let ts { timestamp = Date(timeIntervalSince1970: TimeInterval(ts)) }
            }

            return WalletTransaction(
                txid: tx.computeTxid().description,
                direction: direction,
                amountSats: amount,
                feeSats: fee,
                confirmed: confirmed,
                timestamp: timestamp
            )
        }
        .sorted { ($0.timestamp ?? .distantFuture) > ($1.timestamp ?? .distantFuture) }
    }

    // MARK: - Sync

    /// Incremental sync of revealed script pubkeys; pass `fullScan: true`
    /// after a restore to discover used addresses beyond the hints.
    public func sync(esploraURL: URL, fullScan: Bool = false) throws {
        let client = EsploraClient(url: esploraURL.absoluteString)
        if fullScan {
            let request = try wallet.startFullScan().build()
            let update = try client.fullScan(request: request, stopGap: 25, parallelRequests: 4)
            try wallet.applyUpdate(update: update)
        } else {
            let request = try wallet.startSyncWithRevealedSpks().build()
            let update = try client.sync(request: request, parallelRequests: 4)
            try wallet.applyUpdate(update: update)
        }
        try persist()
    }

    // MARK: - Spending

    public func validateAddress(_ address: String) -> Bool {
        (try? Address(address: address, network: network.bdkNetwork)) != nil
    }

    /// Builds and signs a transaction, returning it with its true fee for
    /// the confirmation sheet. Nothing is broadcast here.
    public func createSignedTransaction(
        to destination: String,
        amountSats: UInt64,
        feeRateSatPerVb: UInt64
    ) throws -> SignedSend {
        guard let address = try? Address(address: destination, network: network.bdkNetwork) else {
            throw WalletKitError.invalidAddress(destination)
        }

        let psbt: Psbt
        do {
            psbt = try TxBuilder()
                .addRecipient(script: address.scriptPubkey(), amount: Amount.fromSat(satoshi: amountSats))
                .feeRate(feeRate: try FeeRate.fromSatPerVb(satVb: feeRateSatPerVb))
                .finish(wallet: wallet)
        } catch {
            if String(describing: error).lowercased().contains("insufficient") {
                throw WalletKitError.insufficientFunds
            }
            throw WalletKitError.internalError("could not build transaction: \(error)")
        }

        let signed = try wallet.sign(psbt: psbt)
        guard signed else {
            throw WalletKitError.internalError("wallet could not finalize signatures")
        }
        let tx = try psbt.extractTx()
        let fee = try wallet.calculateFee(tx: tx).toSat()
        try persist()

        return SignedSend(
            transaction: tx,
            details: PreparedSend(destinationAddress: destination, amountSats: amountSats, feeSats: fee)
        )
    }

    public func broadcast(_ send: SignedSend, esploraURL: URL) throws -> String {
        let client = EsploraClient(url: esploraURL.absoluteString)
        try client.broadcast(transaction: send.transaction)
        return send.transaction.computeTxid().description
    }

    private func persist() throws {
        _ = try wallet.persist(connection: connection)
    }
}

/// A fully signed, not-yet-broadcast transaction. Opaque to the UI layer so
/// app targets never import BitcoinDevKit directly.
public struct SignedSend: @unchecked Sendable {
    let transaction: Transaction
    public let details: PreparedSend

    public var txid: String { transaction.computeTxid().description }
}

extension NetworkKind {
    var bdkNetwork: Network {
        switch self {
        case .bitcoin: return .bitcoin
        case .testnet: return .testnet
        case .signet: return .signet
        case .regtest: return .regtest
        }
    }
}
