import AuthenticationServices
import Foundation
import WalletKit
import WidgetKit

/// App-layer state machine implementing the auto-wallet model (ADR 0004):
/// opening Satchel silently creates or restores the wallet — no ceremony,
/// no prompts. Face ID guards what matters: spending and revealing the
/// recovery phrase. Balance and receiving are as open as a mailbox.
@MainActor
final class WalletStore: ObservableObject {
    enum Phase: Equatable {
        case loading
        case working(String)
        case ready
        case setupFailed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var balance = WalletBalance(confirmedSats: 0, pendingSats: 0)
    @Published private(set) var transactions: [WalletTransaction] = []
    @Published private(set) var feeTiers: FeeTiers = .fallback
    @Published private(set) var isSyncing = false
    @Published var lastError: String?
    /// Set when the user taps a payment card in the transcript.
    @Published var incomingRequest: IncomingCard?
    /// False when iCloud is unreachable and the backup only exists on this
    /// device (simulator, iCloud Drive off). Home shows a warning banner.
    @Published private(set) var backupInICloud = true
    /// BTC/USD for display only (nil hides fiat lines). Fetched on-device
    /// from a public API — no company server involved.
    @Published private(set) var usdPerBTC: Double?

    let chain: ChainConfig
    /// Wired by MessagesViewController; passkey sheets need a window.
    var presentationAnchor: @MainActor () -> ASPresentationAnchor? = { nil }

    private var engine: WalletEngine?
    private var secrets: WalletSecrets?
    /// Key material + provider id used this session, cached (memory only)
    /// so resealing the backup never re-prompts Face ID/passkey.
    private var sessionKey: (material: Data, provider: String)?
    private let keychainProvider = SyncedKeychainKeyProvider()
    private let backupStore = ICloudBackupStore()
    private let localSecrets = LocalSecretsStore()
    private let faceID = FaceIDGate()
    private let feeEstimator = FeeEstimator()
    private let priceOracle = PriceOracle()
    private var started = false

    /// Which provider sealed the cloud envelope, remembered across launches
    /// so silent reseals never downgrade a passkey-sealed backup.
    private static let backupProviderKey = "backupKeyProvider.v1"
    private var knownBackupProvider: String? {
        get { UserDefaults.standard.string(forKey: Self.backupProviderKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.backupProviderKey) }
    }

    init(chain: ChainConfig = .fromBundle()) {
        self.chain = chain
    }

    // MARK: - Lifecycle (auto-wallet)

    func start() async {
        guard !started else {
            if engine != nil { await refresh() }
            return
        }
        started = true
        loadGifts()
        await bootstrap()
    }

    func retrySetup() async {
        await bootstrap()
    }

    // MARK: - Live refresh

    private var autoRefreshTask: Task<Void, Never>?
    private var hasLoadedOnce = false

    /// Polls the chain every few seconds while the extension is on screen,
    /// so incoming payments appear without closing and reopening. Started
    /// on willBecomeActive, stopped on willResignActive — never runs in
    /// the background (extensions don't have one).
    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    /// Silent create-or-restore. The only prompt that can appear is a
    /// passkey assertion, and only when restoring a passkey-sealed backup
    /// onto a fresh device.
    private func bootstrap() async {
        guard engine == nil else {
            phase = .ready
            return
        }
        do {
            if let cached = localSecrets.load() {
                // Fast path: this device already holds the wallet.
                try await bootEngine(with: cached)
                phase = .ready
                await refresh()
                return
            }
            // Everything touching the ubiquity container must stay off the
            // main actor: url(forUbiquityContainerIdentifier:) can block for
            // seconds on a real device while iOS provisions the container —
            // on main it freezes the extension into a blank panel.
            let store = backupStore
            let hasBackup = try await Self.offMain { store.backupExists() }
            if hasBackup {
                phase = .working("Restoring your wallet…")
                let envelope = try await Task.detached(priority: .userInitiated) {
                    try await store.load()
                }.value
                let material = try await keyMaterial(for: envelope)
                sessionKey = (material, envelope.keyProvider)
                knownBackupProvider = envelope.keyProvider
                let restored = try BackupCrypto.open(envelope, inputKeyMaterial: material)
                try await bootEngine(with: restored)
                localSecrets.save(restored)
                backupInICloud = try await Self.offMain { store.isUsingICloud }
                phase = .ready
                await refresh(fullScan: true)
            } else {
                phase = .working("Setting things up…")
                // Silent creation: random seed, sealed with the synced
                // keychain key. Passkey protection is an explicit upgrade
                // in Settings (its registration sheet can't be silent).
                let material = try await keychainProvider.keyMaterial()
                sessionKey = (material, keychainProvider.identifier)
                let fresh = WalletEngine.generateSecrets(network: chain.network)
                try await bootEngine(with: fresh)
                try await persistBackup()
                localSecrets.save(fresh)
                phase = .ready
                await refresh()
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            phase = .setupFailed(message)
        }
    }

    private func bootEngine(with secrets: WalletSecrets) async throws {
        let storageDir = Self.walletStorageDirectory()
        let cacheKey = chain.esploraURL.host ?? ""
        let engine = try await Self.offMain {
            try WalletEngine(secrets: secrets, storageDirectory: storageDir, cacheDiscriminator: cacheKey)
        }
        self.engine = engine
        self.secrets = secrets
    }

    /// Key material for a restore, honoring the envelope's provider:
    /// synced keychain reads silently; a passkey-sealed backup requires an
    /// assertion (that's its whole point — one Face ID on a new device).
    private func keyMaterial(for envelope: BackupEnvelope) async throws -> Data {
        switch envelope.keyProvider {
        case "passkey-prf":
            guard #available(iOS 18.0, *) else {
                throw WalletKitError.keyUnavailable(
                    "This backup is protected by a passkey and needs iOS 18 or later."
                )
            }
            let prf = PasskeyPRFKeyProvider(anchor: presentationAnchor)
            guard let material = try await prf.existingKeyMaterial() else {
                throw WalletKitError.keyUnavailable(
                    "Couldn't reach the wallet passkey. Check that iCloud Keychain is on and try again."
                )
            }
            return material
        default:
            guard let material = try await keychainProvider.existingKeyMaterial() else {
                throw WalletKitError.keyUnavailable(
                    "Backup key hasn't synced to this device yet. Make sure iCloud Keychain is on, then try again."
                )
            }
            return material
        }
    }

    // MARK: - Chain state

    func refresh(fullScan: Bool = false) async {
        guard let engine, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            try await withEsploraFailover { esplora in
                try await Self.offMain { try engine.sync(esploraURL: esplora, fullScan: fullScan) }
            }
        } catch {
            // Sync failures are non-fatal: show cached state plus a notice.
            report(error)
        }
        let previousTotal = balance.totalSats
        balance = engine.balance()
        transactions = engine.transactions()
        feeTiers = await feeEstimator.tiers(esploraURL: chain.esploraURL, feesURL: chain.feesURL)
        usdPerBTC = await priceOracle.usdPerBTC() ?? usdPerBTC
        publishSnapshot()

        // Money arriving while you watch deserves a buzz.
        if hasLoadedOnce, balance.totalSats > previousTotal {
            Haptics.success()
        }
        hasLoadedOnce = true

        // Keep the handed-out (Siri/widget) addresses revealed & backed up.
        let before = engine.revealedIndexes().receive
        upcomingAddresses = (try? await Self.offMain { try engine.revealUpcomingReceiveAddresses(count: 3) }) ?? []
        if engine.revealedIndexes().receive != before {
            try? await persistBackup()
        }
    }

    /// Snapshot-published addresses; revealed so sync watches them.
    private var upcomingAddresses: [String] = []

    /// "≈ $12.34" for display, or nil when the rate is unknown.
    func usdApprox(_ sats: UInt64) -> String? {
        guard let usdPerBTC, sats > 0 else { return nil }
        return "≈ " + PriceOracle.usdString(sats: sats, usdPerBTC: usdPerBTC)
    }

    /// Watch-only state for the widget and Siri intents (App Group).
    /// Never includes key material.
    private func publishSnapshot() {
        guard let engine else { return }
        SharedSnapshot(
            balanceSats: balance.totalSats,
            pendingSats: balance.pendingSats,
            recent: transactions.prefix(4).map {
                SharedSnapshot.Activity(
                    txid: $0.txid,
                    incoming: $0.direction == .incoming,
                    amountSats: $0.amountSats,
                    confirmed: $0.confirmed,
                    timestamp: $0.timestamp
                )
            },
            network: chain.network.rawValue,
            upcomingReceiveAddresses: upcomingAddresses,
            usdPerBTC: usdPerBTC,
            updatedAt: Date()
        ).save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Receive

    func makeReceiveRequest(amountSats: UInt64?, label: String?) async throws -> PaymentRequest {
        guard let engine else { throw WalletKitError.internalError("wallet not ready") }
        let next = try await Self.offMain { try engine.nextReceiveAddress() }
        try? await persistBackup() // advance index hints; best-effort
        return PaymentRequest(address: next.address, amountSats: amountSats, label: label)
    }

    // MARK: - Send

    /// Live validation for the Send form's destination field.
    func isValidAddress(_ address: String) -> Bool {
        guard let engine else { return false }
        return engine.validateAddress(address.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let paidAddressesKey = "paidAddresses.v1"

    /// Addresses this wallet has paid before — the reference set for
    /// address-poisoning detection. Local to this device; capped.
    private var paidAddresses: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.paidAddressesKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.suffix(200)), forKey: Self.paidAddressesKey) }
    }

    /// Non-nil when `candidate` looks like a poisoning lookalike of an
    /// address previously paid from this wallet.
    func poisoningSuspect(for candidate: String) -> String? {
        AddressSafety.poisoningSuspect(
            candidate: candidate.trimmingCharacters(in: .whitespacesAndNewlines),
            history: paidAddresses
        )
    }

    private func recordPaidAddress(_ address: String) {
        // Skip pseudo-destinations like "Speed-up of abc123…".
        guard !address.contains(where: \.isWhitespace) else { return }
        var list = paidAddresses
        guard !list.contains(address) else { return }
        list.append(address)
        paidAddresses = list
    }

    /// Converts a SmartAmount parse into sats using the live display rate.
    func satsFor(_ parsed: SmartAmount.Parsed) -> UInt64? {
        switch parsed {
        case .sats(let sats):
            return sats
        case .usd(let dollars):
            guard let usdPerBTC, usdPerBTC > 0 else { return nil }
            return UInt64((dollars / usdPerBTC * 100_000_000).rounded())
        }
    }

    /// Face ID first, then build + sign. Returns the signed-but-unbroadcast
    /// transaction for the review sheet. `drain: true` sweeps everything
    /// (Send Max) and ignores `amountSats`.
    func prepareSend(
        to address: String,
        amountSats: UInt64,
        feeRateSatPerVb: UInt64,
        drain: Bool = false
    ) async throws -> SignedSend {
        guard let engine else { throw WalletKitError.internalError("wallet not ready") }
        guard engine.validateAddress(address) else { throw WalletKitError.invalidAddress(address) }
        if !drain, amountSats < dustLimitSats { throw WalletKitError.amountBelowDust }
        try await faceID.authenticate(reason: "Approve sending Bitcoin")
        return try await Self.offMain {
            drain
                ? try engine.createSignedDrain(to: address, feeRateSatPerVb: feeRateSatPerVb)
                : try engine.createSignedTransaction(
                    to: address,
                    amountSats: amountSats,
                    feeRateSatPerVb: feeRateSatPerVb
                )
        }
    }

    /// RBF speed-up of a pending outgoing tx at the current fastest rate.
    /// Face ID gates it like any other spend, then broadcasts immediately.
    func speedUp(txid: String) async throws -> String {
        guard let engine else { throw WalletKitError.internalError("wallet not ready") }
        try await faceID.authenticate(reason: "Approve the higher network fee")
        let rate = max(feeTiers.fastestFee, feeTiers.minimumFee)
        let bumped = try await Self.offMain {
            try engine.createFeeBump(txid: txid, feeRateSatPerVb: rate)
        }
        let newTxid = try await withEsploraFailover { esplora in
            try await Self.offMain { try engine.broadcast(bumped, esploraURL: esplora) }
        }
        await refresh()
        return newTxid
    }

    func broadcast(_ send: SignedSend) async throws -> String {
        guard let engine else { throw WalletKitError.internalError("wallet not ready") }
        let txid = try await withEsploraFailover { esplora in
            try await Self.offMain { try engine.broadcast(send, esploraURL: esplora) }
        }
        recordPaidAddress(send.details.destinationAddress)
        await refresh()
        return txid
    }

    /// Runs `operation` against each same-chain Esplora endpoint in order,
    /// moving on only for connectivity failures (rate limits, outages).
    /// Any other error is the operation's own problem and surfaces as-is.
    private func withEsploraFailover<T>(
        _ operation: (URL) async throws -> T
    ) async throws -> T {
        for (index, url) in chain.esploraURLs.enumerated() {
            do {
                return try await operation(url)
            } catch let error as WalletKitError {
                guard case .networkUnreachable = error, index < chain.esploraURLs.count - 1 else {
                    throw error
                }
            }
        }
        throw WalletKitError.networkUnreachable
    }

    // MARK: - Claimable gifts (ADR 0005)

    struct GiftRecord: Codable, Equatable, Identifiable {
        let voucher: ClaimVoucher
        let fundingTxid: String
        var id: String { voucher.address }
    }

    private static let giftLedgerKey = "claimLedger.v1"
    @Published private(set) var outstandingGifts: [GiftRecord] = []

    func loadGifts() {
        guard let data = UserDefaults.standard.data(forKey: Self.giftLedgerKey) else { return }
        outstandingGifts = (try? JSONDecoder().decode([GiftRecord].self, from: data)) ?? []
    }

    private func saveGifts() {
        UserDefaults.standard.set(try? JSONEncoder().encode(outstandingGifts), forKey: Self.giftLedgerKey)
    }

    func isOwnGift(_ voucher: ClaimVoucher) -> Bool {
        outstandingGifts.contains { $0.voucher.address == voucher.address }
    }

    /// Generates a voucher and the Face-ID-gated funding transaction.
    /// Nothing is broadcast or recorded until `fundGift` runs.
    func prepareGift(amountSats: UInt64, feeRateSatPerVb: UInt64) async throws -> (ClaimVoucher, SignedSend) {
        guard engine != nil else { throw WalletKitError.internalError("wallet not ready") }
        let network = chain.network
        let voucher = try await Self.offMain {
            try ClaimVoucher.generate(network: network, amountSats: amountSats)
        }
        let send = try await prepareSend(
            to: voucher.address,
            amountSats: amountSats,
            feeRateSatPerVb: feeRateSatPerVb
        )
        return (voucher, send)
    }

    /// Broadcasts the funding tx and remembers the gift for reclaim.
    func fundGift(_ voucher: ClaimVoucher, send: SignedSend) async throws -> String {
        let txid = try await broadcast(send)
        outstandingGifts.append(GiftRecord(voucher: voucher, fundingTxid: txid))
        saveGifts()
        return txid
    }

    /// Sweeps a voucher into this wallet — used identically by recipients
    /// (claim) and senders (cancel/reclaim); the chain arbitrates races.
    /// Claiming is receiving, so there is no Face ID gate.
    func redeem(_ voucher: ClaimVoucher) async throws -> UInt64 {
        guard let engine else { throw WalletKitError.internalError("wallet not ready") }
        guard voucher.network == chain.network else {
            throw WalletKitError.internalError("This gift is on \(voucher.network.rawValue); this wallet is on \(chain.network.rawValue).")
        }
        let destination = try await Self.offMain { try engine.nextReceiveAddress() }.address
        let rate = max(feeTiers.halfHourFee, feeTiers.minimumFee)
        let swept = try await withEsploraFailover { esplora in
            try await Self.offMain {
                try ClaimVoucher.sweep(
                    mnemonic: voucher.mnemonic,
                    network: voucher.network,
                    to: destination,
                    esploraURL: esplora,
                    feeRateSatPerVb: rate
                )
            }
        }
        outstandingGifts.removeAll { $0.voucher.address == voucher.address }
        saveGifts()
        await refresh()
        return swept.sweptSats
    }

    // MARK: - Settings

    /// Face ID → the 12 words, for the advanced recovery escape hatch.
    /// Never cached anywhere; the caller shows them and lets go.
    func revealSeed() async throws -> [String] {
        guard let secrets else { throw WalletKitError.internalError("wallet not ready") }
        try await faceID.authenticate(reason: "Reveal your recovery phrase")
        return secrets.mnemonic.split(separator: " ").map(String.init)
    }

    /// Re-saves the backup; if iCloud has become reachable since the last
    /// save this migrates the local-only copy into the ubiquity container.
    func ensureBackupInICloud() async {
        try? await persistBackup()
    }

    var backupKeyProviderName: String {
        switch sessionKey?.provider ?? knownBackupProvider {
        case "passkey-prf": return "Passkey (Face ID)"
        default: return "iCloud Keychain + Face ID"
        }
    }

    /// Whether the explicit "upgrade to passkey" Settings action applies:
    /// device build, iOS 18+, and a backup still sealed by the keychain key.
    var canUpgradeToPasskey: Bool {
        #if targetEnvironment(simulator)
            return false
        #else
            guard #available(iOS 18.0, *) else { return false }
            return (sessionKey?.provider ?? knownBackupProvider) != "passkey-prf"
        #endif
    }

    /// Explicit, user-initiated upgrade (ADR 0002/0004): register the
    /// wallet passkey and reseal the backup with its PRF output.
    func upgradeToPasskeyProtection() async throws {
        guard secrets != nil else { throw WalletKitError.internalError("wallet not ready") }
        guard #available(iOS 18.0, *) else {
            throw WalletKitError.keyUnavailable("Passkey protection needs iOS 18 or later.")
        }
        let prf = PasskeyPRFKeyProvider(anchor: presentationAnchor)
        let material = try await prf.keyMaterial()
        sessionKey = (material, prf.identifier)
        try await persistBackup()
    }

    // MARK: - Backup

    /// Reseals the backup with current index hints. Called after wallet
    /// creation and whenever new addresses are revealed. Uses the
    /// session-cached key when present; otherwise falls back to the silent
    /// keychain key — but never silently downgrades a passkey-sealed backup.
    private func persistBackup() async throws {
        guard let engine, var secrets else { return }

        if sessionKey == nil {
            guard knownBackupProvider != "passkey-prf" else { return } // hints stay stale; harmless
            let material = try await keychainProvider.keyMaterial()
            sessionKey = (material, keychainProvider.identifier)
        }
        guard let sessionKey else { return }

        let indexes = engine.revealedIndexes()
        secrets.receiveIndexHint = indexes.receive
        secrets.changeIndexHint = indexes.change
        self.secrets = secrets
        localSecrets.save(secrets)

        let envelope = try BackupCrypto.seal(
            secrets,
            inputKeyMaterial: sessionKey.material,
            keyProvider: sessionKey.provider
        )
        // Ubiquity writes off-main (see bootstrap note).
        let store = backupStore
        let inICloud = try await Self.offMain {
            try store.save(envelope)
            return store.isUsingICloud
        }
        knownBackupProvider = sessionKey.provider
        backupInICloud = inICloud
    }

    // MARK: - Helpers

    private func report(_ error: Error) {
        lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func walletStorageDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wallet", isDirectory: true)
    }

    private nonisolated static func offMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

extension ChainConfig {
    /// Network is a build setting (`WALLET_NETWORK` → Info.plist `WalletNetwork`):
    /// Debug builds default to standard signet so the team can test with
    /// free faucet coins; Release is mainnet.
    static func fromBundle(_ bundle: Bundle = .main) -> ChainConfig {
        switch bundle.object(forInfoDictionaryKey: "WalletNetwork") as? String {
        case "signet": return .signet
        case "bitcoin": return .mainnet
        default:
            #if DEBUG
                return .signet
            #else
                return .mainnet
            #endif
        }
    }
}
