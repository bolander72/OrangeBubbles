import SwiftUI

/// Required container app. The product lives in Messages; this screen just
/// points people there.
@main
struct SatchelApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "bitcoinsign.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.orange)
                Text("Satchel lives in Messages")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Open a conversation in the Messages app, tap the ⊕ or app strip, and choose Satchel to create, fund, and spend your Bitcoin wallet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Text("Your keys never leave your device.\nEncrypted backup lives in your iCloud.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 32)
        }
    }
}
