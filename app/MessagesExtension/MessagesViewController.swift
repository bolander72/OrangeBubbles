import Messages
import SwiftUI
import UIKit

/// Entry point for the iMessage app. Hosts the SwiftUI tree and forwards
/// Messages-framework lifecycle events into `ExtensionBridge`/`WalletStore`.
final class MessagesViewController: MSMessagesAppViewController {
    private let bridge = ExtensionBridge()
    private let store = WalletStore()

    override func viewDidLoad() {
        super.viewDidLoad()
        bridge.controller = self
        store.presentationAnchor = { [weak self] in self?.view.window }

        let hosting = UIHostingController(rootView: RootView(store: store, bridge: bridge))
        addChild(hosting)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hosting.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        bridge.conversation = conversation
        bridge.presentationStyle = presentationStyle
        if let selected = conversation.selectedMessage {
            bridge.handleSelected(selected, store: store)
        }
        Task { await store.start() }
    }

    override func didSelect(_ message: MSMessage, conversation: MSConversation) {
        super.didSelect(message, conversation: conversation)
        bridge.conversation = conversation
        bridge.handleSelected(message, store: store)
    }

    override func didTransition(to presentationStyle: MSMessagesAppPresentationStyle) {
        super.didTransition(to: presentationStyle)
        bridge.presentationStyle = presentationStyle
    }
}
