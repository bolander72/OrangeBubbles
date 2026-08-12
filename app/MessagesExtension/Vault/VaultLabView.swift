import SwiftUI
import WalletKit

/// DEBUG-only harness for the live multi-device FROST test (ADR 0008).
/// Each device joins the same vault ID with a distinct member index and
/// coordinates over the debug relay. Not shipped; the product flow will
/// live in group-chat cards.
struct VaultLabView: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    @State private var relayHost = "192.168.1.46"
    @State private var vaultID = "testvault"
    @State private var memberIndex = 1
    @State private var memberCount = 3
    @State private var threshold = 2
    @State private var destination = ""
    @State private var amountText = ""
    @State private var coordinator: VaultCoordinator?

    var body: some View {
        NavigationStack {
            Form {
                if let c = coordinator {
                    liveSection(c)
                } else {
                    setupSection
                }
            }
            .navigationTitle("Vault Lab (FROST)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var setupSection: some View {
        Group {
            Section("Relay") {
                TextField("Relay host (Mac LAN IP)", text: $relayHost)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                Text("Simulators can use 127.0.0.1; the phone uses the Mac's Wi-Fi IP.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("This device's role") {
                TextField("Vault ID (same on all devices)", text: $vaultID)
                    .autocorrectionDisabled()
                Stepper("I am member \(memberIndex)", value: $memberIndex, in: 1...memberCount)
                Stepper("Members (n): \(memberCount)", value: $memberCount, in: 2...5)
                Stepper("Threshold (k): \(threshold)", value: $threshold, in: 1...memberCount)
            }
            Section {
                Button {
                    startCeremony()
                } label: {
                    Label("Join vault & run DKG", systemImage: "person.3.sequence.fill")
                }
            } footer: {
                Text("Start the relay on the Mac first (python3 frost/relay/relay.py). Each device: same Vault ID, different member number, matching n and k.")
            }
        }
    }

    private func liveSection(_ c: VaultCoordinator) -> some View {
        Group {
            Section("Vault") {
                statusRow(c)
                if let addr = c.vaultAddress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deposit address").font(.caption).foregroundStyle(.secondary)
                        Text(addr).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = addr
                    } label: { Label("Copy deposit address", systemImage: "doc.on.doc") }
                    LabeledContent("Balance", value: "\(Format.sats(c.balanceSats)) sats")
                    Button { Task { await c.refreshBalance() } } label: {
                        Label("Refresh balance", systemImage: "arrow.clockwise")
                    }
                }
            }

            if c.stage == .ready {
                Section("Propose a spend") {
                    TextField("Destination address", text: $destination)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Amount in sats (blank = sweep all)", text: $amountText)
                        .keyboardType(.numberPad)
                    Button {
                        let amt = UInt64(amountText.filter(\.isNumber))
                        Task { await c.proposeSpend(to: destination.trimmingCharacters(in: .whitespaces), amountSats: amt) }
                    } label: { Label("Propose spend", systemImage: "paperplane") }
                    .disabled(destination.isEmpty)
                }
            }

            if let p = c.pendingProposal {
                Section("Pending proposal") {
                    LabeledContent("Amount", value: "\(Format.sats(p.amountSats)) sats")
                    LabeledContent("To", value: Format.shortAddress(p.destination))
                    Button {
                        Task { await c.approve(p) }
                    } label: { Label("Approve & sign", systemImage: "checkmark.seal.fill") }
                }
            }

            Section("Activity") {
                ForEach(Array(c.log.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusRow(_ c: VaultCoordinator) -> some View {
        switch c.stage {
        case .idle: return AnyView(Text("Idle"))
        case .dkgInProgress(let s): return AnyView(Label("DKG: \(s)", systemImage: "hourglass").foregroundStyle(.orange))
        case .ready: return AnyView(Label("Vault ready", systemImage: "checkmark.shield.fill").foregroundStyle(.green))
        case .error(let e): return AnyView(Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red))
        }
    }

    private func startCeremony() {
        guard let seed = store.debugMnemonic,
              let url = URL(string: "http://\(relayHost):8781") else { return }
        let transport = DebugRelayTransport(baseURL: url)
        let config = VaultCoordinator.Config(
            vaultID: vaultID, name: vaultID, memberIndex: UInt16(memberIndex),
            memberCount: UInt16(memberCount), threshold: UInt16(threshold),
            displayName: "Member \(memberIndex)")
        // Each member needs a DISTINCT seed; derive a per-index one from the
        // wallet seed so a single device can also play different members.
        let memberSeed = FrostTestSeeds.seed(base: seed, memberIndex: memberIndex)
        guard let c = try? VaultCoordinator(config: config, transport: transport, chain: store.chain, mnemonic: memberSeed) else { return }
        coordinator = c
        Task { await c.start() }
    }
}

/// Derives distinct per-member mnemonics from one base seed so the same
/// physical device can stand in for different members during testing.
enum FrostTestSeeds {
    static func seed(base: String, memberIndex: Int) -> String {
        (try? WalletEngine.deterministicMnemonic(from: "\(base)#frost-member-\(memberIndex)")) ?? base
    }
}
