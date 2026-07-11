import AuthenticationServices
import Foundation
import WalletKit

/// App-layer state machine. Owns the engine, the decrypted secrets (memory
/// only, per session), and the backup lifecycle. Every entry into the wallet
/// — create, restore/unlock, send — goes through the Face ID gate first.
@MainActor
final class WalletStore: ObservableObject {
    enum Phase: Equatable {
        case loading
        /// No unlocked wallet yet. `hasBackup` decides Create vs Unlock UI.
        case welcome(hasBackup: Bool)
        case working(String)
        case ready
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
    /// from a public API — no TW server involved.
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
    private let faceID = FaceIDGate()
    private let feeEstimator = FeeEstimator()
    private let priceOracle = PriceOracle()
    private var started = false

    init(chain: ChainConfig = .fromBundle()) {
        self.chain = chain
    }

    // MARK: - Lifecycle

    func start() async {
        guard !started else {
            if engine != nil { await refresh() }
            return
        }
        started = true
        guard engine == nil else {
            phase = .ready
            return
        }
        phase = .welcome(hasBackup: backupStore.backupExists())
    }

    /// One tap: Face ID (passkey registration when available, LAContext
    /// otherwise) → new seed → wallet → encrypted iCloud backup.
    func createWallet() async {
        do {
            phase = .working("Setting up Face ID…")
            sessionKey = try await establishKeyForNewWallet()
            phase = .working("Creating your wallet…")

            let secrets = WalletEngine.generateSecrets(network: chain.network)
            let storageDir = Self.walletStorageDirectory()
            let cacheKey = chain.esploraURL.host ?? ""
            let engine = try await Self.offMain {
                try WalletEngine(secrets: secrets, storageDirectory: storageDir, cacheDiscriminator: cacheKey)
            }
            self.engine = engine
            self.secrets = secrets

            phase = .working("Backing up to iCloud…")
            try await persistBackup()

            phase = .ready
            await refresh()
        } catch {
            report(error)
            phase = .welcome(hasBackup: backupStore.backupExists())
        }
    }

    /// Fetch envelope from iCloud → authenticate with whichever key
    /// provider sealed it → decrypt → rebuild the deterministic wallet →
    /// rescan.
    func restoreWallet() async {
        do {
            phase = .working("Restoring from iCloud…")
            let envelope = try await backupStore.load()

            let keyMaterial = try await keyMaterialForRestore(of: envelope)
            sessionKey = (keyMaterial, envelope.keyProvider)
            let secrets = try BackupCrypto.open(envelope, inputKeyMaterial: keyMaterial)

            let storageDir = Self.walletStorageDirectory()
            let cacheKey = chain.esploraURL.host ?? ""
            let engine = try await Self.offMain {
                try WalletEngine(secrets: secrets, storageDirectory: storageDir, cacheDiscriminator: cacheKey)
            }
            self.engine = engine
            self.secrets = secrets
            backupInICloud = backupStore.isUsingICloud

            phase = .ready
            await refresh(fullScan: true)
        } catch {
            report(error)
            phase = .welcome(hasBackup: backupStore.backupExists())
        }
    }

    // MARK: - Chain state

    func refresh(fullScan: Bool = false) async {
        guard let engine, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        let esplora = chain.esploraURL
        do {
            try await Self.offMain { try engine.sync(esploraURL: esplora, fullScan: fullScan) }
        } catch {
            // Sync failures are non-fatal: show cached state plus a notice.
            report(error)
        }
        balance = engine.balance()
        transactions = engine.transactions()
        feeTiers = await feeEstimator.tiers(esploraURL: chain.esploraURL, feesURL: chain.feesURL)
        usdPerBTC = await priceOracle.usdPerBTC() ?? usdPerBTC
    }

    /// "≈ $12.34" for display, or nil when the rate is unknown.
    func usdApprox(_ sats: UInt64) -> String? {
        guard let usdPerBTC, sats > 0 else { return nil }
        return "≈ " + PriceOracle.usdString(sats: sats, usdPerBTC: usdPerBTC)
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
        let esplora = chain.esploraURL
        let newTxid = try await Self.offMain {
            let bumped = try engine.createFeeBump(txid: txid, feeRateSatPerVb: rate)
            return try engine.broadcast(bumped, esploraURL: esplora)
        }
        await refresh()
        return newTxid
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
        switch sessionKey?.provider {
        case "passkey-prf": return "Passkey (Face ID)"
        default: return "iCloud Keychain + Face ID"
        }
    }

    func broadcast(_ send: SignedSend) async throws -> String {
        guard let engine else { throw WalletKitError.internalError("wallet not ready") }
        let esplora = chain.esploraURL
        let txid = try await Self.offMain { try engine.broadcast(send, esploraURL: esplora) }
        await refresh()
        return txid
    }

    // MARK: - Key providers

    /// New wallets prefer the passkey-PRF provider (iOS 18+): registration
    /// shows its own Face ID sheet and the PRF output becomes the key. If
    /// that fails at runtime (domain/AASA not reachable, unsupported, user
    /// declined the passkey), fall back to the synced-keychain provider
    /// gated by an LAContext Face ID prompt — ADR 0002.
    private func establishKeyForNewWallet() async throws -> (material: Data, provider: String) {
        // Simulators can't validate associated domains, so the passkey
        // attempt always fails there — skip it instead of flashing doomed
        // system sheets that race the fallback Face ID prompt.
        #if !targetEnvironment(simulator)
            if #available(iOS 18.0, *) {
                let prf = PasskeyPRFKeyProvider(anchor: presentationAnchor)
                if let material = try? await prf.keyMaterial() {
                    return (material, prf.identifier)
                }
                // The failed passkey sheet needs to finish tearing down
                // before LAContext presents, or the prompt gets
                // system-canceled underneath us.
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        #endif
        try await faceID.authenticate(reason: "Create your Bitcoin wallet")
        return (try await keychainProvider.keyMaterial(), keychainProvider.identifier)
    }

    /// Restore must use the provider recorded in the envelope: a passkey
    /// assertion for "passkey-prf" (which *is* the Face ID gate), or
    /// LAContext + the synced keychain key otherwise.
    private func keyMaterialForRestore(of envelope: BackupEnvelope) async throws -> Data {
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
            try await faceID.authenticate(reason: "Unlock your Bitcoin wallet")
            guard let material = try await keychainProvider.existingKeyMaterial() else {
                throw WalletKitError.keyUnavailable(
                    "Backup key hasn't synced to this device yet. Make sure iCloud Keychain is on, then try again."
                )
            }
            return material
        }
    }

    // MARK: - Backup

    /// Reseals the backup with current index hints. Called after wallet
    /// creation and whenever new addresses are revealed. Uses the
    /// session-cached key so it never re-prompts the user.
    private func persistBackup() async throws {
        guard let engine, var secrets, let sessionKey else { return }
        let indexes = engine.revealedIndexes()
        secrets.receiveIndexHint = indexes.receive
        secrets.changeIndexHint = indexes.change
        self.secrets = secrets

        let envelope = try BackupCrypto.seal(
            secrets,
            inputKeyMaterial: sessionKey.material,
            keyProvider: sessionKey.provider
        )
        try backupStore.save(envelope)
        backupInICloud = backupStore.isUsingICloud
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
