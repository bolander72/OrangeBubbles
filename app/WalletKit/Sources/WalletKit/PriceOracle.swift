import Foundation

/// Fetches the BTC/USD rate directly from a public API on device — display
/// convenience only, never used for transaction math. Per product policy
/// there is no Taproot Wizards server in this path.
public struct PriceOracle: Sendable {
    public static let defaultURL = URL(string: "https://mempool.space/api/v1/prices")!

    private let session: URLSession
    private let url: URL

    public init(url: URL = PriceOracle.defaultURL, session: URLSession? = nil) {
        self.url = url
        self.session = session ?? PriceOracle.boundedSession
    }

    static let boundedSession: URLSession = BoundedSession.shared

    /// Returns nil on any failure — fiat display simply hides.
    public func usdPerBTC() async -> Double? {
        struct Prices: Codable {
            let USD: Double
        }
        guard
            let (data, response) = try? await session.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let prices = try? JSONDecoder().decode(Prices.self, from: data)
        else { return nil }
        return prices.USD
    }

    public static func usdString(sats: UInt64, usdPerBTC: Double) -> String {
        let usd = Double(sats) / 100_000_000 * usdPerBTC
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = usd < 1 ? 4 : 2
        return formatter.string(from: NSNumber(value: usd)) ?? String(format: "$%.2f", usd)
    }
}

/// The one URLSession for every small JSON fetch (fees, price, status
/// probes). Short timeouts matter more than usual here: a public Esplora
/// that is rate-limiting us may hold a connection open for minutes, and
/// `URLSession.shared`'s 60-second default would stall every refresh.
public enum BoundedSession {
    public static let shared: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
}
