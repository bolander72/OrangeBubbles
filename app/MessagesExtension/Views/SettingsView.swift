import SwiftUI
import WalletKit

struct SettingsView: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    @State private var seedWords: [String]?
    @State private var migrating = false
    @State private var showSecurityExplainer = false

    var body: some View {
        NavigationStack {
            List {
                backupSection
                recoverySection
                aboutSection
            }
            .navigationTitle("Wallet Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
            }
        }
        .sheet(item: seedSheet) { words in
            SeedRevealView(words: words.items)
        }
        .sheet(isPresented: $showSecurityExplainer) {
            SecurityExplainerView(store: store)
        }
    }

    private var seedSheet: Binding<SeedWords?> {
        Binding(
            get: { seedWords.map(SeedWords.init) },
            set: { if $0 == nil { seedWords = nil } }
        )
    }

    // MARK: - Sections

    private var backupSection: some View {
        Section("Backup") {
            HStack {
                Label {
                    Text(store.backupInICloud ? "Backed up to iCloud" : "On this device only")
                } icon: {
                    Image(systemName: store.backupInICloud ? "checkmark.icloud.fill" : "icloud.slash.fill")
                        .foregroundStyle(store.backupInICloud ? .green : .orange)
                }
                Spacer()
            }

            if !store.backupInICloud {
                Button {
                    Task {
                        migrating = true
                        await store.ensureBackupInICloud()
                        migrating = false
                    }
                } label: {
                    if migrating {
                        ProgressView()
                    } else {
                        Label("Move backup to iCloud", systemImage: "icloud.and.arrow.up")
                    }
                }
                Text("Sign in to iCloud with iCloud Drive on, then tap to protect this wallet against losing your phone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Backup encryption", value: store.backupKeyProviderName)

            Button {
                showSecurityExplainer = true
            } label: {
                Label("Learn how you're protected", systemImage: "info.circle")
                    .font(.system(.body, design: .rounded).weight(.medium))
            }
            .accessibilityHint("Explains where your keys live and how backups are encrypted")
        }
    }

    private var recoverySection: some View {
        Section {
            Button {
                Task {
                    do {
                        seedWords = try await store.revealSeed()
                    } catch {
                        store.lastError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    }
                }
            } label: {
                Label("Reveal Recovery Phrase", systemImage: "key.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("The 12-word phrase is the wallet. Anyone who sees it can take your bitcoin. Only use this if you're moving to another wallet or making a paper backup.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Network", value: store.chain.network.rawValue.capitalized)
            LabeledContent(
                "Version",
                value: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
            )
            LabeledContent("Keys", value: "Generated & stored on device")
        }
    }
}

private struct SeedWords: Identifiable {
    let items: [String]
    var id: String { items.joined() }
}

/// Plain-English walkthrough of the security model — where the keys live,
/// what the backup is, and what Taproot Wizards can and can't see.
struct SecurityExplainerView: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    private var usesPasskey: Bool {
        store.backupKeyProviderName.localizedCaseInsensitiveContains("passkey")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    explainerCard(
                        icon: "iphone",
                        title: "Your keys live on this iPhone",
                        body: "The wallet is a 12-word secret generated on your device. It is never shown, uploaded, or shared — it only exists in this device's memory while the wallet is unlocked."
                    )

                    explainerCard(
                        icon: "lock.icloud.fill",
                        title: "Your backup lives in your iCloud",
                        body: usesPasskey
                            ? "An encrypted copy of the secret is stored in your personal iCloud Drive. The key that unlocks it comes from a passkey that requires your Face ID — nobody, including Apple or Taproot Wizards, can decrypt the backup without you."
                            : "An encrypted copy of the secret is stored in your personal iCloud Drive. The key that unlocks it lives in your iCloud Keychain, which Apple end-to-end encrypts to your devices. Neither Apple nor Taproot Wizards can read your backup."
                    )

                    explainerCard(
                        icon: "faceid",
                        title: "Face ID guards every action",
                        body: "Creating, unlocking, sending, and revealing the recovery phrase all require Face ID (or your device passcode)."
                    )

                    explainerCard(
                        icon: "arrow.triangle.2.circlepath.icloud",
                        title: "Losing your phone isn't losing your bitcoin",
                        body: "Sign into iCloud on a new iPhone, open Wizard Wallet, and unlock — the backup and its key sync down and the same wallet is rebuilt. The recovery phrase in Settings is a manual backstop on top of that."
                    )

                    explainerCard(
                        icon: "eye.slash.fill",
                        title: "No accounts. No servers. No tracking.",
                        body: "Taproot Wizards runs no server for this wallet and never sees your keys, balances, or activity. The app reads the Bitcoin network directly from public sources — like any other bitcoin node or explorer."
                    )
                }
                .padding(20)
            }
            .navigationTitle("How you're protected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .font(.system(.body, design: .rounded).weight(.medium))
                }
            }
        }
    }

    private func explainerCard(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBubble(systemName: icon, tint: Brand.orange, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                Text(body)
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

/// Full-screen, deliberately screenshot-unfriendly presentation of the
/// mnemonic: dark, no share/copy affordances, dismiss to hide.
struct SeedRevealView: View {
    let words: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                InfoBanner(
                    systemName: "eye.trianglebadge.exclamationmark.fill",
                    text: "Never share these words or type them into any website. Wizard Wallet will never ask for them.",
                    tint: .red
                )

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            Text(word)
                                .font(.system(.body, design: .monospaced).weight(.medium))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                    }
                }

                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Text("Done — hide the words")
                }
                .buttonStyle(ProminentButtonStyle())
            }
            .padding(20)
            .navigationTitle("Recovery Phrase")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
