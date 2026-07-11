import Foundation
import WalletKit

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// Turns a human phrase into sats. Deterministic parser first ("$5",
/// "0.5 btc", "21k sats"); when that fails and Apple Intelligence is
/// available (iOS 26+), the on-device foundation model has a go at
/// freeform phrases ("twenty bucks", "half a million sats"). Entirely
/// on-device either way — nothing leaves the phone.
enum SmartAmountAI {
    static func parse(_ text: String, store: WalletStore) async -> UInt64? {
        if let parsed = SmartAmount.parse(text), let sats = await MainActor.run(body: { store.satsFor(parsed) }) {
            return sats
        }
        return await modelParse(text, usdPerBTC: await MainActor.run(body: { store.usdPerBTC }))
    }

    private static func modelParse(_ text: String, usdPerBTC: Double?) async -> UInt64? {
        #if canImport(FoundationModels)
            guard #available(iOS 26.0, *) else { return nil }
            guard case .available = SystemLanguageModel.default.availability else { return nil }

            let rateLine = usdPerBTC.map { "1 BTC = \(Int($0)) USD." } ?? "No USD rate is known; refuse dollar amounts."
            let session = LanguageModelSession(instructions: """
                Convert the user's phrase describing a bitcoin amount into an integer number of satoshis.
                1 BTC = 100000000 satoshis. \(rateLine)
                Reply with ONLY the integer, no words, no punctuation. If you cannot determine an amount, reply 0.
                """)
            guard let response = try? await session.respond(to: text) else { return nil }
            let digits = response.content.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isNumber)
            guard let sats = UInt64(digits), sats > 0 else { return nil }
            return sats
        #else
            return nil
        #endif
    }
}
