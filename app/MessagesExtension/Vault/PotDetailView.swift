import SwiftUI
import WalletKit

/// A single pot: hero balance, Add money / Spend, and a plain-language
/// spend-request flow. All threshold/signing language stays hidden.
struct PotDetailView: View {
    @ObservedObject var store: WalletStore
    @ObservedObject var coordinator: VaultCoordinator
    /// People in the current chat — used to frame members as "your group".
    var chatParticipantCount: Int = 0
    let onBack: () -> Void
    /// Archive the pot: hide it locally, keep the share, rejoin anytime. Silent
    /// and always safe — you remain a backup signer (ADR 0009).
    var onArchive: (() -> Void)? = nil
    /// Rebuild redundancy: start a fresh pot + move the funds over (ADR 0009).
    var onRefresh: (() -> Void)? = nil
    /// Destroy this device's share (irreversible). Guarded by a balance check.
    var onDelete: (() -> Void)? = nil

    @State private var showAdd = false
    @State private var showSpend = false
    @State private var confirmArchive = false
    @State private var confirmDelete = false

    /// Every pot in a chat shares the same people, so we frame members as the
    /// chat's group rather than a per-pot roster.
    private var inGroupChat: Bool { chatParticipantCount >= 2 }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                balanceCard
                if coordinator.redundancyBuffer <= 0 { healthCard }
                actionRow
                membersCard
                if onArchive != nil || onDelete != nil { manageCard }
                if coordinator.spendStatus != .none { spendStatusCard }
                if let p = coordinator.pendingProposal, !isProposerBusy { incomingRequestCard(p) }
                activityCard
            }
            .padding(20)
        }
        .refreshable { await coordinator.refreshBalance() }
        .confirmationDialog("Archive this pot?", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Archive pot") { onArchive?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It moves to Archived and stops showing here. Your share stays on this phone — you're still a backup signer, and you can rejoin anytime.")
        }
        .confirmationDialog("Delete this pot?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete pot", role: .destructive) { onDelete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This destroys your key share (here and in iCloud). It can't be undone and you can't rejoin. Archive instead if you might want back in.")
        }
        .sheet(isPresented: $showAdd) { AddMoneySheet(coordinator: coordinator, store: store) }
        .sheet(isPresented: $showSpend) { SpendSheet(coordinator: coordinator, store: store) }
        .task { await coordinator.refreshBalance() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(coordinator.config.emoji ?? potEmoji(for: coordinator.config.name)).font(.system(size: 52))
            Text(coordinator.config.name)
                .font(.system(.title2, design: .rounded).weight(.bold))
            Text(inGroupChat ? "Shared with everyone in this chat" : "Shared with your group")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Pot health (ADR 0009)

    /// Shown when the redundancy buffer is gone (someone left) or the pot is
    /// unspendable. Plain language — no "threshold" jargon.
    private var healthCard: some View {
        let frozen = coordinator.redundancyBuffer < 0
        return VStack(alignment: .leading, spacing: 10) {
            Label(frozen ? "This pot is stuck" : "No backup left",
                  systemImage: frozen ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(frozen ? .red : Brand.orangeDeep)
            Text(frozen
                 ? "Too many people have left — there aren't enough left to move the money. You'll need someone who left to come back and help once."
                 : "Someone stepped out, so there's no spare signer. If one more person loses their phone, the money could get stuck. Move it to a fresh pot with the people who are still active.")
                .font(.caption).foregroundStyle(.secondary)
            if !frozen, onRefresh != nil {
                Button { onRefresh?() } label: {
                    Label("Refresh pot", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
                }.buttonStyle(ProminentButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill((frozen ? Color.red : Brand.orange).opacity(0.12)))
    }

    /// Sits right under "Your group": the discoverable place to archive (hide,
    /// keep your share, rejoin) or delete (destroy your share — guarded).
    private var manageCard: some View {
        VStack(spacing: 0) {
            if onArchive != nil {
                Button { confirmArchive = true } label: {
                    manageRow(icon: "archivebox", title: "Archive pot",
                              subtitle: "Hide it, keep your share, rejoin anytime")
                }
                .buttonStyle(.plain)
            }
            if onArchive != nil, onDelete != nil { Divider().padding(.leading, 52) }
            if onDelete != nil {
                Button { confirmDelete = true } label: {
                    manageRow(icon: "trash", title: "Delete pot",
                              subtitle: coordinator.balanceSats > 0
                                  ? "Move the money out first"
                                  : "Destroys your share — can't be undone",
                              destructive: coordinator.balanceSats == 0)
                }
                .buttonStyle(.plain)
                // Can't destroy your share while there's money in the pot.
                .disabled(coordinator.balanceSats > 0)
            }
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func manageRow(icon: String, title: String, subtitle: String, destructive: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(destructive ? .red : .primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(destructive ? .red : .primary)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    private var balanceCard: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(SharedSnapshot.formatSats(coordinator.balanceSats).replacingOccurrences(of: " sats", with: ""))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Brand.gradient)
                    .contentTransition(.numericText())
                Text("sats").font(.system(.headline, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
            }
            if let usd = store.usdApprox(coordinator.balanceSats) {
                Text(usd).font(.system(.caption, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Brand.subtleGradient))
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button { showAdd = true } label: { Label("Add money", systemImage: "arrow.down.left") }
                .buttonStyle(ProminentButtonStyle())
            Button { showSpend = true } label: { Label("Spend", systemImage: "arrow.up.right") }
                .buttonStyle(QuietButtonStyle())
                .disabled(coordinator.balanceSats == 0 || coordinator.stage != .ready)
                .opacity(coordinator.balanceSats == 0 ? 0.5 : 1)
        }
    }

    private var membersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(inGroupChat ? "Your group" : "People in this pot")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Text("\(coordinator.joined.count) of \(coordinator.config.memberCount) joined")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(1...Int(coordinator.config.memberCount), id: \.self) { i in
                memberRow(index: UInt16(i))
            }
            Text(ruleExplanation)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    /// Anonymous member slot — no names (iMessage shows the real people in the
    /// chat). Just you-vs-others and whether they've joined this pot yet.
    private func memberRow(index: UInt16) -> some View {
        let isSelf = index == coordinator.config.memberIndex
        let hasJoined = coordinator.joined.contains(index)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(hasJoined ? avatarColor(index) : Color.gray.opacity(0.25))
                    .frame(width: 34, height: 34)
                Image(systemName: "person.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(hasJoined ? 1 : 0.7))
            }
            Text(isSelf ? "You" : (hasJoined ? "In the group" : "Waiting to join…"))
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(hasJoined || isSelf ? .primary : .secondary)
            Spacer()
            if hasJoined {
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            }
        }
    }

    private func avatarColor(_ i: UInt16) -> Color {
        [Brand.orange, .blue, .purple, .green, .pink, .teal][Int(i) % 6]
    }

    private var ruleExplanation: String {
        let k = coordinator.config.threshold, n = coordinator.config.memberCount
        if k == n { return "Every person must approve each spend." }
        if k == 2 { return "Any 2 people can approve a spend — so one phone can be lost and the money's still safe." }
        return "Any \(k) of \(n) people can approve a spend."
    }

    private var spendStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch coordinator.spendStatus {
            case .none: EmptyView()
            case .proposing:
                progressRow("Setting up the request…")
            case .awaitingSignatures(let have, let need):
                progressRow("Waiting for approvals — \(have) of \(need) so far")
            case .broadcasting:
                progressRow("Sending…")
            case .done(let txid):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Sent! 🎉", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                    Link(destination: store.chain.explorerURL(txid: txid)) {
                        Text("View transaction").font(.caption)
                    }
                }
            case .failed(let e):
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func progressRow(_ s: String) -> some View {
        HStack(spacing: 10) { ProgressView(); Text(s).font(.system(.subheadline, design: .rounded)) }
            .foregroundStyle(Brand.orangeDeep)
    }

    private func incomingRequestCard(_ p: VaultCoordinator.Proposal) -> some View {
        VStack(spacing: 10) {
            Text("Someone wants to spend")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
            Text("\(SharedSnapshot.formatSats(p.amountSats))")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.gradient)
            Text("to \(String(p.destination.prefix(14)))…")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Button { Task { await coordinator.approve(p) } } label: {
                Label("Approve", systemImage: "checkmark.seal.fill").frame(maxWidth: .infinity)
            }.buttonStyle(ProminentButtonStyle())
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Brand.subtleGradient))
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity").font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)
            if coordinator.activity.isEmpty {
                Text("Nothing yet.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(Array(coordinator.activity.enumerated().reversed().prefix(8)), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private var isProposerBusy: Bool {
        switch coordinator.spendStatus {
        case .proposing, .broadcasting: return true
        default: return false
        }
    }
}

/// "Add money" — the deposit address as a friendly receive card.
private struct AddMoneySheet: View {
    @ObservedObject var coordinator: VaultCoordinator
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Add money to \(coordinator.config.name)")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)
                    if let addr = coordinator.vaultAddress {
                        if let qr = QRCodeGenerator.image(for: "bitcoin:\(addr)") {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                                .frame(maxWidth: 210).padding(12)
                                .background(RoundedRectangle(cornerRadius: 18).fill(.white))
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Brand.gradient))
                        }
                        Button {
                            UIPasteboard.general.string = addr
                            copied = true; Haptics.tap()
                        } label: {
                            Label(copied ? "Copied!" : "Copy address", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }.buttonStyle(QuietButtonStyle())
                        Text("Send bitcoin here from any wallet to fill the pot. Everyone in the group shares this pot.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        ProgressView()
                    }
                }.padding(20)
            }
            .navigationTitle("Add money").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// "Spend" — request a spend in plain language.
private struct SpendSheet: View {
    @ObservedObject var coordinator: VaultCoordinator
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var amountText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Send to") {
                    TextField("Bitcoin address", text: $destination, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button {
                        if let s = UIPasteboard.general.string {
                            destination = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            Haptics.tap()
                        }
                    } label: {
                        Label("Paste address", systemImage: "doc.on.clipboard")
                            .font(.system(.subheadline, design: .rounded))
                    }
                    if !destination.isEmpty && !valid {
                        Text("That's not a valid address").font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Amount") {
                    TextField("Sats (blank = everything)", text: $amountText).keyboardType(.numberPad)
                    Text("Available: \(SharedSnapshot.formatSats(coordinator.balanceSats))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        let amt = UInt64(amountText.filter(\.isNumber))
                        Task {
                            await coordinator.proposeSpend(to: destination.trimmingCharacters(in: .whitespaces), amountSats: amt)
                            dismiss()
                        }
                    } label: {
                        Label("Ask to spend", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ProminentButtonStyle())
                    .disabled(!canAsk)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                } footer: {
                    Text("Your group will be asked to approve. Once enough say yes, the money is sent.")
                }
            }
            .navigationTitle("Spend from pot").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var valid: Bool { store.isValidAddress(destination.trimmingCharacters(in: .whitespaces)) }
    private var canAsk: Bool {
        guard valid else { return false }
        let a = amountText.filter(\.isNumber)
        return a.isEmpty || (UInt64(a) ?? 0) >= 546
    }
}
