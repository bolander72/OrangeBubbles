import BitcoinDevKit
import Foundation

/// Builds and watches P2WSH shared-vault wallets (ADR 0008, `p2wsh-v1`).
/// A vault has no single seed: each member contributes an xpub, and the
/// `sortedmulti` descriptor is assembled identically by everyone. This
/// engine derives the local member's cosigner xpub, assembles the watch
/// descriptor, and (once complete) syncs balance/addresses like any
/// other wallet. Signing accumulates PSBT signatures across members.
public final class VaultEngine {
    /// BIP48 multisig account path for P2WSH (script type 2').
    /// `m/48'/coin'/0'/2'`
    public static func cosignerPath(network: NetworkKind) -> String {
        let coin = network == .bitcoin ? "0" : "1"
        return "m/48'/\(coin)'/0'/2'"
    }

    /// Derives THIS device's cosigner xpub from the member's wallet seed —
    /// so restoring the main wallet restores vault membership.
    public static func cosignerXpub(mnemonic: String, network: NetworkKind) throws -> String {
        let bdkNetwork = network.bdkNetwork
        let m = try Mnemonic.fromString(mnemonic: mnemonic)
        let root = DescriptorSecretKey(network: bdkNetwork, mnemonic: m, password: nil)
        let path = try DerivationPath(path: Self.cosignerPath(network: network))
        let derived = try root.derive(path: path)
        // Public form: the xpub the other members combine into the descriptor.
        return derived.asPublic().asString()
    }

    /// Assembles the deterministic `wsh(sortedmulti(k, xpubs...))`
    /// descriptor. `sortedmulti` (BIP67) makes member order irrelevant —
    /// everyone derives the identical descriptor and addresses.
    public struct VaultDescriptors: Equatable, Sendable {
        public let external: String  // receive branch …/0/*
        public let change: String    // change branch …/1/*
    }

    public static func assembleDescriptor(
        threshold: Int,
        cosignerXpubs: [String],
        network: NetworkKind
    ) throws -> VaultDescriptors {
        precondition(cosignerXpubs.count >= threshold, "need at least k xpubs")
        // Canonically order the keys so every member stores a
        // byte-identical descriptor string (sortedmulti sorts per-address
        // for the script, but the descriptor text keeps input order).
        let cosignerXpubs = cosignerXpubs.sorted()
        func desc(_ branch: Int) throws -> String {
            // Cosigner xpubs arrive as "[origin]tpub…/*" — splice the
            // branch index in front of the terminal wildcard.
            let keys = cosignerXpubs.map { xpub -> String in
                xpub.hasSuffix("/*")
                    ? String(xpub.dropLast(2)) + "/\(branch)/*"
                    : xpub + "/\(branch)/*"
            }.joined(separator: ",")
            let d = "wsh(sortedmulti(\(threshold),\(keys)))"
            _ = try Descriptor(descriptor: d, network: network.bdkNetwork) // validate
            return d
        }
        return VaultDescriptors(external: try desc(0), change: try desc(1))
    }

    private let wallet: Wallet
    private let connection: Connection
    public let network: NetworkKind

    /// Opens a watch-only vault wallet from its assembled descriptors.
    public init(descriptors: VaultDescriptors, network: NetworkKind, storageDirectory: URL) throws {
        self.network = network
        let bdkNetwork = network.bdkNetwork
        let ext = try Descriptor(descriptor: descriptors.external, network: bdkNetwork)
        let chg = try Descriptor(descriptor: descriptors.change, network: bdkNetwork)

        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let dbPath = storageDirectory.appendingPathComponent("vault.sqlite").path
        self.connection = try Connection(path: dbPath)
        do {
            self.wallet = try Wallet.load(descriptor: ext, changeDescriptor: chg, connection: connection)
        } catch {
            self.wallet = try Wallet(descriptor: ext, changeDescriptor: chg, network: bdkNetwork, connection: connection)
        }
        _ = try? wallet.persist(connection: connection)
    }

    public func depositAddress() throws -> String {
        let info = wallet.revealNextAddress(keychain: .external)
        _ = try? wallet.persist(connection: connection)
        return info.address.description
    }

    public func balance() -> WalletBalance {
        let b = wallet.balance()
        return WalletBalance(
            confirmedSats: b.confirmed.toSat(),
            pendingSats: b.trustedPending.toSat() + b.untrustedPending.toSat() + b.immature.toSat()
        )
    }

    public func sync(esploraURL: URL) throws {
        let client = EsploraClient(url: esploraURL.absoluteString)
        do {
            let request = try wallet.startFullScan().build()
            let update = try client.fullScan(request: request, stopGap: 20, parallelRequests: 3)
            try wallet.applyUpdate(update: update)
        } catch let error as EsploraError {
            NSLog("vault sync failed: \(error)")
            throw WalletKitError.networkUnreachable
        }
        _ = try? wallet.persist(connection: connection)
    }
}
