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

    static let appGroupID = "group.com.bolandcompany.orangebubbles"
    private static let fileName = "wallet-snapshot.json"

    /// Written under Library/Application Support: on real devices the
    /// group container's ROOT is not reliably writable (the simulator is
    /// lax about it, which hid this) — the original root-level write
    /// silently failed on hardware, starving the widget and Siri.
    private static var fileURL: URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else { return nil }
        let dir = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    /// Pre-fix location (container root) — read fallback for one
    /// transition so an un-upgraded writer's data still surfaces.
    private static var legacyFileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(fileName)
    }

    static func load() -> SharedSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in [fileURL, legacyFileURL].compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               let snapshot = try? decoder.decode(SharedSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }

    func save() {
        guard let url = Self.fileURL else {
            NSLog("SharedSnapshot: app group container unavailable")
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(self)
            try data.write(to: url, options: .atomic)
        } catch {
            // Loud, not silent — this exact failure hid for weeks.
            NSLog("SharedSnapshot: write failed: \(error)")
        }
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
