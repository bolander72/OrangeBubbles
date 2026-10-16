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

    /// The same chain, read through the user's own Esplora/mempool API
    /// first (the public services stay as failover). No separate fees
    /// endpoint: fee estimates come from the node too, so a privacy-minded
    /// user talks to nobody else.
    public func withCustomEsplora(_ url: URL) -> ChainConfig {
        var copy = self
        copy.esploraURLs = [url] + esploraURLs.filter { $0 != url }
        copy.feesURL = nil
        return copy
    }

    /// Hash of block 0, used to check that a user-supplied endpoint serves
    /// this chain before the wallet trusts it.
    public var genesisHash: String {
        switch network {
        case .bitcoin: return "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f"
        case .testnet: return "000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943"
        case .signet: return "00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6"
        case .regtest: return "0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206"
        }
    }
}

/// Checks a user-supplied Esplora base URL before the wallet switches to it.
public enum EsploraEndpointCheck {
    public enum Failure: LocalizedError, Equatable {
        case notAnURL
        case unreachable
        case notEsplora
        case wrongChain(expected: NetworkKind)

        public var errorDescription: String? {
            switch self {
            case .notAnURL: return "That doesn't look like a URL. Use the API base, like https://your-node.example/api."
            case .unreachable: return "Couldn't reach that server."
            case .notEsplora: return "That server doesn't answer like an Esplora or mempool API."
            case .wrongChain(let expected): return "That server is on a different chain — this wallet is on \(expected.rawValue)."
            }
        }
    }

    /// Normalises user input into an API base URL: adds https:// when no
    /// scheme is given, strips a trailing slash. Plain http is allowed so
    /// a node on the local network works.
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// Returns the tip height on success.
    public static func verify(_ base: URL, network: NetworkKind, session: URLSession = BoundedSession.shared) async throws -> UInt32 {
        func get(_ path: String) async throws -> String {
            let (data, response): (Data, URLResponse)
            do { (data, response) = try await session.data(from: base.appendingPathComponent(path)) }
            catch { throw Failure.unreachable }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.notEsplora }
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let height = UInt32(try await get("blocks/tip/height")) else { throw Failure.notEsplora }
        let genesis = try await get("block-height/0").lowercased()
        guard genesis.count == 64 else { throw Failure.notEsplora }
        guard genesis == ChainConfig(network: network, esploraURLs: [base], feesURL: nil, explorerTxBase: base).genesisHash else {
            throw Failure.wrongChain(expected: network)
        }
        return height
    }
}
