import Foundation

public struct FeeTiers: Equatable, Sendable, Codable {
    public var fastestFee: UInt64
    public var halfHourFee: UInt64
    public var hourFee: UInt64
    public var economyFee: UInt64
    public var minimumFee: UInt64

    public static let fallback = FeeTiers(fastestFee: 8, halfHourFee: 5, hourFee: 3, economyFee: 2, minimumFee: 1)
}

/// Fetches sat/vB tiers. Tries the mempool.space-style recommended endpoint
/// first (which our optional backend also serves at /v1/fees), then falls
/// back to Esplora's /fee-estimates map.
public struct FeeEstimator: Sendable {
    private let session: URLSession

    public init(session: URLSession = BoundedSession.shared) {
        self.session = session
    }

    public func tiers(esploraURL: URL, feesURL: URL?) async -> FeeTiers {
        if let feesURL, let tiers = try? await fetchRecommended(feesURL) {
            return tiers
        }
        if let tiers = try? await fetchEsploraEstimates(esploraURL) {
            return tiers
        }
        return .fallback
    }

    private func fetchRecommended(_ url: URL) async throws -> FeeTiers {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        struct Recommended: Codable {
            let fastestFee: Double
            let halfHourFee: Double
            let hourFee: Double
            let economyFee: Double
            let minimumFee: Double
        }
        let r = try JSONDecoder().decode(Recommended.self, from: data)
        return FeeTiers(
            fastestFee: UInt64(max(1, r.fastestFee.rounded(.up))),
            halfHourFee: UInt64(max(1, r.halfHourFee.rounded(.up))),
            hourFee: UInt64(max(1, r.hourFee.rounded(.up))),
            economyFee: UInt64(max(1, r.economyFee.rounded(.up))),
            minimumFee: UInt64(max(1, r.minimumFee.rounded(.up)))
        )
    }

    private func fetchEsploraEstimates(_ esploraURL: URL) async throws -> FeeTiers {
        let (data, response) = try await session.data(from: esploraURL.appendingPathComponent("fee-estimates"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let map = try JSONDecoder().decode([String: Double].self, from: data)
        let targets = map.keys.compactMap(Int.init).sorted()
        func at(_ target: Int) -> UInt64 {
            let chosen = targets.first(where: { $0 >= target }) ?? targets.last
            let rate = chosen.flatMap { map[String($0)] } ?? 1
            return UInt64(max(1, rate.rounded(.up)))
        }
        let fastest = at(1)
        let halfHour = min(at(3), fastest)
        let hour = min(at(6), halfHour)
        let economy = min(at(144), hour)
        return FeeTiers(fastestFee: fastest, halfHourFee: halfHour, hourFee: hour, economyFee: economy, minimumFee: 1)
    }
}
