import Foundation

/// A claimable gift (ADR 0005): a throwaway single-purpose wallet whose
/// mnemonic is the claim secret. The sender funds its first address; the
/// holder of the secret sweeps it. Built entirely on `WalletEngine`, so
/// sweep = the existing drain path.
public struct ClaimVoucher: Codable, Equatable, Sendable, Identifiable {
    public var id: String { address }

    /// The claim secret — 12 words. Whoever holds this holds the gift.
    public let mnemonic: String
    public let network: NetworkKind
    /// The voucher wallet's first receive address (what the sender funds).
    public let address: String
    public let amountSats: UInt64
    public let createdAt: Date
    public let expiresAt: Date

    /// Gifts below this can't reliably cover their own sweep fee.
    public static let minimumSats: UInt64 = 3_000
    public static let defaultLifetime: TimeInterval = 14 * 24 * 3600

    // MARK: - Lifecycle

    /// Generates a fresh voucher (not yet funded).
    public static func generate(
        network: NetworkKind,
        amountSats: UInt64,
        lifetime: TimeInterval = defaultLifetime
    ) throws -> ClaimVoucher {
        guard amountSats >= minimumSats else { throw WalletKitError.amountBelowDust }
        let secrets = WalletEngine.generateSecrets(network: network)
        let address = try firstAddress(mnemonic: secrets.mnemonic, network: network)
        return ClaimVoucher(
            mnemonic: secrets.mnemonic,
            network: network,
            address: address,
            amountSats: amountSats,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(lifetime)
        )
    }

    /// Rebuilds the deterministic claim address from a received secret.
    public static func firstAddress(mnemonic: String, network: NetworkKind) throws -> String {
        let engine = try ephemeralEngine(mnemonic: mnemonic, network: network)
        return try engine.nextReceiveAddress().address
    }

    /// Sweeps whatever the voucher holds to `destination`. Used by the
    /// recipient (claim) and the sender (cancel/reclaim) identically —
    /// the chain arbitrates races. Returns the sweep txid and amount.
    public static func sweep(
        mnemonic: String,
        network: NetworkKind,
        to destination: String,
        esploraURL: URL,
        feeRateSatPerVb: UInt64
    ) throws -> (txid: String, sweptSats: UInt64) {
        let engine = try ephemeralEngine(mnemonic: mnemonic, network: network)
        _ = try engine.nextReceiveAddress() // reveal index 0 so sync watches it
        try engine.sync(esploraURL: esploraURL, fullScan: true)

        let balance = engine.balance()
        guard balance.totalSats > 0 else {
            throw WalletKitError.internalError(
                "This gift has already been claimed (or the payment hasn't reached the network yet)."
            )
        }

        let send = try engine.createSignedDrain(to: destination, feeRateSatPerVb: feeRateSatPerVb)
        let txid = try engine.broadcast(send, esploraURL: esploraURL)
        return (txid, send.details.amountSats)
    }

    /// Voucher wallets live in a temp directory — their chain cache is
    /// disposable by definition.
    private static func ephemeralEngine(mnemonic: String, network: NetworkKind) throws -> WalletEngine {
        let secrets = WalletSecrets(mnemonic: mnemonic, network: network, scriptType: .bip84)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claim-\(UUID().uuidString)", isDirectory: true)
        return try WalletEngine(secrets: secrets, storageDirectory: dir)
    }

    // MARK: - Card payload

    public func queryItems() -> [URLQueryItem] {
        [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "m", value: mnemonic),
            URLQueryItem(name: "sats", value: String(amountSats)),
            URLQueryItem(name: "net", value: network.rawValue),
            URLQueryItem(name: "exp", value: String(Int(expiresAt.timeIntervalSince1970))),
        ]
    }

    public var isExpired: Bool {
        Date() > expiresAt
    }
}

extension ClaimVoucher {
    /// Parses a received claim card. The address is re-derived from the
    /// secret rather than trusted from the payload.
    public init?(queryItems: [URLQueryItem]) {
        func value(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }
        guard
            let mnemonic = value("m"),
            mnemonic.split(separator: " ").count == 12,
            let satsText = value("sats"), let sats = UInt64(satsText),
            let netText = value("net"), let network = NetworkKind(rawValue: netText),
            let address = try? Self.firstAddress(mnemonic: mnemonic, network: network)
        else { return nil }

        self.mnemonic = mnemonic
        self.network = network
        self.address = address
        self.amountSats = sats
        self.createdAt = Date()
        self.expiresAt = value("exp")
            .flatMap(Double.init)
            .map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(Self.defaultLifetime)
    }
}
