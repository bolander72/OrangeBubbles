import Foundation

/// Defense against clipboard/address-poisoning attacks: victims verify
/// only the ends of a pasted address, so attackers craft lookalikes whose
/// prefix and suffix match an address the victim has paid before.
public enum AddressSafety {
    /// Returns the historical address the candidate suspiciously resembles
    /// (same start and end, different middle), or nil if it looks clean.
    public static func poisoningSuspect(
        candidate: String,
        history: [String],
        edge: Int = 6
    ) -> String? {
        let c = candidate.lowercased()
        guard c.count > edge * 2 else { return nil }
        for paid in history {
            let p = paid.lowercased()
            guard p.count > edge * 2, p != c else { continue }
            if p.prefix(edge) == c.prefix(edge), p.suffix(edge) == c.suffix(edge) {
                return paid
            }
        }
        return nil
    }
}

/// Parses human amount expressions into sats deterministically:
/// "21000", "21,000 sats", "5k sats", "0.5 btc", "₿0.5", "$5", "5 usd",
/// "5 bucks". USD forms need a rate; they return `.usd` for the caller to
/// convert (or reject when no rate is known).
public enum SmartAmount {
    public enum Parsed: Equatable {
        case sats(UInt64)
        case usd(Double)
    }

    public static func parse(_ input: String) -> Parsed? {
        var text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        text = text.replacingOccurrences(of: ",", with: "")

        // Dollar forms
        let usdMarkers = ["$", "usd", "dollars", "dollar", "bucks", "buck"]
        if usdMarkers.contains(where: { text.contains($0) }) {
            var cleaned = text
            for marker in usdMarkers {
                cleaned = cleaned.replacingOccurrences(of: marker, with: "")
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            guard let value = Double(cleaned), value > 0 else { return nil }
            return .usd(value)
        }

        // BTC forms
        if text.contains("btc") || text.contains("₿") || text.contains("bitcoin") {
            var cleaned = text
            for marker in ["btc", "₿", "bitcoins", "bitcoin"] {
                cleaned = cleaned.replacingOccurrences(of: marker, with: "")
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            guard
                let btc = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
                btc > 0
            else { return nil }
            return .sats(UInt64(truncating: NSDecimalNumber(decimal: btc * 100_000_000)))
        }

        // Sats forms, with k/m shorthand
        var cleaned = text
        for marker in ["sats", "sat", "satoshis", "satoshi"] {
            cleaned = cleaned.replacingOccurrences(of: marker, with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        var multiplier: Double = 1
        if cleaned.hasSuffix("k") {
            multiplier = 1_000
            cleaned = String(cleaned.dropLast())
        } else if cleaned.hasSuffix("m") {
            multiplier = 1_000_000
            cleaned = String(cleaned.dropLast())
        }
        guard let value = Double(cleaned), value > 0 else { return nil }
        return .sats(UInt64(value * multiplier))
    }
}
