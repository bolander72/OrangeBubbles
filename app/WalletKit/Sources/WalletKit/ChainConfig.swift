import Foundation

/// Which chain backend the client talks to. V0 default is a public
/// Esplora-compatible API queried directly from the device (the privacy
/// choice documented in docs/decisions/0003-chain-api.md); flipping to our
/// own backend is a URL change only.
public struct ChainConfig: Sendable {
    public var network: NetworkKind
    /// Esplora-compatible base URL used by BDK for sync + broadcast.
    public var esploraURL: URL
    /// Optional mempool.space-style recommended-fees endpoint.
    public var feesURL: URL?
    /// Block explorer for "view transaction" links.
    public var explorerTxBase: URL

    public init(network: NetworkKind, esploraURL: URL, feesURL: URL?, explorerTxBase: URL) {
        self.network = network
        self.esploraURL = esploraURL
        self.feesURL = feesURL
        self.explorerTxBase = explorerTxBase
    }

    public static let mainnet = ChainConfig(
        network: .bitcoin,
        esploraURL: URL(string: "https://mempool.space/api")!,
        feesURL: URL(string: "https://mempool.space/api/v1/fees/recommended")!,
        explorerTxBase: URL(string: "https://mempool.space/tx")!
    )

    /// Standard signet (mempool.space). Faucets: signetfaucet.com and
    /// others — most are open, unlike Mutinynet's authenticated faucet.
    /// Blocks average ~10 minutes.
    public static let signet = ChainConfig(
        network: .signet,
        esploraURL: URL(string: "https://mempool.space/signet/api")!,
        feesURL: URL(string: "https://mempool.space/signet/api/v1/fees/recommended")!,
        explorerTxBase: URL(string: "https://mempool.space/signet/tx")!
    )

    public func explorerURL(txid: String) -> URL {
        explorerTxBase.appendingPathComponent(txid)
    }
}
