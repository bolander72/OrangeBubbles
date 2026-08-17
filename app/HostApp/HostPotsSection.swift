import SwiftUI
import WalletKit

/// Read-only pot list for the container app. Pots are created and managed in
/// Messages (the chat is a pot's home); here we surface the ones this device
/// is part of, with live balances, so you can check on them without digging
/// through conversations.
struct HostPotsSection: View {
    private let vaultStore = VaultStore()
    @State private var pots: [VaultRecord] = []
    @State private var balances: [String: UInt64] = [:]

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

    var body: some View {
        if !pots.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your pots")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                ForEach(pots) { pot in
                    HStack(spacing: 12) {
                        Text(pot.emoji ?? "🍯")
                            .font(.system(size: 26))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color(.tertiarySystemFill)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pot.name)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            Text("\(pot.memberCount) people · any \(pot.threshold) approve")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(balanceLabel(for: pot))
                            .font(.system(.subheadline, design: .rounded).weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemBackground)))
                }
                Text("Open the pot's group chat in Messages to chip in or spend.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .task { await refresh() }
        } else {
            // Still reload on appear so a pot created in Messages shows up
            // next time this screen is visited.
            Color.clear.frame(height: 0).task { await refresh() }
        }
    }

    private func balanceLabel(for pot: VaultRecord) -> String {
        guard let sats = balances[pot.vaultID] else { return "…" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return "\(f.string(from: NSNumber(value: sats)) ?? "\(sats)") sats"
    }

    private func refresh() async {
        pots = vaultStore.all().filter { !$0.archived }
        for pot in pots {
            let engine = FrostVaultEngine(vaultXonlyHex: pot.vaultXonlyHex, network: chain.network)
            for url in chain.esploraURLs {
                if let sats = try? await engine.balance(esploraURL: url) {
                    balances[pot.vaultID] = sats
                    break
                }
            }
        }
    }
}
