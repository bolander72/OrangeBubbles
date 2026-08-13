import Foundation

/// A "join our pot" invitation — what travels inside an iMessage card's URL.
/// Carries everything a recipient needs to join the shared pot: which pot,
/// how big, the approval threshold, and where the automatic key-setup rounds
/// are coordinated (the relay; a hosted service in production). No secrets —
/// key material never leaves each member's device.
public struct PotInvite: Equatable, Sendable {
    public var vaultID: String
    public var name: String
    public var emoji: String
    public var memberCount: UInt16
    public var threshold: UInt16
    public var relayHost: String

    public init(vaultID: String, name: String, emoji: String,
                memberCount: UInt16, threshold: UInt16, relayHost: String) {
        self.vaultID = vaultID
        self.name = name
        self.emoji = emoji
        self.memberCount = memberCount
        self.threshold = threshold
        self.relayHost = relayHost
    }

    public func queryItems() -> [URLQueryItem] {
        [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "vault", value: vaultID),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "emoji", value: emoji),
            URLQueryItem(name: "n", value: String(memberCount)),
            URLQueryItem(name: "k", value: String(threshold)),
            URLQueryItem(name: "relay", value: relayHost),
        ]
    }

    public init?(queryItems: [URLQueryItem]) {
        func value(_ name: String) -> String? { queryItems.first(where: { $0.name == name })?.value }
        guard let vault = value("vault"), !vault.isEmpty,
              let n = value("n").flatMap(UInt16.init),
              let k = value("k").flatMap(UInt16.init) else { return nil }
        self.vaultID = vault
        self.name = value("name") ?? "Shared pot"
        self.emoji = value("emoji") ?? "🍯"
        self.memberCount = n
        self.threshold = k
        self.relayHost = value("relay") ?? "127.0.0.1"
    }

    /// Plain-language summary for the card / join screen.
    public var ruleLine: String {
        "\(memberCount) people · any \(threshold) approve"
    }
}
