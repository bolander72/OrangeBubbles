import Foundation
import OBFrost

/// Ties the FROST layers to the chain (ADR 0008 frost-v1, task 4): derive
/// the vault's Taproot address, read its UTXOs, build the keypath
/// sighashes, and — given the aggregated signatures from a signing
/// ceremony — finalize and broadcast a real transaction. The delicate
/// bitcoin-tx construction lives in the Rust FFI (the code proven on-chain
/// in the research PoC); this type is the Swift orchestration around it.
public struct FrostVaultEngine: Sendable {
    public let vaultXonlyHex: String
    public let network: NetworkKind
    private let session: URLSession

    public init(vaultXonlyHex: String, network: NetworkKind, session: URLSession = .shared) {
        self.vaultXonlyHex = vaultXonlyHex
        self.network = network
        self.session = session
    }

    public func address() throws -> String {
        try frostVaultAddress(xonlyHex: vaultXonlyHex, network: network.rawValue)
    }

    // MARK: - Chain reads

    public struct VaultUTXO: Sendable {
        public let txid: String
        public let vout: UInt32
        public let valueSats: UInt64
    }

    public func fetchUTXOs(esploraURL: URL) async throws -> [VaultUTXO] {
        let addr = try address()
        let url = esploraURL.appendingPathComponent("address/\(addr)/utxo")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WalletKitError.networkUnreachable
        }
        struct Esplora: Decodable { let txid: String; let vout: UInt32; let value: UInt64 }
        let raw = try JSONDecoder().decode([Esplora].self, from: data)
        return raw.map { VaultUTXO(txid: $0.txid, vout: $0.vout, valueSats: $0.value) }
    }

    public func balance(esploraURL: URL) async throws -> UInt64 {
        try await fetchUTXOs(esploraURL: esploraURL).reduce(0) { $0 + $1.valueSats }
    }

    // MARK: - Spend construction

    public struct SpendPlan: Sendable {
        public let unsignedTxHex: String
        /// Per-input taproot keypath sighashes — the messages the FROST
        /// signing session signs.
        public let sighashes: [String]
    }

    /// Builds the unsigned transaction + sighashes. `amountSats == nil`
    /// sweeps everything.
    public func planSpend(
        to destination: String,
        amountSats: UInt64?,
        feeSats: UInt64,
        esploraURL: URL
    ) async throws -> SpendPlan {
        let utxos = try await fetchUTXOs(esploraURL: esploraURL)
        guard !utxos.isEmpty else { throw WalletKitError.insufficientFunds }
        let plan = try frostBuildSpend(
            xonlyHex: vaultXonlyHex,
            utxos: utxos.map { FrostUtxo(txid: $0.txid, vout: $0.vout, valueSats: $0.valueSats) },
            destAddress: destination,
            amountSats: amountSats ?? 0,
            feeSats: feeSats,
            network: network.rawValue
        )
        return SpendPlan(unsignedTxHex: plan.unsignedTxHex, sighashes: plan.sighashesHex)
    }

    /// Injects aggregated signatures (one per input) into the plan and
    /// broadcasts. Returns the txid.
    public func finalizeAndBroadcast(
        plan: SpendPlan,
        signatures: [String],
        esploraURL: URL
    ) async throws -> String {
        let signedHex = try frostFinalizeSpend(unsignedTxHex: plan.unsignedTxHex, signaturesHex: signatures)
        let url = esploraURL.appendingPathComponent("tx")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(signedHex.utf8)
        let (data, response) = try await session.upload(for: request, from: request.httpBody ?? Data())
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WalletKitError.internalError("broadcast rejected: \(body)")
        }
        return body // txid
    }
}
