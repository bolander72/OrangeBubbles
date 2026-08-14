import CloudKit
import Foundation

/// The shipping transport for pot coordination. The DKG + signing rounds ride
/// **CloudKit** (Apple's iCloud, the app's own container) instead of cards sent
/// back and forth — so a member just taps the invite once and their round syncs
/// silently. Trustless (round-2 shares are already pairwise-encrypted; round-1
/// commitments are public), and no send-back ever.
///
/// One CloudKit record per pot (recordName = vaultID) holds a grow-only set of
/// ceremony messages, exactly like the evolving card did — but merged by every
/// member's device. Union is by message identity, so concurrent writes converge
/// (CloudKit conflicts re-merge and retry). Fetch/save go by recordID, so no
/// queryable schema/index setup is needed.
@MainActor
final class CloudKitTransport: VaultTransport {
    /// The app's CloudKit container (public database — records keyed by the
    /// pot's id, which is derived from the chat fingerprint at creation).
    static let containerID = "iCloud.com.bolandcompany.orangebubbles"
    private let db = CKContainer(identifier: CloudKitTransport.containerID).publicCloudDatabase
    private let recordType = "PotCeremony"

    private var messages: [String: [String: Any]] = [:]
    private var order: [String] = []

    /// Whether the local user can use CloudKit at all (signed into iCloud).
    static func accountAvailable() async -> Bool {
        let status = try? await CKContainer(identifier: containerID).accountStatus()
        return status == .available
    }

    /// Ask CloudKit to silently push the container app when this pot's record
    /// changes, so the creator's later round can finish while the app is closed
    /// (see BackgroundCeremonyResumer). Best-effort; idempotent by subscriptionID.
    /// NOTE: public-DB subscription predicate behavior needs on-device verification.
    static func subscribe(vaultID: String) async throws {
        let subscription = CKQuerySubscription(
            recordType: "PotCeremony",
            predicate: NSPredicate(format: "recordID == %@", CKRecord.ID(recordName: vaultID)),
            subscriptionID: "pot-\(vaultID)",
            options: [.firesOnRecordUpdate, .firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true   // silent (content-available) push
        subscription.notificationInfo = info
        _ = try await CKContainer(identifier: containerID).publicCloudDatabase.save(subscription)
    }

    static func key(_ m: [String: Any]) -> String {
        let kind = m["kind"] as? String ?? "?"
        let sender = m["sender"] as? Int ?? -1
        let pid = (m["payload"] as? [String: Any])?["proposalID"] as? String ?? ""
        return "\(kind):\(sender):\(pid)"
    }

    @discardableResult
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

    private func decodeMessages(_ record: CKRecord) {
        if let data = record["messages"] as? Data,
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            merge(arr)
        }
    }

    // MARK: VaultTransport

    /// Pull the pot's record, merge into our local union, and return it.
    func fetch(vaultID: String) async throws -> [[String: Any]] {
        let id = CKRecord.ID(recordName: vaultID)
        if let record = try? await db.record(for: id) { decodeMessages(record) }
        return ordered()
    }

    /// Add a message to the pot record (fetch → union → save, retrying on the
    /// server-changed conflict by re-merging — grow-only, so it converges).
    func post(vaultID: String, message: [String: Any]) async throws {
        merge([message])
        try await save(vaultID: vaultID, retries: 4)
    }

    private func save(vaultID: String, retries: Int) async throws {
        let id = CKRecord.ID(recordName: vaultID)
        let record: CKRecord
        if let existing = try? await db.record(for: id) {
            decodeMessages(existing)          // fold in anything new from the server
            record = existing
        } else {
            record = CKRecord(recordType: recordType, recordID: id)
        }
        record["messages"] = try JSONSerialization.data(withJSONObject: ordered()) as CKRecordValue
        do {
            _ = try await db.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged && retries > 0 {
            if let server = error.serverRecord { decodeMessages(server) }
            try await save(vaultID: vaultID, retries: retries - 1)
        }
    }
}
