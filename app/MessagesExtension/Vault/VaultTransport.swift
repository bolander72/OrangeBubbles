import Foundation

/// How vault ceremony messages travel between members. In production this
/// is iMessage cards (end-to-end encrypted, no server). For multi-device
/// development it's the debug relay (`DebugRelayTransport`) so two
/// simulators and a phone can run a real ceremony together — the
/// simulator can't send iMessages, so a stand-in bulletin board is the
/// only way to test the multi-party flow before shipping.
protocol VaultTransport: Sendable {
    /// Append a message to the vault's shared log.
    func post(vaultID: String, message: [String: Any]) async throws
    /// Fetch the full ordered message log for a vault.
    func fetch(vaultID: String) async throws -> [[String: Any]]
}

/// Talks to the local debug relay (see frost/relay/relay.py). DEBUG only.
struct DebugRelayTransport: VaultTransport {
    let baseURL: URL

    func post(vaultID: String, message: [String: Any]) async throws {
        var req = URLRequest(url: baseURL.appendingPathComponent("vault/\(vaultID)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: message)
        _ = try await URLSession.shared.data(for: req)
    }

    func fetch(vaultID: String) async throws -> [[String: Any]] {
        let url = baseURL.appendingPathComponent("vault/\(vaultID)")
        let (data, _) = try await URLSession.shared.data(from: url)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["messages"] as? [[String: Any]]) ?? []
    }
}

/// Ceremony message envelope kinds exchanged over the transport. Each
/// wraps a WalletKit Codable payload as JSON.
enum VaultMessageKind: String {
    case announce       // "I'm joining", carries member index + name
    case dkgRound1
    case dkgRound2
    case spendProposal
    case spendCommit    // a signer's commitments for a proposal
    case spendPartial   // a signer's partial signatures
    case spendBroadcast // final txid
}
