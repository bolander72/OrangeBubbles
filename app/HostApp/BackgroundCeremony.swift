import CloudKit
import UIKit
import WalletKit

/// Container-app side of pot setup. A pot's DKG rounds sync over CloudKit; when
/// a peer contributes while this device's app is closed, CloudKit sends a silent
/// push and we finish the local member's part in the background — so nobody has
/// to reopen anything. Reuses the same persisted DKG state the extension wrote
/// (PendingCeremonyStore), resumed via VaultCoordinator(resumingDKG:).
///
/// Needs (one-time, in Xcode Signing & Capabilities): Push Notifications +
/// Background Modes → Remote notifications, and the iCloud > CloudKit container.
/// Untested without a real device + iCloud — the resume machinery is shared with
/// the (compilable) extension path; the push wake is the device-only piece.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        Task { await BackgroundCeremonyResumer.shared.ensureSubscriptions() }
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await BackgroundCeremonyResumer.shared.run()
        return .newData
    }
}

@MainActor
final class BackgroundCeremonyResumer {
    static let shared = BackgroundCeremonyResumer()
    private let pending = PendingCeremonyStore()
    private var active: [VaultCoordinator] = []

    private var chain: ChainConfig {
        switch Bundle.main.object(forInfoDictionaryKey: "WalletNetwork") as? String {
        case "signet": return .signet
        case "bitcoin": return .mainnet
        default:
            #if DEBUG
                return .signet
            #else
                return .mainnet
            #endif
        }
    }

    /// Make sure we're subscribed for every pot still in progress (so future
    /// changes push us). Best-effort.
    func ensureSubscriptions() async {
        for p in pending.all() { try? await CloudKitTransport.subscribe(vaultID: p.vaultID) }
    }

    /// Resume every in-progress ceremony over CloudKit and wait (bounded) for
    /// them to drain — each completion saves the vault and clears its pending
    /// record. Called from a silent push while backgrounded.
    func run() async {
        for p in pending.all() where !active.contains(where: { $0.config.vaultID == p.vaultID }) {
            guard let c = try? VaultCoordinator(
                resumingDKG: p.config, sessionData: p.sessionData, seenKeys: p.seenKeys,
                transport: CloudKitTransport(), chain: chain, mnemonic: p.memberSeed) else { continue }
            wire(c, chatKey: p.chatKey)
            active.append(c)
            Task { await c.resumeDKG() }
        }
        // Silent-push execution time is limited (~30s). Wait for the pending set
        // to drain, then let the system suspend us.
        for _ in 0..<25 {
            if pending.all().isEmpty { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        active.removeAll { $0.stage == .ready }
    }

    private func wire(_ c: VaultCoordinator, chatKey: String?) {
        let cfg = c.config
        let ps = pending
        let vaults = VaultStore()
        c.onDKGProgress = { data, keys in
            guard var rec = ps.all().first(where: { $0.vaultID == cfg.vaultID }) else { return }
            rec.sessionData = data
            rec.seenKeys = keys
            ps.save(rec)
        }
        c.onVaultReady = { r in
            var rec = r
            rec.chatKey = chatKey
            vaults.save(rec)
            ps.delete(vaultID: cfg.vaultID)
        }
    }
}
