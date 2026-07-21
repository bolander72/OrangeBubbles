import Foundation

/// Persists the encrypted `BackupEnvelope` as a single JSON document.
///
/// Preferred home: the app's iCloud Drive ubiquity container (survives
/// uninstall, syncs to the user's other devices). When iCloud is
/// unavailable (simulator without sign-in, iCloud Drive off) it falls back
/// to app-local storage so create/restore keep working — and migrates the
/// file into iCloud automatically the next time it becomes reachable.
public struct ICloudBackupStore: Sendable {
    public static let fileName = "wallet-backup.v1.json"
    /// The prior envelope, kept on every rewrite so one bad seal (or an
    /// interrupted write on a future OS) can never orphan the wallet.
    public static let previousFileName = "wallet-backup.v1.previous.json"

    private let containerIdentifier: String?
    /// Pre-rename wallets' backups live here; read-only fallback so an
    /// upgraded install finds its wallet, after which saves re-home it.
    private let legacyContainerIdentifier: String?
    private var fileManager: FileManager { FileManager.default }

    /// - Parameter containerIdentifier: pass nil for the app's first
    ///   ubiquity container from entitlements.
    public init(
        containerIdentifier: String? = nil,
        legacyContainerIdentifier: String? = "iCloud.com.bolandcompany.satchel"
    ) {
        self.containerIdentifier = containerIdentifier
        self.legacyContainerIdentifier = legacyContainerIdentifier
    }

    // MARK: - Locations

    public var isUsingICloud: Bool {
        fileManager.url(forUbiquityContainerIdentifier: containerIdentifier) != nil
    }

    private func icloudURL() -> URL? {
        icloudURL(in: containerIdentifier)
    }

    private func legacyICloudURL() -> URL? {
        guard let legacyContainerIdentifier else { return nil }
        return icloudURL(in: legacyContainerIdentifier)
    }

    private func icloudURL(in identifier: String?) -> URL? {
        guard let container = fileManager.url(forUbiquityContainerIdentifier: identifier) else {
            return nil
        }
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        try? fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        return documents.appendingPathComponent(Self.fileName)
    }

    private func fallbackURL() -> URL {
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WalletBackupLocal", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(Self.fileName)
    }

    // MARK: - API

    public func backupExists() -> Bool {
        for candidate in [icloudURL(), legacyICloudURL()].compactMap({ $0 }) {
            if fileManager.fileExists(atPath: candidate.path)
                || fileManager.isUbiquitousItem(at: candidate)
                || fileManager.fileExists(atPath: previousURL(for: candidate).path) {
                return true
            }
        }
        let fallback = fallbackURL()
        return fileManager.fileExists(atPath: fallback.path)
            || fileManager.fileExists(atPath: previousURL(for: fallback).path)
    }

    public func load() async throws -> BackupEnvelope {
        for icloud in [icloudURL(), legacyICloudURL()].compactMap({ $0 }) {
            if !fileManager.fileExists(atPath: icloud.path), fileManager.isUbiquitousItem(at: icloud) {
                // Ask iCloud to materialize the file, then poll briefly.
                try? fileManager.startDownloadingUbiquitousItem(at: icloud)
                for _ in 0..<40 where !fileManager.fileExists(atPath: icloud.path) {
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            if let envelope = decodeWithPreviousFallback(main: icloud) {
                return envelope
            }
        }
        if let icloud = icloudURL(), fileManager.fileExists(atPath: icloud.path) {
            throw WalletKitError.backupCorrupted("backup and its previous copy are both unreadable")
        }
        let fallback = fallbackURL()
        if let envelope = decodeWithPreviousFallback(main: fallback) {
            return envelope
        }
        if fileManager.fileExists(atPath: fallback.path) {
            throw WalletKitError.backupCorrupted("backup and its previous copy are both unreadable")
        }
        throw WalletKitError.backupNotFound
    }

    /// Writes to iCloud when reachable, else the local fallback. A
    /// successful iCloud write also cleans up any stale fallback copy —
    /// which is exactly how a local-only backup migrates once the user
    /// signs into iCloud.
    public func save(_ envelope: BackupEnvelope) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)

        if let icloud = icloudURL() {
            keepPreviousCopy(of: icloud)
            try coordinatedWrite(data, to: icloud)
            try? fileManager.removeItem(at: fallbackURL())
        } else {
            let fallback = fallbackURL()
            keepPreviousCopy(of: fallback)
            try data.write(to: fallback, options: .atomic)
        }
    }

    /// True when a backup exists but only on this device.
    public func hasLocalOnlyBackup() -> Bool {
        guard fileManager.fileExists(atPath: fallbackURL().path) else { return false }
        guard let icloud = icloudURL() else { return true }
        return !fileManager.fileExists(atPath: icloud.path) && !fileManager.isUbiquitousItem(at: icloud)
    }

    // MARK: - Internals

    private func previousURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(Self.previousFileName)
    }

    private func keepPreviousCopy(of url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let previous = previousURL(for: url)
        try? fileManager.removeItem(at: previous)
        try? fileManager.copyItem(at: url, to: previous)
    }

    /// Main file first; a corrupt or missing main falls back to the
    /// previous-generation envelope. Nil only when neither decodes.
    private func decodeWithPreviousFallback(main: URL) -> BackupEnvelope? {
        if fileManager.fileExists(atPath: main.path), let envelope = try? decode(at: main) {
            return envelope
        }
        let previous = previousURL(for: main)
        if fileManager.fileExists(atPath: previous.path), let envelope = try? decode(at: previous) {
            return envelope
        }
        return nil
    }

    private func decode(at url: URL) throws -> BackupEnvelope {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(BackupEnvelope.self, from: data)
        } catch {
            throw WalletKitError.backupCorrupted("undecodable envelope: \(error.localizedDescription)")
        }
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatorError) { dest in
            do {
                try data.write(to: dest, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let writeError { throw writeError }
    }
}
