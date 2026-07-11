import AppIntents

/// Siri / Shortcuts / Spotlight / Apple Intelligence surface. Everything
/// here is read-only against the watch-only App Group snapshot — there is
/// deliberately NO send intent: irreversible money never moves by voice.
struct CheckBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Bitcoin Balance"
    static let description = IntentDescription(
        "Shows your Wizard Wallet balance.",
        categoryName: "Wallet"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let snapshot = SharedSnapshot.load() else {
            return .result(dialog: "Your wallet hasn't been opened yet — open Wizard Wallet in Messages first.")
        }
        var line = "Your balance is \(snapshot.balanceLine)"
        if let usd = snapshot.usdLine {
            line += " — about \(usd)"
        }
        if snapshot.pendingSats > 0 {
            line += ", with \(SharedSnapshot.formatSats(snapshot.pendingSats)) sats pending"
        }
        line += "."
        return .result(dialog: IntentDialog(stringLiteral: line))
    }
}

struct ReceiveAddressIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Bitcoin Address"
    static let description = IntentDescription(
        "Gives you a fresh address for receiving bitcoin.",
        categoryName: "Wallet"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard
            let snapshot = SharedSnapshot.load(),
            let address = snapshot.upcomingReceiveAddresses.first
        else {
            return .result(
                value: "",
                dialog: "Your wallet hasn't been opened yet — open Wizard Wallet in Messages first."
            )
        }
        return .result(
            value: address,
            dialog: IntentDialog(stringLiteral: "Here's a fresh receive address: \(address)")
        )
    }
}

struct WalletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckBalanceIntent(),
            phrases: [
                "What's my bitcoin balance in \(.applicationName)",
                "Check my \(.applicationName) balance",
                "How much bitcoin do I have in \(.applicationName)",
            ],
            shortTitle: "Balance",
            systemImageName: "bitcoinsign.circle.fill"
        )
        AppShortcut(
            intent: ReceiveAddressIntent(),
            phrases: [
                "Get a bitcoin address from \(.applicationName)",
                "New receive address in \(.applicationName)",
            ],
            shortTitle: "Receive Address",
            systemImageName: "qrcode"
        )
    }
}
