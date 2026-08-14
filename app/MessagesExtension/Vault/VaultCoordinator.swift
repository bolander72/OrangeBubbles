import Foundation
import SwiftUI
import WalletKit

/// Drives one device's participation in a shared vault: DKG to establish
/// the key, then propose/approve/broadcast for spends — all over a
/// `VaultTransport`. Polls the transport for peers' messages. Observable
/// so the debug Vault Lab UI reflects live state.
@MainActor
final class VaultCoordinator: ObservableObject {
    struct Config {
        let vaultID: String
        let name: String
        let memberIndex: UInt16
        let memberCount: UInt16
        let threshold: UInt16
        var emoji: String? = nil
    }

    enum Stage: Equatable {
        case idle
        case dkgInProgress(String)
        case ready                    // vault key established
        case error(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var vaultAddress: String?
    @Published private(set) var balanceSats: UInt64 = 0
    @Published private(set) var log: [String] = []
    @Published private(set) var pendingProposal: Proposal?
    @Published private(set) var spendStatus: SpendStatus = .none
    /// Which member slots have joined this pot (anonymous — no names). Used
    /// only for the "x of n joined" status; the real people are shown by
    /// iMessage itself in the chat.
    @Published private(set) var joined: Set<UInt16> = []
    /// Plain-language, user-facing activity — never the crypto plumbing.
    @Published private(set) var activity: [String] = []
    /// Test runners set this so a headless member auto-signs proposals.
    var autoApprove = false

    enum SpendStatus: Equatable {
        case none
        case proposing
        case awaitingSignatures(have: Int, need: Int)
        case broadcasting
        case done(txid: String)
        case failed(String)
    }

    let config: Config
    private let transport: VaultTransport
    private let chain: ChainConfig
    private let identity: FrostMemberIdentity
    private let mnemonic: String

    private var dkg: FrostDKGSession?
    private var vaultKeyHex: String?
    private var publicKeyPackage: String?
    private var keyPackage: String?
    private var pollTask: Task<Void, Never>?
    /// Identity-based dedup (kind:sender:proposalID) — order-independent, unlike
    /// a running count, so it survives resume over CloudKit (whose fetch order
    /// isn't stable). A message is processed at most once.
    private var seenKeys: Set<String> = []

    /// Called when DKG completes so the caller can persist the vault.
    var onVaultReady: ((VaultRecord) -> Void)?
    /// Fired after every DKG state change with (encoded session, seen keys) so
    /// the caller can persist the in-progress ceremony. Persisted together with
    /// seenKeys AFTER the response is posted, so a crash mid-round resumes from a
    /// consistent snapshot (re-feeding an unseen round re-derives it — the DKG
    /// round messages are deterministic, so re-posting is idempotent).
    var onDKGProgress: ((Data, [String]) -> Void)?

    private func persistDKG() {
        guard let dkg, let data = try? JSONEncoder().encode(dkg) else { return }
        onDKGProgress?(data, Array(seenKeys))
    }

    init(config: Config, transport: VaultTransport, chain: ChainConfig, mnemonic: String) throws {
        self.config = config
        self.transport = transport
        self.chain = chain
        self.mnemonic = mnemonic
        self.identity = try FrostMemberIdentity(index: config.memberIndex, mnemonic: mnemonic)
    }

    /// Resume an already-established vault (no DKG): load key material and
    /// go straight to ready, then poll for spend proposals.
    init(resuming record: VaultRecord, transport: VaultTransport, chain: ChainConfig, mnemonic: String) throws {
        self.config = Config(vaultID: record.vaultID, name: record.name,
                             memberIndex: record.memberIndex, memberCount: record.memberCount,
                             threshold: record.threshold, emoji: record.emoji)
        self.transport = transport
        self.chain = chain
        self.mnemonic = mnemonic
        self.identity = try FrostMemberIdentity(index: record.memberIndex, mnemonic: mnemonic)
        self.vaultKeyHex = record.vaultXonlyHex
        self.publicKeyPackage = record.publicKeyPackage
        self.keyPackage = record.keyPackage
        self.vaultAddress = record.address
        self.stage = .ready
    }

    /// Resume an in-progress DKG (not yet complete): restore the persisted
    /// session + which rounds we've already folded in, then keep going over the
    /// transport. Lets a member close the app mid-setup and finish on reopen.
    init(resumingDKG config: Config, sessionData: Data, seenKeys: [String],
         transport: VaultTransport, chain: ChainConfig, mnemonic: String) throws {
        self.config = config
        self.transport = transport
        self.chain = chain
        self.mnemonic = mnemonic
        self.identity = try FrostMemberIdentity(index: config.memberIndex, mnemonic: mnemonic)
        self.dkg = try JSONDecoder().decode(FrostDKGSession.self, from: sessionData)
        self.seenKeys = Set(seenKeys)
        self.joined.insert(config.memberIndex)
        self.stage = .dkgInProgress("Finishing setup…")
    }

    /// Start participating for a resumed vault: begin polling for proposals.
    func resume() async {
        joined.insert(config.memberIndex)
        startPolling()
        try? await post(.announce, ["index": Int(config.memberIndex)])
        await refreshBalance()
    }

    /// Continue an in-progress DKG (paired with `init(resumingDKG:)`). Re-posts
    /// our own round-1 (deterministic → idempotent) in case it never reached the
    /// transport before we closed, then polls to finish.
    func resumeDKG() async {
        guard let dkg else { stage = .error("Lost setup state"); return }
        try? await post(.announce, ["index": Int(config.memberIndex)])
        try? await post(.dkgRound1, encode(dkg.round1Message()))
        startPolling()
    }

    // MARK: - DKG

    func start() async {
        do {
            note("Joining vault as member \(config.memberIndex) of \(config.memberCount)")
            let session = try FrostDKGSession(
                vaultID: config.vaultID, identity: identity,
                memberCount: config.memberCount, threshold: config.threshold)
            self.dkg = session
            stage = .dkgInProgress("Announcing…")
            joined.insert(config.memberIndex)

            try await post(.announce, ["index": Int(config.memberIndex)])
            // Broadcast our round-1 package.
            let r1 = session.round1Message()
            try await post(.dkgRound1, encode(r1))
            persistDKG()
            startPolling()
        } catch {
            stage = .error(error.localizedDescription)
        }
    }

    private func handle(_ kind: VaultMessageKind, _ payload: [String: Any]) async {
        do {
            switch kind {
            case .dkgRound1:
                guard let session = dkg else { return }
                let msg: FrostDKGSession.Round1Message = try decode(payload)
                if let r2 = try session.receiveRound1(msg, identity: identity) {
                    stage = .dkgInProgress("Exchanging shares…")
                    try await post(.dkgRound2, encode(r2))
                }
                persistDKG()   // session consumed a round-1 + posted our round-2
            case .dkgRound2:
                guard let session = dkg else { return }
                let msg: FrostDKGSession.Round2Message = try decode(payload)
                let done = try session.receiveRound2(msg, identity: identity)
                persistDKG()
                if done { try finishDKG() }
            case .spendProposal:
                let p: Proposal = try decode(payload)
                resetSpendState()
                spendStatus = .proposing
                pendingProposal = p
                event("Someone asked to spend \(Self.sats(p.amountSats))")
                if autoApprove { await approve(p) }
            case .spendCommit:
                try await collectCommit(decode(payload))
            case .spendSigningSet:
                try await receiveSigningSet(decode(payload))
            case .spendPartial:
                try await collectPartial(decode(payload))
            case .spendBroadcast:
                if let txid = payload["txid"] as? String {
                    event("Sent ✓")
                    spendStatus = .done(txid: txid)
                    pendingProposal = nil
                    let keep = spendStatus
                    resetSpendState()
                    spendStatus = keep
                    await refreshBalance()
                }
            case .announce:
                if let idx = payload["index"] as? Int { joined.insert(UInt16(idx)) }
            }
        } catch {
            note("⚠️ \(error.localizedDescription)")
        }
    }

    private func finishDKG() throws {
        guard let session = dkg, let key = session.vaultXonlyHex,
              let pub = session.publicKeyPackage, let kp = session.keyPackage else { return }
        vaultKeyHex = key
        publicKeyPackage = pub
        keyPackage = kp
        let engine = FrostVaultEngine(vaultXonlyHex: key, network: chain.network)
        let addr = try engine.address()
        vaultAddress = addr
        stage = .ready
        event("Pot is ready 🎉")
        onVaultReady?(VaultRecord(
            vaultID: config.vaultID, name: config.name, memberIndex: config.memberIndex,
            memberCount: config.memberCount, threshold: config.threshold,
            keyPackage: kp, publicKeyPackage: pub, vaultXonlyHex: key, address: addr,
            emoji: config.emoji, relayHost: nil, createdAt: Date()))
        Task { await refreshBalance() }
    }

    // MARK: - Spend
    //
    // Correct FROST coordination (ADR 0008): every signer must sign
    // against ONE canonical commitment set, and the aggregator must
    // combine partials from exactly that set. So:
    //   1. proposer posts the proposal; members commit nonces (round 1)
    //      but DO NOT sign yet.
    //   2. the proposer collects commits, freezes a canonical signer set
    //      of exactly k members, and broadcasts it (indices + commitments).
    //   3. only members in that set sign — against the exact commitments —
    //      and post partials.
    //   4. the proposer aggregates the k partials and broadcasts.

    private var isProposer = false
    private var signing: FrostSigningSession?
    private var currentPlan: FrostVaultEngine.SpendPlan?
    private var commitsByIndex: [UInt16: [String]] = [:]
    private var partialsByIndex: [UInt16: [String]] = [:]
    private var canonicalSigners: [UInt16]?
    private var canonicalCommitments: [[UInt16: String]]?
    private var didBroadcast = false

    struct Proposal: Codable, Equatable {
        let proposalID: String
        let destination: String
        let amountSats: UInt64
        let feeSats: UInt64
        let unsignedTxHex: String
        let sighashes: [String]
    }

    func proposeSpend(to destination: String, amountSats: UInt64?, feeSats: UInt64 = 400) async {
        guard let key = vaultKeyHex else { return }
        guard pendingProposal == nil else { note("A spend is already in progress"); return }
        spendStatus = .proposing
        do {
            note("Building spend…")
            resetSpendState()
            isProposer = true
            let engine = FrostVaultEngine(vaultXonlyHex: key, network: chain.network)
            let plan = try await engine.planSpend(to: destination, amountSats: amountSats, feeSats: feeSats, esploraURL: chain.esploraURL)
            let proposal = Proposal(
                proposalID: UUID().uuidString, destination: destination,
                amountSats: amountSats ?? balanceSats, feeSats: feeSats,
                unsignedTxHex: plan.unsignedTxHex, sighashes: plan.sighashes)
            currentPlan = plan
            pendingProposal = proposal
            spendStatus = .awaitingSignatures(have: 0, need: Int(config.threshold))
            event("You asked to spend \(Self.sats(proposal.amountSats))")
            try await post(.spendProposal, encode(proposal))
            await approve(proposal) // proposer commits too
        } catch {
            spendStatus = .failed(friendlyError(error))
            event("Couldn't send — \(friendlyError(error))")
        }
    }

    /// Commit nonces (round 1) for the proposal. Does NOT sign yet — signing
    /// waits for the proposer's canonical signer set.
    func approve(_ proposal: Proposal) async {
        guard let kp = keyPackage else { return }
        do {
            let session = FrostSigningSession(
                vaultID: config.vaultID, proposalID: proposal.proposalID,
                selfIndex: config.memberIndex, keyPackage: kp, sighashes: proposal.sighashes)
            signing = session
            let commitments = try session.commitments()
            commitsByIndex[config.memberIndex] = commitments
            if !isProposer {
                spendStatus = .awaitingSignatures(have: 0, need: Int(config.threshold))
                event("You approved this spend")
            }
            try await post(.spendCommit, ["proposalID": proposal.proposalID, "index": Int(config.memberIndex), "commitments": commitments])
            note("Committed nonces")
        } catch {
            spendStatus = .failed(friendlyError(error))
            note("⚠️ approve failed: \(error.localizedDescription)")
        }
    }

    /// Proposer only: collect commits, then freeze + broadcast the set.
    private func collectCommit(_ payload: CommitMsg) async throws {
        guard let proposal = pendingProposal, payload.proposalID == proposal.proposalID else { return }
        commitsByIndex[payload.index] = payload.commitments
        guard isProposer, canonicalSigners == nil,
              commitsByIndex.count >= Int(config.threshold) else { return }

        let signers = Array(commitsByIndex.keys.sorted().prefix(Int(config.threshold)))
        let inputs = proposal.sighashes.count
        var comm: [[UInt16: String]] = Array(repeating: [:], count: inputs)
        for idx in signers { for i in 0..<inputs { comm[i][idx] = commitsByIndex[idx]![i] } }
        canonicalSigners = signers
        canonicalCommitments = comm
        note("Signer set fixed: \(signers.map(String.init).joined(separator: ","))")
        try await post(.spendSigningSet, [
            "proposalID": proposal.proposalID,
            "signers": signers.map(Int.init),
            "commitments": comm.map { $0.reduce(into: [String: [String]]()) { $0[String($1.key)] = [$1.value] } },
        ])
        try await signIfChosen()
    }

    /// Any member: on receiving the canonical set, sign if we're in it.
    private func receiveSigningSet(_ msg: SigningSetMsg) async throws {
        guard let proposal = pendingProposal, msg.proposalID == proposal.proposalID,
              canonicalSigners == nil else { return }
        canonicalSigners = msg.signers
        var comm: [[UInt16: String]] = Array(repeating: [:], count: msg.commitments.count)
        for (i, perInput) in msg.commitments.enumerated() {
            for (k, v) in perInput { if let idx = UInt16(k), let c = v.first { comm[i][idx] = c } }
        }
        canonicalCommitments = comm
        try await signIfChosen()
    }

    private func signIfChosen() async throws {
        guard let signers = canonicalSigners, let comm = canonicalCommitments,
              let proposal = pendingProposal, let session = signing,
              signers.contains(config.memberIndex), session.partialsPerInput == nil else { return }
        let partials = try session.sign(commitmentsByInputByIndex: comm)
        partialsByIndex[config.memberIndex] = partials
        try await post(.spendPartial, ["proposalID": proposal.proposalID, "index": Int(config.memberIndex), "partials": partials])
        note("Signed ✓")
        if !isProposer { spendStatus = .awaitingSignatures(have: 1, need: Int(config.threshold)) }
    }

    /// Proposer only: aggregate the canonical set's partials + broadcast.
    private func collectPartial(_ payload: PartialMsg) async throws {
        guard let proposal = pendingProposal, payload.proposalID == proposal.proposalID else { return }
        partialsByIndex[payload.index] = payload.partials
        guard isProposer, !didBroadcast,
              let key = vaultKeyHex, let pub = publicKeyPackage,
              let plan = currentPlan, let signers = canonicalSigners, let comm = canonicalCommitments,
              signers.allSatisfy({ partialsByIndex[$0] != nil }) else { return }
        spendStatus = .awaitingSignatures(have: partialsByIndex.count, need: Int(config.threshold))
        didBroadcast = true
        spendStatus = .broadcasting
        let inputs = proposal.sighashes.count
        var partByInput: [[UInt16: String]] = Array(repeating: [:], count: inputs)
        for idx in signers { for i in 0..<inputs { partByInput[i][idx] = partialsByIndex[idx]![i] } }
        note("Aggregating \(signers.count) partials…")
        let sigs = try FrostAggregator.aggregate(
            publicKeyPackage: pub, sighashes: proposal.sighashes,
            commitmentsByInputByIndex: comm, partialsByInputByIndex: partByInput)
        let engine = FrostVaultEngine(vaultXonlyHex: key, network: chain.network)
        let txid = try await engine.finalizeAndBroadcast(plan: plan, signatures: sigs, esploraURL: chain.esploraURL)
        try await post(.spendBroadcast, ["txid": txid])
        event("Sent ✓")
        spendStatus = .done(txid: txid)
        pendingProposal = nil
        await refreshBalance()
    }

    private func resetSpendState() {
        signing = nil; currentPlan = nil; commitsByIndex = [:]; partialsByIndex = [:]
        canonicalSigners = nil; canonicalCommitments = nil; didBroadcast = false; isProposer = false
    }

    struct CommitMsg: Codable { let proposalID: String; let index: UInt16; let commitments: [String] }
    struct PartialMsg: Codable { let proposalID: String; let index: UInt16; let partials: [String] }
    struct SigningSetMsg: Codable { let proposalID: String; let signers: [UInt16]; let commitments: [[String: [String]]] }

    // MARK: - Chain

    func refreshBalance() async {
        guard let key = vaultKeyHex else { return }
        let engine = FrostVaultEngine(vaultXonlyHex: key, network: chain.network)
        balanceSats = (try? await engine.balance(esploraURL: chain.esploraURL)) ?? balanceSats
    }

    // MARK: - Polling & transport plumbing

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func poll() async {
        do {
            let messages = try await transport.fetch(vaultID: config.vaultID)
            for m in messages {
                guard let kindRaw = m["kind"] as? String, let kind = VaultMessageKind(rawValue: kindRaw),
                      let sender = m["sender"] as? Int, UInt16(sender) != config.memberIndex,
                      let payload = m["payload"] as? [String: Any] else { continue }
                let mkey = "\(kindRaw):\(sender):\((payload["proposalID"] as? String) ?? "")"
                if seenKeys.contains(mkey) { continue }
                seenKeys.insert(mkey)   // mark seen BEFORE handling; persistDKG (in handle) snapshots it with the advanced session
                await handle(kind, payload)
            }
        } catch { /* transient; keep polling */ }
    }

    private func post(_ kind: VaultMessageKind, _ payload: [String: Any]) async throws {
        try await transport.post(vaultID: config.vaultID, message: [
            "kind": kind.rawValue, "sender": Int(config.memberIndex), "payload": payload,
        ])
    }

    private func encode<T: Encodable>(_ v: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(v)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    private func decode<T: Decodable>(_ payload: [String: Any]) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func sats(_ v: UInt64) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: v)) ?? "\(v)") + " sats"
    }
    private static func short(_ a: String) -> String {
        a.count > 24 ? "\(a.prefix(10))…\(a.suffix(8))" : a
    }

    private func note(_ s: String) { log.append(s); if log.count > 40 { log.removeFirst() } }

    /// Plain-language, user-facing activity (never crypto plumbing).
    private func event(_ s: String) {
        activity.append(s)
        if activity.count > 20 { activity.removeFirst() }
    }

    /// Turn engine/network errors into something a normal person can read.
    private func friendlyError(_ error: Error) -> String {
        let m = error.localizedDescription.lowercased()
        if m.contains("insufficient") || m.contains("funds") { return "not enough in the pot" }
        if m.contains("address") { return "that address looks wrong" }
        if m.contains("network") || m.contains("connection") || m.contains("timed out") { return "no connection — try again" }
        return "something went wrong — try again"
    }

    deinit { pollTask?.cancel() }
}
