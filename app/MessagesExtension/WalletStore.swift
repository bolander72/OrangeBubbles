import AuthenticationServices
import Foundation
import WalletKit
import WidgetKit

/// App-layer state machine implementing the auto-wallet model (ADR 0004):
/// opening OrangeBubbles silently creates or restores the wallet — no ceremony,
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
    /// True when the most recent sync attempt failed; balance shown is cached.
    @Published var syncStale = false
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

    /// Which provider sealed the cloud envelope. Lives in the App Group so
    /// the HOST APP's passkey upgrade (see HostApp/PasskeyOps) is visible
    /// here immediately, and silent reseals never downgrade it.
    private static let backupProviderKey = "backupKeyProvider.v1"
    private var knownBackupProvider: String? {
        get { UserDefaults(suiteName: SharedSnapshot.appGroupID)?.string(forKey: Self.backupProviderKey) }
        set { UserDefaults(suiteName: SharedSnapshot.appGroupID)?.set(newValue, forKey: Self.backupProviderKey) }
    }

    init(chain: ChainConfig = .fromBundle()) {
        self.chain = chain
    }

    // MARK: - Lifecycle (auto-wallet)

    func start() async {
        guard !started else {
            if engine != nil { await refresh(quiet: true) }
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
    /// The one network sync allowed at a time. A refresh that times out
    /// leaves its BDK sync running (it can't be cancelled); starting another
    /// on top only deepens a rate-limit hole, so later refreshes join this
    /// one instead.
    private var syncInFlight: Task<Void, Error>?
    /// Index of the Esplora endpoint that last answered; failover starts
    /// there instead of re-trying a throttled primary on every call.
    private var preferredEsploraIndex = 0
    /// Endpoints that answered 429, and when they may be tried again.
    private var endpointCooldownUntil: [Int: Date] = [:]

    // MARK: - Request budget
    //
    // The app has no backend: every request goes to a public Esplora, and
    // those are rate-limited per IP (blockstream.info: 700/hour). A BDK
    // incremental sync costs about one request per revealed script pubkey
    // (`engine.watchedScriptPubkeyCount`, dozens after a few sessions), so
    // syncing every 12 s was thousands of requests an hour. Instead:
    //
    //   • A full BDK sync runs on open, after our own broadcasts, on
    //     pull-to-refresh, and otherwise only every `fullSyncInterval`.
    //   • Between those, each tick *probes* only what can change right
    //     now — receive addresses shown in the last few minutes and our
    //     unconfirmed txids — one request each, and triggers a sync only
    //     when a probe sees something new. Nothing to watch → no request.
    //   • Ticks come every 20 s while something is pending, 60 s otherwise.
    //
    // Idle cost is a few dozen requests an hour; with a payment pending it
    // stays in the low hundreds, and a payment to a just-shown address
    // still shows up within one tick.

    private var lastFullSyncAt: Date?
    /// A wallet whose cache was just created knows no history until a full
    /// scan succeeds; incremental syncs of the few revealed addresses would
    /// never find it. Set on an empty cache and on restore, cleared by the
    /// first successful full scan.
    private var needsFullScan = false
    /// When a full sync was last *started* — a failing sync must not be
    /// retried every tick (each one costs a request per watched address).
    private var lastFullSyncAttemptAt: Date?
    private var lastSideDataAt: Date?
    /// Receive addresses handed out recently, with when they were shown.
    private var recentlyShownAddresses: [(address: String, shownAt: Date)] = []
    /// Last probe result per address/txid, so a tick can tell "changed".
    private var probeFingerprints: [String: String] = [:]

    private static let recentAddressWindow: TimeInterval = 10 * 60
    private static let pendingTick: UInt64 = 20_000_000_000
    private static let idleTick: UInt64 = 60_000_000_000
    private static let fullSyncIntervalPending: TimeInterval = 5 * 60
    private static let fullSyncIntervalIdle: TimeInterval = 15 * 60
    private static let failedSyncRetryInterval: TimeInterval = 2 * 60
    private static let sideDataInterval: TimeInterval = 2 * 60

    private var recentAddresses: [String] {
        let cutoff = Date().addingTimeInterval(-Self.recentAddressWindow)
        return recentlyShownAddresses.filter { $0.shownAt > cutoff }.map(\.address)
    }

    private var unconfirmedTxids: [String] {
        transactions.filter { !$0.confirmed }.map(\.txid)
    }

    /// Something on screen can change from one tick to the next.
    private var hasPendingActivity: Bool {
        !recentAddresses.isEmpty || !unconfirmedTxids.isEmpty
    }

    /// Keeps the chain view current while the extension is on screen, at
    /// the lowest request cost that still makes a payment to a just-shown
    /// address appear within a tick (see "Request budget" above). Started
    /// on willBecomeActive, stopped on willResignActive — never runs in
    /// the background (extensions don't have one).
    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                let pending = await self?.hasPendingActivity ?? false
                try? await Task.sleep(nanoseconds: pending ? Self.pendingTick : Self.idleTick)
                guard !Task.isCancelled else { break }
                await self?.tick()
            }
        }
    }

    /// One auto-refresh tick: a full sync when one is due, otherwise a
    /// cheap probe that escalates to a sync only on change. Always quiet.
    private func tick() async {
        guard engine != nil, !isSyncing else { return }
        let interval = hasPendingActivity ? Self.fullSyncIntervalPending : Self.fullSyncIntervalIdle
        let now = Date()
        let syncedRecently = lastFullSyncAt.map { now.timeIntervalSince($0) < interval } ?? false
        let triedRecently = lastFullSyncAttemptAt.map { now.timeIntervalSince($0) < Self.failedSyncRetryInterval } ?? false
        if syncedRecently || triedRecently {
            if await probeSawChange() { await refresh(quiet: true) }
        } else {
            await refresh(quiet: true)
        }
    }

    /// Asks the endpoint about the handful of things that can change
    /// between full syncs. One request per item; none when there is
    /// nothing to watch. Any failure reads as "no change" — the next full
    /// sync is never more than `fullSyncInterval` away.
    private func probeSawChange() async -> Bool {
        let addresses = recentAddresses
        let txids = unconfirmedTxids
        guard !addresses.isEmpty || !txids.isEmpty else { return false }
        NSLog("wallet probe: addresses=%d txids=%d", addresses.count, txids.count)
        let probe = StatusProbe()
        var changed = false
        for address in addresses {
            guard let activity = try? await withEsploraFailover(perEndpointSeconds: 8, { esplora in
                try await probe.addressActivity(address: address, esploraURL: esplora)
            }) else { continue }
            let fingerprint = "\(activity.confirmedReceivedSats)/\(activity.mempoolReceivedSats)/\(activity.spentSats)"
            if let previous = probeFingerprints[address], previous != fingerprint { changed = true }
            if probeFingerprints[address] == nil, activity.hasAny { changed = true }
            probeFingerprints[address] = fingerprint
        }
        for txid in txids where !changed {
            guard let status = try? await withEsploraFailover(perEndpointSeconds: 8, { esplora in
                try await probe.txConfirmation(txid: txid, esploraURL: esplora)
            }) else { continue }
            if status.confirmed { changed = true }
        }
        return changed
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
                if let engine, engine.unusedReceiveAddressCount > Self.runawayRevealThreshold {
                    // Don't spend a 300-request sync on a cache we are about
                    // to replace; the rebuilt one syncs itself when ready.
                    Task { await repairRunawayReveals() }
                } else if let engine, engine.startedFromEmptyCache {
                    // Secrets without a chain cache (cache deleted, or a new
                    // Esplora host): only a full scan finds the history.
                    needsFullScan = true
                    await refresh(fullScan: true, quiet: true)
                } else {
                    // Opening the app is not a request to talk to the
                    // network: a slow endpoint shows the cached balance plus
                    // the stale marker, never a modal. Pull-to-refresh stays
                    // loud.
                    await refresh(quiet: true)
                }
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
                needsFullScan = true
                await refresh(fullScan: true)
            } else {
                phase = .working("Setting things up…")
                // Silent creation: random seed, sealed with the synced
                // keychain key. Passkey protection is an explicit upgrade
                // in Settings (its registration sheet can't be silent).
                let material = try await keychainProvider.keyMaterial()
                sessionKey = (material, keychainProvider.identifier)
                let fresh = try WalletEngine.generateSecrets(network: chain.network)
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
        let cacheKey = cacheDiscriminator(generation: chainCacheGeneration)
        let engine = try await Self.offMain {
            try WalletEngine(secrets: secrets, storageDirectory: storageDir, cacheDiscriminator: cacheKey)
        }
        self.engine = engine
        self.secrets = secrets
    }

    // MARK: - Chain cache generations

    /// The chain cache file is named by endpoint host plus a generation
    /// number; bumping the generation is how a cache gets rebuilt without
    /// ever deleting the one the UI is currently showing.
    private static let chainCacheGenerationKey = "chainCacheGeneration.v1"
    private var chainCacheGeneration: Int {
        get { max(1, UserDefaults.standard.integer(forKey: Self.chainCacheGenerationKey)) }
        set { UserDefaults.standard.set(newValue, forKey: Self.chainCacheGenerationKey) }
    }

    private func cacheDiscriminator(generation: Int) -> String {
        let host = chain.esploraURL.host ?? ""
        return generation <= 1 ? host : "\(host)-g\(generation)"
    }

    /// More revealed-but-unused receive addresses than this means a cache
    /// poisoned by the old runaway reveal (BIP44's gap is 20).
    private static let runawayRevealThreshold = 60

    /// One-time repair for caches poisoned by the old runaway address
    /// reveal (three fresh addresses per refresh, forever): with hundreds of
    /// revealed-but-unused addresses, every sync was hundreds of requests —
    /// the reason public Esploras started answering 429.
    ///
    /// Builds a fresh cache under the next generation with a full scan
    /// (which reveals only what was used plus the normal gap), and only
    /// once that succeeds swaps it in and deletes the old one. The UI keeps
    /// showing the old cache meanwhile; on failure nothing changes and the
    /// next launch tries again.
    private func repairRunawayReveals() async {
        guard let secrets, let old = engine else { return }
        let oldGeneration = chainCacheGeneration
        let newGeneration = oldGeneration + 1
        let storageDir = Self.walletStorageDirectory()
        let newKey = cacheDiscriminator(generation: newGeneration)
        let oldKey = cacheDiscriminator(generation: oldGeneration)
        NSLog("wallet repair: %d unused revealed addresses — rebuilding chain cache as generation %d",
              old.unusedReceiveAddressCount, newGeneration)

        var trimmed = secrets
        trimmed.receiveIndexHint = 0
        trimmed.changeIndexHint = 0
        do {
            let fresh = try await Self.offMain {
                try WalletEngine(secrets: trimmed, storageDirectory: storageDir, cacheDiscriminator: newKey)
            }
            // A full scan on a throttled endpoint can be slow; this is a
            // background job, so give it real time before giving up.
            try await withTimeout(seconds: 180) {
                try await self.withEsploraFailover(perEndpointSeconds: 150) { esplora in
                    try await Self.offMain { try fresh.sync(esploraURL: esplora, fullScan: true) }
                }
            }
            _ = try? await Self.offMain { try fresh.revealUpcomingReceiveAddresses(count: 3) }

            // Swap. Anything still running against the old engine finishes
            // on its own; the UI reads from `engine` from here on.
            chainCacheGeneration = newGeneration
            engine = fresh
            self.secrets = trimmed
            balance = fresh.balance()
            transactions = fresh.transactions()
            lastFullSyncAt = Date()
            syncStale = false
            probeFingerprints.removeAll()
            publishSnapshot()
            try? await persistBackup() // sane index hints from now on
            try? await Self.offMain {
                WalletEngine.removeChainCache(storageDirectory: storageDir, network: secrets.network, cacheDiscriminator: oldKey)
            }
            NSLog("wallet repair: done — now watching %d script pubkeys", fresh.watchedScriptPubkeyCount)
        } catch {
            NSLog("wallet repair: deferred (%@)", String(describing: error))
            try? await Self.offMain {
                WalletEngine.removeChainCache(storageDirectory: storageDir, network: secrets.network, cacheDiscriminator: newKey)
            }
            await refresh(quiet: true)
        }
    }

    /// Key material for a restore, honoring the envelope's provider:
    /// synced keychain reads silently; a passkey-sealed backup requires an
    /// assertion (that's its whole point — one Face ID on a new device).
    private func keyMaterial(for envelope: BackupEnvelope) async throws -> Data {
        switch envelope.keyProvider {
        case "passkey-prf":
            // Passkey ceremonies can't run inside a Messages extension
            // (WebAuthn association check fails in appex context) — the
            // host app performs the unlock and shares the result.
            throw WalletKitError.keyUnavailable(
                "This backup is protected by a passkey. Open the OrangeBubbles app from your Home Screen, tap \"Unlock wallet with passkey\", then come back here."
            )
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

    /// `quiet` suppresses the error alert on sync failure — used by the
    /// auto-refresh loop, where the cached state simply stays on screen and
    /// `syncStale` lets the UI hint that it is not live.
    func refresh(fullScan requestedFullScan: Bool = false, quiet: Bool = false) async {
        guard let engine, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let fullScan = requestedFullScan || needsFullScan

        // Show what we already know before touching the network: the BDK
        // cache has the last balance and history, and a slow or hung
        // endpoint must not leave Home on "0 sats / No activity yet".
        if !hasLoadedOnce {
            balance = engine.balance()
            transactions = engine.transactions()
        }

        do {
            if syncInFlight == nil || fullScan {
                NSLog("wallet sync: full=%d spks=%d", fullScan ? 1 : 0, engine.watchedScriptPubkeyCount)
                lastFullSyncAttemptAt = Date()
                let sync = Task {
                    try await self.withEsploraFailover { esplora in
                        try await Self.offMain { try engine.sync(esploraURL: esplora, fullScan: fullScan) }
                    }
                }
                syncInFlight = sync
                Task { _ = try? await sync.value; if self.syncInFlight == sync { self.syncInFlight = nil } }
            }
            let sync = syncInFlight!
            try await withTimeout(seconds: 25) { try await sync.value }
            syncStale = false
            lastFullSyncAt = Date()
            if fullScan { needsFullScan = false }
            // A fresh sync supersedes whatever the probes remembered.
            probeFingerprints.removeAll()
        } catch {
            // Sync failures/timeouts are non-fatal: show cached state. The
            // isSyncing flag ALWAYS clears (defer), so the spinner can't wedge.
            syncStale = true
            if !quiet { report(error) }
        }
        let previousTotal = balance.totalSats
        balance = engine.balance()
        transactions = engine.transactions()
        // Side data: fetched together so a slow fee endpoint doesn't delay
        // the price (both bounded by BoundedSession), and at most every
        // couple of minutes — fee tiers and the rate don't move faster.
        if lastSideDataAt.map({ Date().timeIntervalSince($0) > Self.sideDataInterval }) ?? true {
            let preferredEsplora = chain.esploraURLs[preferredEsploraIndex]
            async let tiersFetch = feeEstimator.tiers(esploraURL: preferredEsplora, feesURL: chain.feesURL)
            async let priceFetch = priceOracle.usdPerBTC()
            feeTiers = await tiersFetch
            usdPerBTC = await priceFetch ?? usdPerBTC
            lastSideDataAt = Date()
        }

        // Keep the handed-out (Siri/widget) addresses revealed & backed
        // up — before publishing, so the snapshot is never stale.
        let before = engine.revealedIndexes().receive
        upcomingAddresses = (try? await Self.offMain { try engine.revealUpcomingReceiveAddresses(count: 3) }) ?? []
        if engine.revealedIndexes().receive != before {
            try? await persistBackup()
        }
        publishSnapshot()

        // Money arriving while you watch deserves a buzz.
        if hasLoadedOnce, balance.totalSats > previousTotal {
            Haptics.success()
        }
        hasLoadedOnce = true
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
        // Watch it closely for a while: this is the address most likely to
        // receive something in the next few minutes.
        recentlyShownAddresses.append((next.address, Date()))
        recentlyShownAddresses.removeAll { Date().timeIntervalSince($0.shownAt) > Self.recentAddressWindow }
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
        let newTxid = try await withTimeout(seconds: 30) {
            try await self.withEsploraFailover { esplora in
                try await Self.offMain { try engine.broadcast(bumped, esploraURL: esplora) }
            }
        }
        settleAfterChainWrite()
        return newTxid
    }

    func broadcast(_ send: SignedSend) async throws -> String {
        guard let engine else { throw WalletKitError.internalError("wallet not ready") }
        let txid = try await withTimeout(seconds: 30) {
            try await self.withEsploraFailover { esplora in
                try await Self.offMain { try engine.broadcast(send, esploraURL: esplora) }
            }
        }
        recordPaidAddress(send.details.destinationAddress)
        settleAfterChainWrite()
        return txid
    }

    /// After a broadcast or sweep succeeded: show the engine's view of the
    /// result right away (the engine already recorded the spend locally),
    /// and let the network catch up in the background. The success screen
    /// must never wait on a slow endpoint, and a flaky follow-up sync is
    /// not the action's error.
    private func settleAfterChainWrite() {
        if let engine {
            balance = engine.balance()
            transactions = engine.transactions()
            publishSnapshot()
        }
        Task { await self.refresh(quiet: true) }
    }

    /// Runs `operation` against each same-chain Esplora endpoint in order,
    /// moving on only for connectivity failures (rate limits, outages) —
    /// including an endpoint that simply never answers, which is what a
    /// throttled public Esplora looks like from here. Starts from the
    /// endpoint that last worked. Any other error is the operation's own
    /// problem and surfaces as-is.
    private func withEsploraFailover<T: Sendable>(
        perEndpointSeconds: Double = 15,
        _ operation: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        let urls = chain.esploraURLs
        let now = Date()
        var order = Array(urls.indices).map { ($0 + preferredEsploraIndex) % urls.count }
        // Endpoints that recently answered 429 go last — but are never
        // skipped outright, in case every endpoint is cooling down.
        order.sort { (endpointCooldownUntil[$0] ?? .distantPast) < (endpointCooldownUntil[$1] ?? .distantPast) }
        let allCooling = order.allSatisfy { (endpointCooldownUntil[$0] ?? .distantPast) > now }
        var lastError: WalletKitError = .networkUnreachable
        for (position, index) in order.enumerated() {
            if !allCooling, (endpointCooldownUntil[index] ?? .distantPast) > now { continue }
            let url = urls[index]
            do {
                let result = try await withTimeout(seconds: perEndpointSeconds) { try await operation(url) }
                preferredEsploraIndex = index
                endpointCooldownUntil[index] = nil
                return result
            } catch let error as WalletKitError {
                switch error {
                case .rateLimited:
                    endpointCooldownUntil[index] = now.addingTimeInterval(5 * 60)
                    lastError = error
                case .networkUnreachable:
                    lastError = error
                default:
                    throw error
                }
                if position == order.count - 1 { throw lastError }
            }
        }
        throw lastError
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
        settleAfterChainWrite()
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

    /// The upgrade itself runs in the HOST APP (PasskeyOps) — Messages
    /// extensions can't perform WebAuthn ceremonies. Settings hands off.
    func refreshProviderFromGroup() {
        objectWillChange.send() // backupKeyProviderName reads group defaults
    }

    #if DEBUG
        /// Dev-only: erase every trace of the current wallet (local cache,
        /// iCloud envelopes, provider flag, gift ledger, chain cache) and
        /// auto-create a fresh one. The synced keychain key and any passkey
        /// are kept — they're reusable key material, not wallet identity.
        func debugWipeAndRecreate() async {
            phase = .working("Wiping wallet…")
            engine = nil
            secrets = nil
            sessionKey = nil
            localSecrets.clear()
            let store = backupStore
            _ = try? await Self.offMain { store.eraseAll() }
            knownBackupProvider = nil
            outstandingGifts = []
            saveGifts()
            try? FileManager.default.removeItem(at: Self.walletStorageDirectory())
            balance = WalletBalance(confirmedSats: 0, pendingSats: 0)
            transactions = []
            hasLoadedOnce = false
            await bootstrap()
        }
    #endif

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
        // The host app may have upgraded the envelope to passkey-prf while
        // this session still holds the old keychain key — never downgrade.
        if knownBackupProvider == "passkey-prf", sessionKey.provider != "passkey-prf" {
            self.sessionKey = nil
            return
        }

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

    /// Runs `op` but throws if it exceeds `seconds` — guarantees refresh()
    /// completes so the syncing indicator never gets stuck on a hung call.
    ///
    /// Deliberately NOT a task group: a group waits for every child before
    /// it returns, and the child here is awaiting a blocking BDK/Esplora
    /// call that can't be cancelled — so a group-based timeout "fired" but
    /// never actually returned. This races a continuation instead; the
    /// orphaned work finishes (or fails) on its own in the background.
    private nonisolated func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let once = ResumeOnce(continuation)
            let work = Task {
                do { once.resume(.success(try await op())) } catch { once.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(.failure(WalletKitError.networkUnreachable))
                work.cancel()
            }
        }
    }

    private nonisolated static func offMain<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }
}

/// Resumes a continuation at most once, whichever racer gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
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
