import Foundation

/// A shared vault (ADR 0008): a k-of-n bitcoin account coordinated through
/// an iMessage group chat. This layer is **protocol-agnostic** — it
/// describes membership, threshold, and lifecycle without committing to a
/// signing scheme, so `p2wsh-v1` (shipping) and `frost-v1` (research) are
/// both just a `SigningProtocol` value.
public enum SigningProtocol: String, Codable, Sendable {
    /// Native P2WSH `sortedmulti` — visible on-chain, fee grows with n,
    /// battle-tested. The v1 shipping target.
    case p2wshV1 = "p2wsh-v1"
    /// FROST aggregate Taproot key — single-sig-indistinguishable,
    /// flat fee, re-dealable membership. Research track; gated by
    /// ADR 0008 §8 before it can be selected in a real vault.
    case frostV1 = "frost-v1"

    public var isProduction: Bool { self == .p2wshV1 }
}

/// One participant's public contribution to the vault: the cosigner xpub
/// (P2WSH) or FROST verifying share, plus a stable identity for the UI.
public struct VaultMember: Codable, Equatable, Sendable, Identifiable {
    /// Stable per-vault member id (assigned at join, order-independent).
    public let id: String
    /// Display name captured from the chat at join time (advisory).
    public var displayName: String
    /// Public key material — an xpub for P2WSH; opaque per protocol.
    public let publicKey: String
    /// True for the member on this device.
    public var isSelf: Bool

    public init(id: String, displayName: String, publicKey: String, isSelf: Bool) {
        self.id = id
        self.displayName = displayName
        self.publicKey = publicKey
        self.isSelf = isSelf
    }
}

public struct Vault: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public let threshold: Int          // k
    public let memberCount: Int        // n (target; members fills in as they join)
    public let signingProtocol: SigningProtocol
    public let network: NetworkKind
    public var members: [VaultMember]
    /// The watch descriptors (external\nchange), set once all members
    /// have joined.
    public var descriptorExternal: String?
    public var descriptorChange: String?
    public let createdAt: Date

    public var isComplete: Bool { members.count == memberCount && descriptorExternal != nil }
    public var isSelfMember: Bool { members.contains { $0.isSelf } }

    /// "2 of 3", for headers.
    public var thresholdLabel: String { "\(threshold) of \(memberCount)" }

    public init(
        id: String,
        name: String,
        threshold: Int,
        memberCount: Int,
        signingProtocol: SigningProtocol,
        network: NetworkKind,
        members: [VaultMember],
        descriptorExternal: String? = nil,
        descriptorChange: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.threshold = threshold
        self.memberCount = memberCount
        self.signingProtocol = signingProtocol
        self.network = network
        self.members = members
        self.descriptorExternal = descriptorExternal
        self.descriptorChange = descriptorChange
        self.createdAt = createdAt
    }
}

/// Common threshold presets with plain-language consequences (ADR 0008 §6).
public struct ThresholdPreset: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let threshold: Int
    public let memberCount: Int

    public static let all: [ThresholdPreset] = [
        .init(id: "2of2", title: "Both of us", detail: "Every spend needs both people. Lose either phone and the funds are stuck — pick “Any 2 of 3” instead if that worries you.", threshold: 2, memberCount: 2),
        .init(id: "2of3", title: "Any 2 of 3", detail: "Any two of three approve each spend. One phone can be lost or stolen and the money is still safe and spendable. Recommended.", threshold: 2, memberCount: 3),
        .init(id: "3of5", title: "Any 3 of 5", detail: "For larger groups: any three of five approve. Survives losing up to two members.", threshold: 3, memberCount: 5),
    ]
}
