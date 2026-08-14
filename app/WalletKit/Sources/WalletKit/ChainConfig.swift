import Foundation

/// Which chain backend the client talks to. V0 default is public
/// Esplora-compatible APIs queried directly from the device (the privacy
/// choice documented in docs/decisions/0003-chain-api.md); there is no
/// Taproot Wizards server anywhere in the path.
public struct ChainConfig: Sendable {
    public var network: NetworkKind
    /// Ordered, same-chain Esplora endpoints: first is primary, the rest
    /// are failover for outages/rate limits. They MUST all serve the same
    /// chain — the wallet's local cache is keyed by the primary's host, and
    /// updates from any listed endpoint are applied to that one cache.
    public var esploraURLs: [URL]
    /// Optional mempool.space-style recommended-fees endpoint.
    public var feesURL: URL?
    /// Block explorer for "view transaction" links.
    public var explorerTxBase: URL

    public var esploraURL: URL { esploraURLs[0] }

    public init(network: NetworkKind, esploraURLs: [URL], feesURL: URL?, explorerTxBase: URL) {
        precondition(!esploraURLs.isEmpty, "at least one esplora endpoint required")
        self.network = network
        self.esploraURLs = esploraURLs
        self.feesURL = feesURL
        self.explorerTxBase = explorerTxBase
    }

    public static let mainnet = ChainConfig(
        network: .bitcoin,
        esploraURLs: [
            URL(string: "https://mempool.space/api")!,
            URL(string: "https://blockstream.info/api")!,
        ],
        feesURL: URL(string: "https://mempool.space/api/v1/fees/recommended")!,
        explorerTxBase: URL(string: "https://mempool.space/tx")!
    )

    /// Standard signet. Faucets: signetfaucet.com and others — most are
    /// open, unlike Mutinynet's authenticated faucet. Blocks average
    /// ~10 minutes. Blockstream's signet Esplora is the failover:
    /// mempool.space burst-throttles BDK scans (dozens of per-script
    /// requests), which showed up as balance syncs hanging forever.
    public static let signet = ChainConfig(
        network: .signet,
        esploraURLs: [
            URL(string: "https://mempool.space/signet/api")!,
            URL(string: "https://blockstream.info/signet/api")!,
        ],
        feesURL: URL(string: "https://mempool.space/signet/api/v1/fees/recommended")!,
        explorerTxBase: URL(string: "https://mempool.space/signet/tx")!
    )

    public func explorerURL(txid: String) -> URL {
        explorerTxBase.appendingPathComponent(txid)
    }
}
