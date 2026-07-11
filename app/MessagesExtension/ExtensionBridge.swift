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
        components.host = "wallet.taprootwizards.com"
        components.path = kind == .request ? "/pay" : "/paid"
        components.queryItems = request.queryItems()

        let layout = MSMessageTemplateLayout()
        switch kind {
        case .request:
            layout.image = CardImageRenderer.render(kind: .request, request: request)
            layout.caption = "Tap to pay with Wizard Wallet"
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

    /// A tapped card opens the live status view (which offers Pay for
    /// unpaid requests). The card's session is kept so a status update can
    /// replace the bubble in place.
    func handleSelected(_ message: MSMessage, store: WalletStore) {
        guard
            let url = message.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems,
            let request = PaymentRequest(queryItems: items)
        else { return }

        selectedSession = message.session
        store.incomingRequest = IncomingCard(
            request: request,
            isReceipt: components.path == "/paid"
        )
        requestExpanded()
    }

    enum CardKind {
        case request
        case sent
    }
}

struct IncomingCard: Equatable, Identifiable {
    var request: PaymentRequest
    var isReceipt: Bool

    var id: String { "\(request.address)|\(request.txid ?? "")" }
}
