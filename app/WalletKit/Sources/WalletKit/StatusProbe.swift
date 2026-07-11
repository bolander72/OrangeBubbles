import Foundation

/// What the chain says about a payment-request address right now.
public struct AddressActivity: Equatable, Sendable {
    public var confirmedReceivedSats: UInt64
    public var mempoolReceivedSats: UInt64

    public var hasConfirmed: Bool { confirmedReceivedSats > 0 }
    public var hasPending: Bool { mempoolReceivedSats > 0 }
    public var hasAny: Bool { hasConfirmed || hasPending }
}

public struct TxConfirmation: Equatable, Sendable {
    public var confirmed: Bool
    public var blockTime: Date?
}

/// Tiny read-only Esplora client used by card-status views. Deliberately
/// separate from BDK's sync machinery: these are one-shot lookups about a
/// single address/txid — including ones that belong to *someone else's*
/// wallet (a request card we received).
public struct StatusProbe: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func addressActivity(address: String, esploraURL: URL) async throws -> AddressActivity {
        struct Stats: Codable {
            let funded_txo_sum: UInt64
        }
        struct AddressInfo: Codable {
            let chain_stats: Stats
            let mempool_stats: Stats
        }
        let url = esploraURL.appendingPathComponent("address/\(address)")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WalletKitError.internalError("address lookup failed")
        }
        let info = try JSONDecoder().decode(AddressInfo.self, from: data)
        return AddressActivity(
            confirmedReceivedSats: info.chain_stats.funded_txo_sum,
            mempoolReceivedSats: info.mempool_stats.funded_txo_sum
        )
    }

    public func txConfirmation(txid: String, esploraURL: URL) async throws -> TxConfirmation {
        struct Status: Codable {
            let confirmed: Bool
            let block_time: UInt64?
        }
        let url = esploraURL.appendingPathComponent("tx/\(txid)/status")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WalletKitError.internalError("transaction lookup failed")
        }
        let status = try JSONDecoder().decode(Status.self, from: data)
        return TxConfirmation(
            confirmed: status.confirmed,
            blockTime: status.block_time.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}
