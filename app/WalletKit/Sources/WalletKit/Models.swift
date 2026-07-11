import Foundation

public enum NetworkKind: String, Codable, Sendable, CaseIterable {
    case bitcoin
    case testnet
    case signet
    case regtest
}

public enum ScriptType: String, Codable, Sendable {
    /// BIP84 native SegWit (bc1q…) — V0 default for maximum sender compatibility.
    case bip84
    /// BIP86 Taproot (bc1p…) — supported by the engine; not the default yet.
    case bip86
}

/// The plaintext secret bundle. This is what gets encrypted into a
/// `BackupEnvelope`; it must never be persisted or logged in the clear.
public struct WalletSecrets: Codable, Equatable, Sendable {
    public var version: Int
    public var mnemonic: String
    public var network: NetworkKind
    public var scriptType: ScriptType
    /// Highest revealed indexes at backup time — restore hints only; a chain
    /// rescan is still authoritative.
    public var receiveIndexHint: UInt32
    public var changeIndexHint: UInt32
    public var createdAt: Date

    public init(
        version: Int = 1,
        mnemonic: String,
        network: NetworkKind,
        scriptType: ScriptType,
        receiveIndexHint: UInt32 = 0,
        changeIndexHint: UInt32 = 0,
        createdAt: Date = Date()
    ) {
        self.version = version
        self.mnemonic = mnemonic
        self.network = network
        self.scriptType = scriptType
        self.receiveIndexHint = receiveIndexHint
        self.changeIndexHint = changeIndexHint
        self.createdAt = createdAt
    }
}

/// What actually lands in the user's iCloud container: ciphertext plus the
/// non-secret metadata needed to decrypt and interpret it later.
public struct BackupEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    /// AEAD + KDF identifier, e.g. "chacha20poly1305+hkdf-sha256".
    public var cipher: String
    /// Which key path produced the encryption key: "synced-keychain" or "passkey-prf".
    public var keyProvider: String
    /// HKDF salt, base64.
    public var salt: String
    /// ChaChaPoly combined box (nonce ‖ ciphertext ‖ tag), base64.
    public var sealed: String
    /// Non-secret hints so the restore UI can describe the wallet before unlock.
    public var network: NetworkKind
    public var scriptType: ScriptType
    public var createdAt: Date

    public init(
        version: Int = 1,
        cipher: String,
        keyProvider: String,
        salt: String,
        sealed: String,
        network: NetworkKind,
        scriptType: ScriptType,
        createdAt: Date = Date()
    ) {
        self.version = version
        self.cipher = cipher
        self.keyProvider = keyProvider
        self.salt = salt
        self.sealed = sealed
        self.network = network
        self.scriptType = scriptType
        self.createdAt = createdAt
    }
}

public struct WalletBalance: Equatable, Sendable {
    public var confirmedSats: UInt64
    public var pendingSats: UInt64
    public var totalSats: UInt64 { confirmedSats + pendingSats }

    public init(confirmedSats: UInt64, pendingSats: UInt64) {
        self.confirmedSats = confirmedSats
        self.pendingSats = pendingSats
    }
}

public struct WalletTransaction: Identifiable, Equatable, Sendable {
    public enum Direction: Sendable { case incoming, outgoing }

    public var id: String { txid }
    public var txid: String
    public var direction: Direction
    /// Net effect on the wallet in sats (always positive; see `direction`).
    public var amountSats: UInt64
    public var feeSats: UInt64?
    public var confirmed: Bool
    public var timestamp: Date?

    public init(
        txid: String,
        direction: Direction,
        amountSats: UInt64,
        feeSats: UInt64?,
        confirmed: Bool,
        timestamp: Date?
    ) {
        self.txid = txid
        self.direction = direction
        self.amountSats = amountSats
        self.feeSats = feeSats
        self.confirmed = confirmed
        self.timestamp = timestamp
    }
}

public struct PreparedSend: Sendable {
    public var destinationAddress: String
    public var amountSats: UInt64
    public var feeSats: UInt64
    public var totalSats: UInt64 { amountSats + feeSats }
}

/// Outputs below this are non-standard and unrelayable ("dust").
public let dustLimitSats: UInt64 = 546

public enum WalletKitError: LocalizedError {
    case invalidAddress(String)
    case insufficientFunds
    case amountBelowDust
    case networkUnreachable
    case feeBumpNotPossible(String)
    case backupNotFound
    case backupCorrupted(String)
    case keyUnavailable(String)
    case icloudUnavailable
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let a): return "Invalid Bitcoin address: \(a)"
        case .insufficientFunds: return "Not enough funds to cover the amount plus network fees."
        case .amountBelowDust: return "Amount is too small to send on the Bitcoin network — the minimum is \(dustLimitSats) sats."
        case .networkUnreachable: return "Couldn't reach the Bitcoin network. Check your connection and try again."
        case .feeBumpNotPossible(let why): return "Can't speed this payment up: \(why)"
        case .backupNotFound: return "No wallet backup found in iCloud."
        case .backupCorrupted(let why): return "Wallet backup could not be read: \(why)"
        case .keyUnavailable(let why): return "Encryption key unavailable: \(why)"
        case .icloudUnavailable: return "iCloud is not available. Sign in to iCloud and enable iCloud Drive."
        case .internalError(let why): return why
        }
    }
}
