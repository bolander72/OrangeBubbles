import SwiftUI
import WalletKit

struct SettingsView: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    @State private var seedWords: [String]?
    @State private var migrating = false

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

            LabeledContent("Protected by", value: store.backupKeyProviderName)
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
