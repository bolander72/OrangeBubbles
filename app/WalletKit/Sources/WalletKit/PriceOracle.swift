import Foundation

/// Fetches the BTC/USD rate directly from a public API on device — display
/// convenience only, never used for transaction math. Per product policy
/// there is no Taproot Wizards server in this path.
public struct PriceOracle: Sendable {
    public static let defaultURL = URL(string: "https://mempool.space/api/v1/prices")!

    private let session: URLSession
    private let url: URL

    public init(url: URL = PriceOracle.defaultURL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

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
