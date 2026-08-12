import SwiftUI
import WalletKit

/// DEBUG-only harness for the live multi-device FROST test (ADR 0008).
/// Vaults now persist (VaultStore): once DKG completes, the vault is saved
/// and reappears here — you can close the sheet, fund the address from your
/// main wallet, and come back to the SAME vault to propose spends.
struct VaultLabView: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    private let vaultStore = VaultStore()
    @State private var saved: [VaultRecord] = []
    @State private var coordinator: VaultCoordinator?

    // New-vault form
    @State private var relayHost = "192.168.1.46"
    @State private var vaultID = "testvault"
    @State private var memberIndex = 3
    @State private var memberCount = 3
    @State private var threshold = 2

    // Spend form
    @State private var destination = ""
    @State private var amountText = ""

    var body: some View {
        NavigationStack {
            Form {
                if let c = coordinator {
                    liveSection(c)
                } else {
                    savedSection
                    newVaultSection
                }
            }
            .navigationTitle("Vaults (FROST)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if coordinator != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Back") { coordinator = nil; saved = vaultStore.all() }
                    }
                }
            }
            .onAppear { saved = vaultStore.all() }
        }
    }

    // MARK: - Saved vaults (persisted — the fix for "it disappears")

    private var savedSection: some View {
        Section("Your vaults") {
            if saved.isEmpty {
                Text("No vaults yet. Create one below.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(saved) { record in
                Button {
                    resume(record)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.name).font(.body)
                        Text("\(record.thresholdLabel) · \(String(record.address.prefix(16)))…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { idx in
                idx.map { saved[$0].vaultID }.forEach(vaultStore.delete)
                saved = vaultStore.all()
            }
        }
    }

    private var newVaultSection: some View {
        Section("Create / join a vault") {
            TextField("Relay host (Mac IP; sims use 127.0.0.1)", text: $relayHost)
                .keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
            TextField("Vault ID (same on all devices)", text: $vaultID).autocorrectionDisabled()
            Stepper("I am member \(memberIndex)", value: $memberIndex, in: 1...memberCount)
            Stepper("Members (n): \(memberCount)", value: $memberCount, in: 2...5)
            Stepper("Threshold (k): \(threshold)", value: $threshold, in: 1...memberCount)
            Button {
                startDKG()
            } label: { Label("Join & run DKG", systemImage: "person.3.sequence.fill") }
        }
    }

    // MARK: - Live vault

    private func liveSection(_ c: VaultCoordinator) -> some View {
        Group {
            Section("Vault") {
                statusRow(c)
                if let addr = c.vaultAddress {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Deposit address").font(.caption).foregroundStyle(.secondary)
                        Text(addr).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }
                    Button { UIPasteboard.general.string = addr } label: {
                        Label("Copy deposit address", systemImage: "doc.on.doc")
                    }
                    HStack {
                        LabeledContent("Balance", value: "\(c.balanceSats) sats")
                        Spacer()
                        Button { Task { await c.refreshBalance() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }

            // Prominent spend status — the thing that was missing.
            if c.spendStatus != .none {
                Section("Spend status") { spendStatusView(c) }
            }

            if c.stage == .ready {
                Section("Propose a spend") {
                    TextField("Destination address", text: $destination)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Amount in sats (blank = sweep all)", text: $amountText)
                        .keyboardType(.numberPad)
                    if !destinationValid && !destination.isEmpty {
                        Text("Not a valid signet address").font(.caption).foregroundStyle(.red)
                    }
                    Button {
                        let amt = UInt64(amountText.filter(\.isNumber))
                        Task { await c.proposeSpend(to: destination.trimmingCharacters(in: .whitespaces), amountSats: amt) }
                    } label: {
                        if case .proposing = c.spendStatus {
                            HStack { ProgressView(); Text("Proposing…") }
                        } else {
                            Label("Propose spend", systemImage: "paperplane.fill")
                        }
                    }
                    .disabled(!canPropose(c))
                }
            }

            if let p = c.pendingProposal, !isBusy(c) {
                Section("Incoming proposal") {
                    LabeledContent("Amount", value: "\(p.amountSats) sats")
                    LabeledContent("To", value: String(p.destination.prefix(16)) + "…")
                    Button { Task { await c.approve(p) } } label: {
                        Label("Approve & sign", systemImage: "checkmark.seal.fill")
                    }
                }
            }

            Section("Activity") {
                if c.log.isEmpty {
                    Text("No activity yet").font(.caption).foregroundStyle(.secondary)
                }
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
        case .ready: return AnyView(Label("Ready", systemImage: "checkmark.shield.fill").foregroundStyle(.green))
        case .error(let e): return AnyView(Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red))
        }
    }

    @ViewBuilder
    private func spendStatusView(_ c: VaultCoordinator) -> some View {
        switch c.spendStatus {
        case .none:
            EmptyView()
        case .proposing:
            Label("Building proposal…", systemImage: "hourglass").foregroundStyle(.orange)
        case .awaitingSignatures(let have, let need):
            HStack {
                ProgressView()
                Text("Collecting signatures (\(have) of \(need))…")
            }.foregroundStyle(.orange)
        case .broadcasting:
            HStack { ProgressView(); Text("Broadcasting…") }.foregroundStyle(.orange)
        case .done(let txid):
            VStack(alignment: .leading, spacing: 6) {
                Label("Sent ✓", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Link(destination: URL(string: "https://mempool.space/signet/tx/\(txid)")!) {
                    Text("tx \(String(txid.prefix(20)))… — view").font(.caption)
                }
            }
        case .failed(let e):
            Label(e, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var destinationValid: Bool {
        store.isValidAddress(destination.trimmingCharacters(in: .whitespaces))
    }
    private func isBusy(_ c: VaultCoordinator) -> Bool {
        switch c.spendStatus {
        case .proposing, .awaitingSignatures, .broadcasting: return true
        default: return false
        }
    }
    private func canPropose(_ c: VaultCoordinator) -> Bool {
        guard destinationValid, !isBusy(c) else { return false }
        let amt = amountText.filter(\.isNumber)
        return amt.isEmpty || (UInt64(amt) ?? 0) >= 546
    }

    // MARK: - Actions

    private func transport(host: String) -> VaultTransport? {
        URL(string: "http://\(host):8781").map { DebugRelayTransport(baseURL: $0) }
    }

    private func startDKG() {
        guard let seed = store.debugMnemonic, let t = transport(host: relayHost) else { return }
        let memberSeed = FrostTestSeeds.seed(base: seed, memberIndex: memberIndex)
        let config = VaultCoordinator.Config(
            vaultID: vaultID, name: vaultID, memberIndex: UInt16(memberIndex),
            memberCount: UInt16(memberCount), threshold: UInt16(threshold),
            displayName: "Member \(memberIndex)")
        guard let c = try? VaultCoordinator(config: config, transport: t, chain: store.chain, mnemonic: memberSeed) else { return }
        var record: VaultRecord?
        c.onVaultReady = { r in
            var withHost = r; withHost.relayHost = relayHost
            vaultStore.save(withHost); record = withHost
        }
        _ = record
        coordinator = c
        Task { await c.start() }
    }

    private func resume(_ record: VaultRecord) {
        guard let seed = store.debugMnemonic,
              let t = transport(host: record.relayHost ?? relayHost) else { return }
        let memberSeed = FrostTestSeeds.seed(base: seed, memberIndex: Int(record.memberIndex))
        guard let c = try? VaultCoordinator(resuming: record, transport: t, chain: store.chain, mnemonic: memberSeed) else { return }
        coordinator = c
        Task { await c.resume() }
    }
}

/// Derives distinct per-member mnemonics from one base seed so the same
/// physical device can stand in for different members during testing.
enum FrostTestSeeds {
    static func seed(base: String, memberIndex: Int) -> String {
        (try? WalletEngine.deterministicMnemonic(from: "\(base)#frost-member-\(memberIndex)")) ?? base
    }
}
