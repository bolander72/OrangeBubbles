import Foundation

/// Watch-only wallet snapshot shared through the App Group container.
///
/// Written by the Messages extension on every refresh; read by the widget
/// and the App Intents (Siri/Shortcuts). Contains **no key material** —
/// balances, recent activity, and pre-derived (peeked) receive addresses
/// only. Compiled into each target directly so non-wallet targets don't
/// link BitcoinDevKit.
struct SharedSnapshot: Codable {
    struct Activity: Codable, Identifiable {
        var id: String { txid }
        let txid: String
        let incoming: Bool
        let amountSats: UInt64
        let confirmed: Bool
        let timestamp: Date?
    }

    var balanceSats: UInt64
    var pendingSats: UInt64
    var recent: [Activity]
    /// NetworkKind raw value ("bitcoin", "signet", …).
    var network: String
    /// Fresh, never-revealed receive addresses (peeked). Consumers take
    /// the first; staleness just means address reuse *within our own
    /// wallet*, which a full scan absorbs.
    var upcomingReceiveAddresses: [String]
    var usdPerBTC: Double?
    var updatedAt: Date

    static let appGroupID = "group.com.taprootwizards.imessagewallet"
    private static let fileName = "wallet-snapshot.json"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    static func load() -> SharedSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Display helpers (shared by widget + intents)

    static func formatSats(_ sats: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: sats)) ?? String(sats)
    }

    var balanceLine: String {
        "\(Self.formatSats(balanceSats)) sats"
    }

    var usdLine: String? {
        guard let usdPerBTC, balanceSats > 0 else { return nil }
        let usd = Double(balanceSats) / 100_000_000 * usdPerBTC
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: usd))
    }
}
