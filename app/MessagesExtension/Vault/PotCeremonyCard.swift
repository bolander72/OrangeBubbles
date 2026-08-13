import Foundation

/// The single evolving iMessage card that carries a pot's whole life over
/// iMessage — no server. It holds the pot's identity (so a fresh recipient can
/// join) plus the grow-only set of ceremony messages (DKG + signing). Each
/// member merges the card's messages with their own and re-sends; the card is
/// updated in place via one MSSession so the group sees a single living bubble.
///
/// The messages union is JSON, base64'd into the URL's `d` param (iMessage app
/// messages carry data only through the URL). Pots are small (2–5 people), so
/// the payload stays well within practical URL limits.
struct PotCeremonyCard {
    var vaultID: String
    var name: String
    var emoji: String
    var memberCount: UInt16
    var threshold: UInt16
    var messages: [[String: Any]]

    static let path = "/pot"

    /// Build the card URL (https so it renders as a rich card in the transcript).
    func url() -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "www.boland.co"
        c.path = Self.path
        var items = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "vault", value: vaultID),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "emoji", value: emoji),
            URLQueryItem(name: "n", value: String(memberCount)),
            URLQueryItem(name: "k", value: String(threshold)),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: messages),
           !messages.isEmpty {
            items.append(URLQueryItem(name: "d", value: data.base64EncodedString()))
        }
        c.queryItems = items
        return c.url
    }

    init(vaultID: String, name: String, emoji: String,
         memberCount: UInt16, threshold: UInt16, messages: [[String: Any]]) {
        self.vaultID = vaultID
        self.name = name
        self.emoji = emoji
        self.memberCount = memberCount
        self.threshold = threshold
        self.messages = messages
    }

    /// Decode a tapped/received card back into pot identity + ceremony messages.
    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.path == Self.path,
              let items = c.queryItems else { return nil }
        func value(_ k: String) -> String? { items.first { $0.name == k }?.value }
        guard let vault = value("vault"), !vault.isEmpty,
              let n = value("n").flatMap(UInt16.init),
              let k = value("k").flatMap(UInt16.init) else { return nil }
        self.vaultID = vault
        self.name = value("name") ?? "Shared pot"
        self.emoji = value("emoji") ?? "🍯"
        self.memberCount = n
        self.threshold = k
        if let b64 = value("d"), let data = Data(base64Encoded: b64),
           let msgs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            self.messages = msgs
        } else {
            self.messages = []
        }
    }

    /// True once every member has contributed to the final round — i.e. setup
    /// looks complete from the card alone (a hint for card captions only; the
    /// coordinator is the source of truth on readiness).
    var dkgRound2Count: Int {
        Set(messages.filter { ($0["kind"] as? String) == "dkgRound2" }
            .compactMap { $0["sender"] as? Int }).count
    }
    var ruleLine: String { "\(memberCount) people · any \(threshold) approve" }
}
