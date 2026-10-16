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
    /// Highest receive index ever handed out, from `WalletSecrets`. Every
    /// address at or below it has been shown to someone and is never
    /// offered again. Hand-outs (Receive, claims, Siri) all consume the
    /// same ordered queue of revealed addresses above this mark, so there
    /// is one source of truth and nothing is wasted.
    public private(set) var handedOutReceiveIndex: UInt32?
    /// Unconfirmed transactions the mempool has dropped or replaced. BDK
    /// (1.2 bindings) can't forget a transaction it has seen, so these are
    /// hidden from history and their pending value removed from the
    /// balance here. Persisted next to the chain cache; cleared when the
    /// cache is rebuilt.
    private var evictedTxids: Set<String> = []
    private let evictedFileURL: URL
    /// True when no chain cache existed for this wallet and one was just
    /// created. Such a wallet knows nothing about change addresses or
    /// history, so its first sync must be a full scan, not an incremental
    /// one over the few addresses the restore hint revealed.
    public let startedFromEmptyCache: Bool
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
        let dbURL = Self.chainCacheURL(
            storageDirectory: storageDirectory, network: secrets.network, cacheDiscriminator: cacheDiscriminator
        )
        let dbPath = dbURL.path
        self.evictedFileURL = dbURL.deletingPathExtension().appendingPathExtension("evicted.json")
        if let data = try? Data(contentsOf: evictedFileURL),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.evictedTxids = Set(ids)
        }

        self.connection = try Connection(path: dbPath)
        do {
            self.wallet = try Wallet.load(
                descriptor: descriptor,
                changeDescriptor: changeDescriptor,
                connection: connection
            )
            self.startedFromEmptyCache = false
        } catch {
            self.wallet = try Wallet(
                descriptor: descriptor,
                changeDescriptor: changeDescriptor,
                network: bdkNetwork,
                connection: connection
            )
            self.startedFromEmptyCache = true
        }

        // Secrets written before the hand-out mark existed carry only the
        // revealed-index hint. Anything revealed back then may have been
        // shown to someone, so treat all of it as handed out: a few unused
        // addresses are skipped once, and nothing is ever offered twice.
        let legacyTop: UInt32? = {
            let fromHint: UInt32? = secrets.receiveIndexHint > 0 ? secrets.receiveIndexHint : nil
            let fromCache = wallet.derivationIndex(keychain: .external)
            switch (fromHint, fromCache) {
            case let (h?, c?): return max(h, c)
            case let (h?, nil): return h
            case let (nil, c?): return c
            case (nil, nil): return nil
            }
        }()
        self.handedOutReceiveIndex = secrets.handedOutReceiveIndex ?? legacyTop

        // Restore hint: make sure previously revealed addresses are watched
        // before the first sync. Capped: every revealed address costs a
        // request on every sync, and a hint far beyond what this cache has
        // seen is a sign of the old runaway reveal (see
        // revealUpcomingReceiveAddresses), not of hundreds of handed-out
        // addresses. A restore's full scan finds used ones regardless.
        let hintCap: UInt32 = 30
        let receiveTop = wallet.derivationIndex(keychain: .external).map { $0 + 1 } ?? 0
        let changeTop = wallet.derivationIndex(keychain: .internal).map { $0 + 1 } ?? 0
        if secrets.receiveIndexHint > 0 {
            _ = wallet.revealAddressesTo(keychain: .external, index: min(secrets.receiveIndexHint, receiveTop + hintCap))
        }
        if secrets.changeIndexHint > 0 {
            _ = wallet.revealAddressesTo(keychain: .internal, index: min(secrets.changeIndexHint, changeTop + hintCap))
        }
        try persist()
    }

    /// Where the BDK chain cache for a wallet lives. Deletable at any time;
    /// a full scan rebuilds it.
    public static func chainCacheURL(storageDirectory: URL, network: NetworkKind, cacheDiscriminator: String) -> URL {
        let safe = cacheDiscriminator.replacingOccurrences(of: "/", with: "_")
        let name = safe.isEmpty ? "bdk-\(network.rawValue).sqlite" : "bdk-\(network.rawValue)-\(safe).sqlite"
        return storageDirectory.appendingPathComponent(name)
    }

    /// Removes the chain cache (and SQLite sidecars). Call with no engine
    /// open on it.
    public static func removeChainCache(storageDirectory: URL, network: NetworkKind, cacheDiscriminator: String) {
        let base = chainCacheURL(storageDirectory: storageDirectory, network: network, cacheDiscriminator: cacheDiscriminator)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: base.path + suffix)
        }
    }

    /// Revealed receive addresses nobody has paid yet. A healthy wallet has
    /// a handful; dozens means a cache poisoned by the old runaway reveal,
    /// which the store repairs by rebuilding the cache.
    public var unusedReceiveAddressCount: Int {
        wallet.listUnusedAddresses(keychain: .external).count
    }

    // MARK: - Addresses

    /// Revealed, unpaid receive addresses nobody has been given yet, in
    /// index order. Hand-outs take from the front.
    private func handOutQueue() -> [AddressInfo] {
        let floor = handedOutReceiveIndex.map { $0 + 1 } ?? 0
        return wallet.listUnusedAddresses(keychain: .external).filter { $0.index >= floor }
    }

    private func ensureQueue(atLeast count: Int) {
        let have = handOutQueue().count
        guard have < count else { return }
        let top = wallet.derivationIndex(keychain: .external).map { $0 + 1 } ?? 0
        _ = wallet.revealAddressesTo(keychain: .external, index: top + UInt32(count - have) - 1)
    }

    private func noteHandedOut(_ index: UInt32) {
        handedOutReceiveIndex = max(handedOutReceiveIndex ?? 0, index)
        _ = wallet.markUsed(keychain: .external, index: index)
    }

    /// Hands out the next receive address. "Handed out" is final: once an
    /// address has been on a screen, in a card or in Siri's mouth it is
    /// never offered again, whether or not money arrives (it stays
    /// revealed, so sync keeps watching it). `excluding` lets the caller
    /// skip addresses another process has issued but not yet reconciled
    /// (the host app's Siri ledger).
    public func nextReceiveAddress(excluding: Set<String> = []) throws -> (address: String, index: UInt32) {
        var attempts = 0
        while attempts < 8 {
            ensureQueue(atLeast: 1 + excluding.count)
            if let info = handOutQueue().first(where: { !excluding.contains($0.address.description) }) {
                noteHandedOut(info.index)
                try persist()
                return (info.address.description, info.index)
            }
            attempts += 1
        }
        throw WalletKitError.internalError("could not find a fresh receive address")
    }

    /// Records that the host app (Siri / Shortcuts) handed `address` out.
    /// Returns false if it is not one of this wallet's revealed receive
    /// addresses.
    @discardableResult
    public func markReceiveAddressHandedOut(_ address: String) throws -> Bool {
        let top = wallet.derivationIndex(keychain: .external) ?? 0
        guard wallet.derivationIndex(keychain: .external) != nil else { return false }
        for index in 0...top where wallet.peekAddress(keychain: .external, index: index).address.description == address {
            noteHandedOut(index)
            try persist()
            return true
        }
        return false
    }

    /// Upcoming receive addresses reserved for the host app (Siri /
    /// Shortcuts), published in the shared snapshot. These are REVEALED,
    /// not peeked: an address we hand out must be watched by incremental
    /// sync, or money sent to it is invisible until a full rescan.
    ///
    /// Idempotent: returns the `count` revealed-but-not-yet-handed-out
    /// addresses and reveals more only when fewer than `count` exist. (An
    /// earlier version revealed `count` fresh ones past the top on every
    /// refresh, so the watched set grew by three per tick — hundreds of
    /// addresses, each a request per sync.) Because every address shown in
    /// Receive or issued by Siri is marked used, nothing here can collide
    /// with an address already given to someone.
    public func revealUpcomingReceiveAddresses(count: UInt32) throws -> [String] {
        let before = wallet.derivationIndex(keychain: .external)
        ensureQueue(atLeast: Int(count))
        if wallet.derivationIndex(keychain: .external) != before { try persist() }
        return handOutQueue().prefix(Int(count)).map { $0.address.description }
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
        var pending = b.trustedPending.toSat() + b.untrustedPending.toSat() + b.immature.toSat()
        // Dropped incoming payments still sit in BDK's untrusted-pending;
        // take them back out so the balance tells the truth.
        pending -= min(pending, evictedPendingSats())
        return WalletBalance(
            confirmedSats: confirmed,
            pendingSats: pending,
            spendableSats: confirmed + b.trustedPending.toSat()
        )
    }

    private func evictedPendingSats() -> UInt64 {
        guard !evictedTxids.isEmpty else { return 0 }
        return wallet.transactions().reduce(UInt64(0)) { sum, canonical in
            let txid = canonical.transaction.computeTxid().description
            guard evictedTxids.contains(txid), case .unconfirmed = canonical.chainPosition else { return sum }
            let values = wallet.sentAndReceived(tx: canonical.transaction)
            let received = values.received.toSat(), sent = values.sent.toSat()
            return sum + (received > sent ? received - sent : 0)
        }
    }

    /// Records a transaction as seen in the mempool right now (what
    /// `broadcast` does for our own sends; tests use it to stage incoming
    /// ones).
    public func applyUnconfirmed(_ tx: Transaction) throws {
        wallet.applyUnconfirmedTxs(unconfirmedTxs: [
            UnconfirmedTx(tx: tx, lastSeen: UInt64(Date().timeIntervalSince1970))
        ])
        try persist()
    }

    /// Hides a dropped or replaced unconfirmed transaction (see
    /// `evictedTxids`). No-op for confirmed transactions: a block wins.
    public func evict(txid: String) {
        guard let canonical = try? wallet.getTx(txid: txid), case .unconfirmed = canonical.chainPosition else { return }
        evictedTxids.insert(txid)
        try? JSONEncoder().encode(Array(evictedTxids)).write(to: evictedFileURL, options: .atomic)
    }

    public func isEvicted(txid: String) -> Bool { evictedTxids.contains(txid) }

    /// Re-announces one of our own unconfirmed transactions (a mempool may
    /// purge low-fee transactions during congestion). Throws
    /// `transactionRejected` when the network won't take it any more.
    public func rebroadcast(txid: String, esploraURL: URL) throws {
        guard let canonical = try? wallet.getTx(txid: txid), case .unconfirmed = canonical.chainPosition else { return }
        let client = EsploraClient(url: esploraURL.absoluteString)
        do {
            try client.broadcast(transaction: canonical.transaction)
        } catch let error as EsploraError {
            if case .HttpResponse(let status, let message) = error {
                if status == 429 { throw WalletKitError.rateLimited }
                if (400..<500).contains(status) {
                    let lowered = message.lowercased()
                    if lowered.contains("already-in-mempool") || lowered.contains("already-known")
                        || lowered.contains("already in block chain") { return }
                    throw WalletKitError.transactionRejected(Self.humanizeRejection(message))
                }
            }
            throw WalletKitError.networkUnreachable
        }
    }

    public func transactions() -> [WalletTransaction] {
        wallet.transactions().compactMap { canonical -> WalletTransaction? in
            let tx = canonical.transaction
            if evictedTxids.contains(tx.computeTxid().description) { return nil }
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
            if case .HttpResponse(let status, _) = error, status == 429 {
                throw WalletKitError.rateLimited
            }
            throw WalletKitError.networkUnreachable
        }
        try persist()
    }

    /// How many script pubkeys an incremental sync queries — one Esplora
    /// request each, before transaction fetches. Lets the store reason
    /// about the request budget.
    public var watchedScriptPubkeyCount: Int {
        let receive = wallet.derivationIndex(keychain: .external).map { Int($0) + 1 } ?? 0
        let change = wallet.derivationIndex(keychain: .internal).map { Int($0) + 1 } ?? 0
        return receive + change
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
            if case .HttpResponse(let status, _) = error, status == 429 {
                throw WalletKitError.rateLimited
            }
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
