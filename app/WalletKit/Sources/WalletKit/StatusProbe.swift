import Foundation

/// What the chain says about a payment-request address right now.
public struct AddressActivity: Equatable, Sendable {
    public var confirmedReceivedSats: UInt64
    public var mempoolReceivedSats: UInt64
    public var spentSats: UInt64

    public var hasConfirmed: Bool { confirmedReceivedSats > 0 }
    public var hasPending: Bool { mempoolReceivedSats > 0 }
    public var hasAny: Bool { hasConfirmed || hasPending }
    /// Funds arrived and were spent again — for a claim voucher this
    /// means it was already swept (claimed or reclaimed).
    public var wasSwept: Bool { spentSats > 0 }
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

    public init(session: URLSession = BoundedSession.shared) {
        self.session = session
    }

    public func addressActivity(address: String, esploraURL: URL) async throws -> AddressActivity {
        struct Stats: Codable {
            let funded_txo_sum: UInt64
            let spent_txo_sum: UInt64
        }
        struct AddressInfo: Codable {
            let chain_stats: Stats
            let mempool_stats: Stats
        }
        let url = esploraURL.appendingPathComponent("address/\(address)")
        let data = try await fetch(url)
        let info = try JSONDecoder().decode(AddressInfo.self, from: data)
        return AddressActivity(
            confirmedReceivedSats: info.chain_stats.funded_txo_sum,
            mempoolReceivedSats: info.mempool_stats.funded_txo_sum,
            spentSats: info.chain_stats.spent_txo_sum + info.mempool_stats.spent_txo_sum
        )
    }

    public func txConfirmation(txid: String, esploraURL: URL) async throws -> TxConfirmation {
        struct Status: Codable {
            let confirmed: Bool
            let block_time: UInt64?
        }
        let url = esploraURL.appendingPathComponent("tx/\(txid)/status")
        let data = try await fetch(url)
        let status = try JSONDecoder().decode(Status.self, from: data)
        return TxConfirmation(
            confirmed: status.confirmed,
            blockTime: status.block_time.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    /// One GET with the errors the failover layer understands: 429 cools
    /// the endpoint down, anything else that isn't a 200 moves on to the
    /// next endpoint.
    private func fetch(_ url: URL) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw WalletKitError.networkUnreachable
        }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return data
        case 404: throw WalletKitError.notFound
        case 429: throw WalletKitError.rateLimited
        default: throw WalletKitError.networkUnreachable
        }
    }
}
