import CryptoKit
import Messages
import UIKit
import WalletKit

/// The SwiftUI layer's handle on Messages-framework capabilities:
/// presentation style, card insertion, and incoming card parsing.
@MainActor
final class ExtensionBridge: ObservableObject {
    weak var controller: MSMessagesAppViewController?
    var conversation: MSConversation? {
        didSet { recomputeChatIdentity() }
    }

    @Published var presentationStyle: MSMessagesAppPresentationStyle = .compact

    /// A stable fingerprint of the current chat, derived from the set of
    /// participant UUIDs Messages exposes. Apple guarantees these identifiers
    /// are identical across every member's device for the same conversation,
    /// so the fingerprint is the same for everyone — letting us bind a pot to
    /// a chat without ever seeing a name or number (the sandbox forbids that).
    /// nil in a 1:1 or when there are no remote participants yet.
    @Published private(set) var chatKey: String?
    /// How many people are in the current chat (including you).
    @Published private(set) var chatParticipantCount = 0

    var isCompact: Bool { presentationStyle == .compact }

    private func recomputeChatIdentity() {
        guard let conversation else { chatKey = nil; chatParticipantCount = 0; return }
        let ids = ([conversation.localParticipantIdentifier]
                   + conversation.remoteParticipantIdentifiers)
            .map(\.uuidString).sorted()
        chatParticipantCount = ids.count
        // A group chat is 3+ (you + 2). A 1:1 has a single remote; still
        // fingerprintable, but pots are a group concept, so we key on any
        // chat that has at least one other person.
        guard conversation.remoteParticipantIdentifiers.isEmpty == false else { chatKey = nil; return }
        let digest = SHA256.hash(data: Data(ids.joined(separator: "|").utf8))
        chatKey = digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// This device's member slot in the chat, assigned WITHOUT any coordinator:
    /// everyone sorts the same participant-UUID set (Apple guarantees it's
    /// identical across devices) and takes their own 1-based position. So slot
    /// assignment is deterministic and collision-free with zero negotiation —
    /// the trustless, serverless way to give each member a distinct FROST index.
    /// Returns (index, memberCount), or nil outside a group chat.
    var memberSlot: (index: UInt16, count: UInt16)? {
        guard let conversation, !conversation.remoteParticipantIdentifiers.isEmpty else { return nil }
        let local = conversation.localParticipantIdentifier.uuidString
        let ids = ([conversation.localParticipantIdentifier]
                   + conversation.remoteParticipantIdentifiers)
            .map(\.uuidString).sorted()
        guard let pos = ids.firstIndex(of: local) else { return nil }
        return (UInt16(pos + 1), UInt16(ids.count))
    }

    // MARK: - Pot invite card

    /// The invite card is a SEND-ONCE human touchpoint ("Join our pot"). The
    /// DKG/signing rounds do NOT ride cards back and forth — they sync over
    /// CloudKit (see CloudKitTransport). Tapping the card just opens the pot to
    /// join; nobody ever sends a card back.
    ///
    /// The app sets this to route a tapped invite to the active pot controller.
    /// Buffered for cold start (tapping a card launches the extension before the
    /// controller exists).
    var onPotInvite: ((PotInvite) -> Void)? {
        didSet {
            if let invite = pendingInvite, let handler = onPotInvite {
                pendingInvite = nil
                handler(invite)
            }
        }
    }
    private var pendingInvite: PotInvite?

    private func routeInvite(_ invite: PotInvite) {
        if let handler = onPotInvite { handler(invite) } else { pendingInvite = invite }
    }

    /// Insert the "Join our pot" invite card into the compose field. Sent once
    /// by the creator; the user taps iMessage's Send. We never auto-send, and
    /// there is never a card to send *back*.
    func insertInviteCard(for invite: PotInvite) {
        guard let conversation else { return }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.boland.co"
        components.path = "/pot"
        components.queryItems = invite.queryItems()

        let layout = MSMessageTemplateLayout()
        layout.caption = "\(invite.emoji) \(invite.name)"
        layout.subcaption = "Tap to join · \(invite.ruleLine)"
        layout.trailingCaption = "Tap"

        let message = MSMessage(session: MSSession())
        message.url = components.url
        message.layout = layout
        message.summaryText = "🍯 Shared pot"
        conversation.insert(message) { [weak self] error in
            if let error { NSLog("pot invite insert failed: \(error)"); return }
            // Collapse so the staged card + Send button are visible.
            Task { @MainActor in self?.requestCompact() }
        }
    }

    func requestExpanded() {
        guard presentationStyle != .expanded else { return }
        controller?.requestPresentationStyle(.expanded)
    }

    /// Collapse to compact so the transcript + compose field (with a staged
    /// card) are visible — the user still has to tap iMessage's Send.
    func requestCompact() {
        guard presentationStyle != .compact else { return }
        controller?.requestPresentationStyle(.compact)
    }

    /// Bounces the user into the container app (passkey ceremonies run
    /// there). Falls back silently; Settings shows manual instructions.
    func openHostApp(_ action: String = "upgrade") {
        guard let url = URL(string: "orangebubbles://\(action)") else { return }
        controller?.extensionContext?.open(url, completionHandler: nil)
    }

    // MARK: - Cards

    /// Session of the card the user most recently tapped in the transcript.
    /// Reusing it when inserting an update makes Messages replace that
    /// bubble in place instead of appending a new one.
    private var selectedSession: MSSession?

    /// Inserts a payment-request (or payment-status) card into the compose field.
    /// The user still taps the iMessage send button — we never auto-send.
    func insertCard(for request: PaymentRequest, kind: CardKind, updateSelectedCard: Bool = false) {
        guard let conversation else { return }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.boland.co"
        components.path = kind == .request ? "/pay" : "/paid"
        components.queryItems = request.queryItems()

        let layout = MSMessageTemplateLayout()
        switch kind {
        case .request:
            layout.image = CardImageRenderer.render(kind: .request, request: request)
            layout.caption = "Tap to pay with OrangeBubbles"
        case .sent:
            layout.image = CardImageRenderer.render(kind: .receipt, request: request)
            layout.caption = "Tap to view details"
        }

        let session = (updateSelectedCard ? selectedSession : nil) ?? MSSession()
        let message = MSMessage(session: session)
        message.url = components.url
        message.layout = layout
        message.summaryText = kind == .request ? "₿ Bitcoin payment request" : "₿ Payment sent"

        conversation.insert(message) { error in
            if let error { NSLog("card insert failed: \(error)") }
        }
    }

    /// Inserts a claimable-gift card (ADR 0005). The voucher secret rides
    /// in the message URL — end-to-end encrypted by iMessage.
    func insertClaimCard(for voucher: ClaimVoucher) {
        guard let conversation else { return }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.boland.co"
        components.path = "/claim"
        components.queryItems = voucher.queryItems()

        let layout = MSMessageTemplateLayout()
        layout.image = CardImageRenderer.render(
            kind: .gift,
            request: PaymentRequest(address: voucher.address, amountSats: voucher.amountSats)
        )
        layout.caption = "Tap to claim with OrangeBubbles"

        let message = MSMessage(session: MSSession())
        message.url = components.url
        message.layout = layout
        message.summaryText = "₿ Bitcoin gift"

        conversation.insert(message) { error in
            if let error { NSLog("claim card insert failed: \(error)") }
        }
    }

    /// A tapped card opens the matching view: live status (payment cards)
    /// or the claim screen (gift cards). The card's session is kept so a
    /// status update can replace the bubble in place.
    func handleSelected(_ message: MSMessage, store: WalletStore) {
        guard
            let url = message.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems
        else { return }

        selectedSession = message.session

        switch components.path {
        case "/pot":
            // Tapping the invite opens the pot to join — the rounds sync over
            // CloudKit, so there is nothing to send back.
            if let items = components.queryItems, let invite = PotInvite(queryItems: items) {
                routeInvite(invite)
            }
            requestExpanded()
            return
        case "/claim":
            // Voucher parsing derives the claim address from the secret —
            // a real wallet-engine construction — so keep it off-main.
            Task { [weak store] in
                let voucher = await Task.detached { ClaimVoucher(queryItems: items) }.value
                guard let voucher, let store else { return }
                store.incomingRequest = IncomingCard(kind: .claim(voucher))
            }
        default:
            guard let request = PaymentRequest(queryItems: items) else { return }
            store.incomingRequest = IncomingCard(
                kind: .payment(request, isReceipt: components.path == "/paid")
            )
        }
        requestExpanded()
    }

    enum CardKind {
        case request
        case sent
    }
}

struct IncomingCard: Equatable, Identifiable {
    enum Kind: Equatable {
        case payment(PaymentRequest, isReceipt: Bool)
        case claim(ClaimVoucher)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .payment(let request, let isReceipt):
            return "p|\(request.address)|\(request.txid ?? "")|\(isReceipt)"
        case .claim(let voucher):
            return "c|\(voucher.address)"
        }
    }
}
