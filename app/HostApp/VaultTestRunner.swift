#if DEBUG
import SwiftUI
import WalletKit

/// DEBUG-only headless-ish vault member for the multi-device FROST test.
/// Driven by launch arguments so a simulator can be a real vault member
/// without any manual UI navigation:
///
///   simctl launch <dev> com.bolandcompany.orangebubbles --args \
///     -vaultRun 1 -vaultHost 127.0.0.1 -vaultID testvault \
///     -vaultMember 1 -vaultN 3 -vaultK 2
///
/// The phone plays its member through the real extension Vault Lab; this
/// runner lets the Mac drive the simulator members deterministically.
enum VaultTestLaunch {
    static var isActive: Bool { UserDefaults.standard.string(forKey: "vaultRun") != nil }

    static func config() -> (VaultCoordinator.Config, host: String)? {
        let d = UserDefaults.standard
        guard d.string(forKey: "vaultRun") != nil,
              let member = d.string(forKey: "vaultMember").flatMap({ UInt16($0) }) else { return nil }
        let host = d.string(forKey: "vaultHost") ?? "127.0.0.1"
        let cfg = VaultCoordinator.Config(
            vaultID: d.string(forKey: "vaultID") ?? "testvault",
            name: "test",
            memberIndex: member,
            memberCount: UInt16(d.string(forKey: "vaultN") ?? "3") ?? 3,
            threshold: UInt16(d.string(forKey: "vaultK") ?? "2") ?? 2)
        return (cfg, host)
    }
}

struct VaultTestRunnerView: View {
    @StateObject private var model = Model()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vault Test Runner").font(.headline)
            if let c = model.coordinator {
                Text("Member \(c.config.memberIndex) of \(c.config.memberCount), k=\(c.config.threshold)")
                    .font(.caption).foregroundStyle(.secondary)
                statusLine(c)
                if let addr = c.vaultAddress {
                    Text(addr).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    Text("Balance: \(c.balanceSats) sats").font(.caption)
                }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(c.log.enumerated().reversed()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 11, design: .monospaced))
                        }
                    }
                }
            } else {
                Text("No launch config").foregroundStyle(.red)
            }
        }
        .padding()
        .task { await model.start() }
    }

    private func statusLine(_ c: VaultCoordinator) -> some View {
        switch c.stage {
        case .idle: return Text("idle")
        case .dkgInProgress(let s): return Text("DKG: \(s)").foregroundStyle(.orange)
        case .ready: return Text("READY ✓").foregroundStyle(.green)
        case .error(let e): return Text("ERR: \(e)").foregroundStyle(.red)
        }
    }

    @MainActor final class Model: ObservableObject {
        @Published var coordinator: VaultCoordinator?
        func start() async {
            guard coordinator == nil, let (cfg, host) = VaultTestLaunch.config(),
                  let url = URL(string: "http://\(host):8781") else { return }
            // Each member needs a distinct seed for its pairwise-encryption
            // identity; derive a stable one per member index.
            let seed = (try? WalletEngine.deterministicMnemonic(from: "vaulttest-member-\(cfg.memberIndex)")) ?? ""
            let transport = DebugRelayTransport(baseURL: url)
            let store = VaultStore()
            if let existing = store.all().first(where: { $0.vaultID == cfg.vaultID && $0.memberIndex == cfg.memberIndex }) {
                guard let c = try? VaultCoordinator(resuming: existing, transport: transport, chain: .signet, mnemonic: seed) else { return }
                c.autoApprove = true
                coordinator = c
                await c.resume()
            } else {
                guard let c = try? VaultCoordinator(config: cfg, transport: transport, chain: .signet, mnemonic: seed) else { return }
                c.autoApprove = true
                c.onVaultReady = { store.save($0) }
                coordinator = c
                await c.start()
            }
        }
    }
}
#endif
