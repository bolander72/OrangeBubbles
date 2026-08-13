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

/// The shipping, serverless transport: ceremony state rides a single evolving
/// iMessage card that the group passes around. Each member merges the card's
/// messages with their own and re-sends (one tap). No server, no ordering
/// authority — the message set is grow-only and keyed by identity, so unioning
/// converges even if two people send concurrently or out of order (a CRDT-style
/// grow-only set). This is what replaces the debug relay in production.
///
/// The transport is a passive store: the app feeds incoming card payloads in
/// via `ingest`, and `onOutgoing` fires whenever our own state changes so the
/// app can render/update the MSSession card for the user to send. The
/// coordinator's existing poll loop reads the local union through `fetch`.
@MainActor
final class IMessageTransport: VaultTransport {
    /// Grow-only union of ceremony messages, keyed by identity.
    private var messages: [String: [String: Any]] = [:]
    private var order: [String] = []

    /// Fires when our known state changes (a peer's card arrived, or we posted)
    /// so the app can put the full union on the evolving card. Passed the whole
    /// message set — the card always carries everything so any tapper catches up.
    var onOutgoing: (([[String: Any]]) -> Void)?

    /// Each ceremony message is sent at most once per (kind, sender, proposal),
    /// so this key makes the union idempotent and order-independent.
    static func key(_ m: [String: Any]) -> String {
        let kind = m["kind"] as? String ?? "?"
        let sender = m["sender"] as? Int ?? -1
        let pid = (m["payload"] as? [String: Any])?["proposalID"] as? String ?? ""
        return "\(kind):\(sender):\(pid)"
    }

    private func merge(_ incoming: [[String: Any]]) -> Bool {
        var changed = false
        for m in incoming {
            let id = Self.key(m)
            if messages[id] == nil { order.append(id); changed = true }
            messages[id] = m
        }
        return changed
    }

    private func ordered() -> [[String: Any]] { order.compactMap { messages[$0] } }

    /// The app calls this when a ceremony card is received or tapped.
    func ingest(_ incoming: [[String: Any]]) {
        if merge(incoming) { onOutgoing?(ordered()) }
    }

    // MARK: VaultTransport

    func post(vaultID: String, message: [String: Any]) async throws {
        _ = merge([message])
        onOutgoing?(ordered())
    }

    func fetch(vaultID: String) async throws -> [[String: Any]] { ordered() }
}

/// Ceremony message envelope kinds exchanged over the transport. Each
/// wraps a WalletKit Codable payload as JSON.
enum VaultMessageKind: String {
    case announce       // "I'm joining", carries member index + name
    case dkgRound1
    case dkgRound2
    case spendProposal
    case spendCommit    // a signer's commitments for a proposal
    case spendSigningSet // proposer fixes the canonical signer set + commitments
    case spendPartial   // a signer's partial signatures
    case spendBroadcast // final txid
}
