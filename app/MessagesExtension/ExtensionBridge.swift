import Messages
import UIKit
import WalletKit

/// The SwiftUI layer's handle on Messages-framework capabilities:
/// presentation style, card insertion, and incoming card parsing.
@MainActor
final class ExtensionBridge: ObservableObject {
    weak var controller: MSMessagesAppViewController?
    var conversation: MSConversation?

    @Published var presentationStyle: MSMessagesAppPresentationStyle = .compact

    var isCompact: Bool { presentationStyle == .compact }

    func requestExpanded() {
        guard presentationStyle != .expanded else { return }
        controller?.requestPresentationStyle(.expanded)
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
