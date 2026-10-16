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

    public enum SeedStrength {
        /// 24 words / 256-bit — main wallets.
        case high
        /// 12 words / 128-bit — disposable gift vouchers (URL-sized).
        case standard

        var entropyBytes: Int {
            switch self {
            case .high: return 32
            case .standard: return 16
            }
        }
    }

    /// Seeds come from SeedEntropy (multi-source, fail-closed) — never
    /// from any single library's internal RNG. See SeedEntropy.swift.
    public static func generateSecrets(
        network: NetworkKind,
        scriptType: ScriptType = .bip84,
        strength: SeedStrength = .high
    ) throws -> WalletSecrets {
        let entropy = try SeedEntropy.generate(byteCount: strength.entropyBytes)
        let mnemonic = try Mnemonic.fromEntropy(entropy: [UInt8](entropy))
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

    /// Upcoming receive addresses for the shared snapshot (Siri/widget).
    /// These are REVEALED, not peeked: an address we hand out must be
    /// watched by incremental sync, or money sent to it is invisible
    /// until a full rescan. Idempotent across refreshes until one is used.
    public func revealUpcomingReceiveAddresses(count: UInt32) throws -> [String] {
        let start = wallet.derivationIndex(keychain: .external).map { $0 + 1 } ?? 0
        _ = wallet.revealAddressesTo(keychain: .external, index: start + count - 1)
        try persist()
        return (start..<(start + count)).map {
            wallet.peekAddress(keychain: .external, index: $0).address.description
        }
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
        return WalletBalance(
            confirmedSats: confirmed,
            pendingSats: pending,
            spendableSats: confirmed + b.trustedPending.toSat()
        )
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
        do {
            if fullScan {
                let request = try wallet.startFullScan().build()
                let update = try client.fullScan(request: request, stopGap: 25, parallelRequests: 4)
                try wallet.applyUpdate(update: update)
            } else {
                let request = try wallet.startSyncWithRevealedSpks().build()
                let update = try client.sync(request: request, parallelRequests: 4)
                try wallet.applyUpdate(update: update)
            }
        } catch let error as EsploraError {
            NSLog("esplora sync failed: \(error)")
            throw WalletKitError.networkUnreachable
        }
        try persist()
    }

    // MARK: - Spending

    /// Unconfirmed coins we did not create ourselves. Sends never spend
    /// these: an incoming payment that is still in the mempool can be
    /// dropped or replaced, which would make our own transaction invalid
    /// ("inputs missing or spent"). Change from our own unconfirmed sends
    /// is fine to chain on — we signed the parent — and matches
    /// `WalletBalance.spendableSats`.
    private func untrustedOutpoints() -> [OutPoint] {
        let authored = Set(wallet.transactions().compactMap { canonical -> String? in
            wallet.sentAndReceived(tx: canonical.transaction).sent.toSat() > 0
                ? canonical.transaction.computeTxid().description : nil
        })
        return wallet.listUnspent().compactMap { output in
            guard case .unconfirmed = output.chainPosition else { return nil }
            return authored.contains(output.outpoint.txid) ? nil : output.outpoint
        }
    }

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
                .unspendable(unspendable: untrustedOutpoints())
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

    /// Sweeps every spendable UTXO to `destination` (the "Send Max" path —
    /// no change output; the fee comes out of the swept total).
    ///
    /// `includeUntrusted` also sweeps unconfirmed coins received from others.
    /// Off for the main wallet (see `untrustedOutpoints`); on for a gift
    /// voucher, where the whole point is claiming the moment the card lands.
    public func createSignedDrain(
        to destination: String,
        feeRateSatPerVb: UInt64,
        includeUntrusted: Bool = false
    ) throws -> SignedSend {
        guard let address = try? Address(address: destination, network: network.bdkNetwork) else {
            throw WalletKitError.invalidAddress(destination)
        }

        let psbt: Psbt
        do {
            psbt = try TxBuilder()
                .drainWallet()
                .drainTo(script: address.scriptPubkey())
                .unspendable(unspendable: includeUntrusted ? [] : untrustedOutpoints())
                .feeRate(feeRate: try FeeRate.fromSatPerVb(satVb: feeRateSatPerVb))
                .finish(wallet: wallet)
        } catch {
            if String(describing: error).lowercased().contains("insufficient") {
                throw WalletKitError.insufficientFunds
            }
            throw WalletKitError.internalError("could not build sweep: \(error)")
        }

        let signed = try wallet.sign(psbt: psbt)
        guard signed else {
            throw WalletKitError.internalError("wallet could not finalize signatures")
        }
        let tx = try psbt.extractTx()
        let fee = try wallet.calculateFee(tx: tx).toSat()
        // A drain has a single recipient and no change: the sent amount is
        // simply the sum of the outputs.
        let amount = tx.output().reduce(UInt64(0)) { $0 + $1.value }
        try persist()

        return SignedSend(
            transaction: tx,
            details: PreparedSend(destinationAddress: destination, amountSats: amount, feeSats: fee)
        )
    }

    /// RBF fee bump for one of our unconfirmed sends.
    public func createFeeBump(txid: String, feeRateSatPerVb: UInt64) throws -> SignedSend {
        let psbt: Psbt
        do {
            psbt = try BumpFeeTxBuilder(
                txid: txid,
                feeRate: try FeeRate.fromSatPerVb(satVb: feeRateSatPerVb)
            )
            .finish(wallet: wallet)
        } catch {
            throw WalletKitError.feeBumpNotPossible(String(describing: error))
        }

        let signed = try wallet.sign(psbt: psbt)
        guard signed else {
            throw WalletKitError.internalError("wallet could not finalize signatures")
        }
        let tx = try psbt.extractTx()
        let fee = try wallet.calculateFee(tx: tx).toSat()
        let values = wallet.sentAndReceived(tx: tx)
        let sent = values.sent.toSat()
        let received = values.received.toSat()
        let amount = sent > received ? sent - received - min(fee, sent - received) : 0
        try persist()

        return SignedSend(
            transaction: tx,
            details: PreparedSend(destinationAddress: "Speed-up of \(txid.prefix(8))…", amountSats: amount, feeSats: fee)
        )
    }

    public func broadcast(_ send: SignedSend, esploraURL: URL) throws -> String {
        let client = EsploraClient(url: esploraURL.absoluteString)
        do {
            try client.broadcast(transaction: send.transaction)
        } catch let error as EsploraError {
            NSLog("broadcast failed: \(error)")
            if case .HttpResponse(let status, let message) = error, (400..<500).contains(status) {
                // A retry (timeout → failover) can land after the first
                // attempt actually went through. That's success.
                let lowered = message.lowercased()
                if !(lowered.contains("already-in-mempool") || lowered.contains("already-known")
                    || lowered.contains("already in block chain")) {
                    // A 4xx is the node's verdict on the transaction itself
                    // (missing inputs, fee below relay minimum, …) — not a
                    // connectivity problem, so don't dress it up as one.
                    throw WalletKitError.transactionRejected(Self.humanizeRejection(message))
                }
            } else {
                throw WalletKitError.networkUnreachable
            }
        }
        // Record it locally right away so balance and activity reflect the
        // spend immediately — the next sync confirms it, but a slow endpoint
        // must not leave the user staring at the pre-send balance.
        wallet.applyUnconfirmedTxs(unconfirmedTxs: [
            UnconfirmedTx(tx: send.transaction, lastSeen: UInt64(Date().timeIntervalSince1970))
        ])
        try? persist()
        return send.transaction.computeTxid().description
    }

    private func persist() throws {
        _ = try wallet.persist(connection: connection)
    }

    /// Esplora returns Bitcoin Core's raw reject string (often wrapped in
    /// JSON). Pull out the part a person can act on.
    static func humanizeRejection(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.contains("missingorspent") || lowered.contains("already spent") {
            return "one of the coins it spends is no longer available. Pull to refresh and try again."
        }
        if lowered.contains("min relay fee") || lowered.contains("mempool min fee") || lowered.contains("insufficient fee") {
            // "insufficient fee" is also what a node says when the tx
            // conflicts with one already in its mempool (ours, moments ago).
            return "the fee is too low for the network right now, or it conflicts with a payment you just made. Pull to refresh, then try again with a faster fee tier."
        }
        // Strip a JSON envelope like {"code":-26,"message":"..."} if present.
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = obj["message"] as? String {
            return message
        }
        return trimmed.isEmpty ? "no reason given." : trimmed
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
