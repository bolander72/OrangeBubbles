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
        let displayName: String
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
    private var seenMessageCount = 0

    init(config: Config, transport: VaultTransport, chain: ChainConfig, mnemonic: String) throws {
        self.config = config
        self.transport = transport
        self.chain = chain
        self.mnemonic = mnemonic
        self.identity = try FrostMemberIdentity(index: config.memberIndex, mnemonic: mnemonic)
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

            // Broadcast our round-1 package.
            let r1 = session.round1Message()
            try await post(.dkgRound1, encode(r1))
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
            case .dkgRound2:
                guard let session = dkg else { return }
                let msg: FrostDKGSession.Round2Message = try decode(payload)
                let done = try session.receiveRound2(msg, identity: identity)
                if done { try finishDKG() }
            case .spendProposal:
                let p: Proposal = try decode(payload)
                pendingProposal = p
                note("Spend proposed: \(Format.sats(p.amountSats)) sats to \(Format.shortAddress(p.destination))")
            case .spendCommit:
                try await collectCommit(decode(payload))
            case .spendPartial:
                try await collectPartial(decode(payload))
            case .spendBroadcast:
                if let txid = payload["txid"] as? String {
                    note("Broadcast! tx \(txid.prefix(12))…")
                    await refreshBalance()
                }
            case .announce:
                break
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
        vaultAddress = try engine.address()
        stage = .ready
        note("Vault ready ✓ key \(key.prefix(12))…")
        Task { await refreshBalance() }
    }

    // MARK: - Spend (proposer path)

    private var signing: FrostSigningSession?
    private var currentPlan: FrostVaultEngine.SpendPlan?
    private var commitsByIndex: [UInt16: [String]] = [:]
    private var partialsByIndex: [UInt16: [String]] = [:]

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
        do {
            note("Building spend…")
            let engine = FrostVaultEngine(vaultXonlyHex: key, network: chain.network)
            let plan = try await engine.planSpend(to: destination, amountSats: amountSats, feeSats: feeSats, esploraURL: chain.esploraURL)
            let proposal = Proposal(
                proposalID: UUID().uuidString, destination: destination,
                amountSats: amountSats ?? balanceSats, feeSats: feeSats,
                unsignedTxHex: plan.unsignedTxHex, sighashes: plan.sighashes)
            currentPlan = plan
            try await post(.spendProposal, encode(proposal))
            pendingProposal = proposal
            await approve(proposal) // proposer signs too
        } catch {
            note("⚠️ propose failed: \(error.localizedDescription)")
        }
    }

    /// Any signer approves the pending proposal: commit, then (as commits
    /// arrive) sign, and (as partials arrive, if we're the proposer)
    /// aggregate + broadcast.
    func approve(_ proposal: Proposal) async {
        guard let kp = keyPackage else { return }
        do {
            let session = FrostSigningSession(
                vaultID: config.vaultID, proposalID: proposal.proposalID,
                selfIndex: config.memberIndex, keyPackage: kp, sighashes: proposal.sighashes)
            signing = session
            let commitments = try session.commitments()
            commitsByIndex[config.memberIndex] = commitments
            try await post(.spendCommit, ["proposalID": proposal.proposalID, "index": Int(config.memberIndex), "commitments": commitments])
            note("Approved — committed nonces")
        } catch {
            note("⚠️ approve failed: \(error.localizedDescription)")
        }
    }

    private func collectCommit(_ payload: CommitMsg) async throws {
        commitsByIndex[payload.index] = payload.commitments
        guard let proposal = pendingProposal, let session = signing,
              commitsByIndex.count >= Int(config.threshold) else { return }
        // Enough commits: produce our partials.
        let inputs = proposal.sighashes.count
        var byInput: [[UInt16: String]] = Array(repeating: [:], count: inputs)
        for (idx, comms) in commitsByIndex { for i in 0..<inputs { byInput[i][idx] = comms[i] } }
        if session.partialsPerInput == nil {
            let partials = try session.sign(commitmentsByInputByIndex: byInput)
            partialsByIndex[config.memberIndex] = partials
            try await post(.spendPartial, ["proposalID": proposal.proposalID, "index": Int(config.memberIndex), "partials": partials])
            note("Signed partials")
        }
    }

    private func collectPartial(_ payload: PartialMsg) async throws {
        partialsByIndex[payload.index] = payload.partials
        guard let proposal = pendingProposal, let key = vaultKeyHex, let pub = publicKeyPackage,
              let plan = currentPlan, partialsByIndex.count >= Int(config.threshold) else { return }
        // We have a threshold of partials — finalize (idempotent; only the
        // instance holding the plan aggregates).
        let inputs = proposal.sighashes.count
        var commByInput: [[UInt16: String]] = Array(repeating: [:], count: inputs)
        var partByInput: [[UInt16: String]] = Array(repeating: [:], count: inputs)
        let signerSet = Array(partialsByIndex.keys.prefix(Int(config.threshold)))
        for idx in signerSet {
            for i in 0..<inputs {
                commByInput[i][idx] = commitsByIndex[idx]![i]
                partByInput[i][idx] = partialsByIndex[idx]![i]
            }
        }
        let sigs = try FrostAggregator.aggregate(
            publicKeyPackage: pub, sighashes: proposal.sighashes,
            commitmentsByInputByIndex: commByInput, partialsByInputByIndex: partByInput)
        let engine = FrostVaultEngine(vaultXonlyHex: key, network: chain.network)
        let txid = try await engine.finalizeAndBroadcast(
            plan: plan, signatures: sigs, esploraURL: chain.esploraURL)
        try await post(.spendBroadcast, ["txid": txid])
        note("BROADCAST ✓ tx \(txid.prefix(12))…")
        pendingProposal = nil
        await refreshBalance()
    }

    struct CommitMsg: Codable { let proposalID: String; let index: UInt16; let commitments: [String] }
    struct PartialMsg: Codable { let proposalID: String; let index: UInt16; let partials: [String] }

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
            guard messages.count > seenMessageCount else { return }
            let fresh = messages[seenMessageCount...]
            seenMessageCount = messages.count
            for m in fresh {
                guard let kindRaw = m["kind"] as? String, let kind = VaultMessageKind(rawValue: kindRaw),
                      let sender = m["sender"] as? Int, UInt16(sender) != config.memberIndex,
                      let payload = m["payload"] as? [String: Any] else { continue }
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

    private func note(_ s: String) { log.append(s); if log.count > 40 { log.removeFirst() } }

    deinit { pollTask?.cancel() }
}
