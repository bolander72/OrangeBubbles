import SwiftUI
import WalletKit

// Shared by the Messages extension and the host app (compiled into both
// targets via app/project.yml). Everything that makes the two look like one
// product lives here; screen-specific pieces stay with their screens.

// MARK: - Brand

enum Brand {
    /// Bitcoin orange. Used for primary actions and incoming amounts only —
    /// everything else stays in system neutrals so the orange means something.
    static let orange = Color(red: 0.97, green: 0.58, blue: 0.10)
    static let orangeDeep = Color(red: 0.93, green: 0.42, blue: 0.05)

    /// Reserved for brand moments: welcome hero, balance numerals, QR frame.
    static var gradient: LinearGradient {
        LinearGradient(
            colors: [orange, orangeDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var subtleGradient: LinearGradient {
        LinearGradient(
            colors: [orange.opacity(0.14), orangeDeep.opacity(0.06)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Formatting

enum Format {
    static func sats(_ value: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func btc(_ sats: UInt64) -> String {
        PaymentRequest.btcString(sats: sats)
    }

    /// tb1q9ykh…jw48dpq — enough of both ends to eyeball-verify.
    static func shortAddress(_ address: String, prefix: Int = 10, suffix: Int = 7) -> String {
        guard address.count > prefix + suffix + 1 else { return address }
        return "\(address.prefix(prefix))…\(address.suffix(suffix))"
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Buttons

struct ProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Brand.gradient)
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(Brand.orangeDeep)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Brand.orange.opacity(0.13))
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Small pieces

/// Circular icon well used by transaction rows and info banners.
struct IconBubble: View {
    let systemName: String
    var tint: Color = Brand.orange
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(0.14)))
    }
}

struct NetworkBadge: View {
    let network: NetworkKind

    var body: some View {
        if network != .bitcoin {
            Text(network.rawValue.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.8)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.purple.opacity(0.14)))
                .foregroundStyle(.purple)
        }
    }
}

struct InfoBanner: View {
    let systemName: String
    let text: String
    var tint: Color = .orange

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.footnote.weight(.semibold))
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.1))
        )
    }
}

/// The ₿ mark used on welcome, cards, and success states.
struct BitcoinMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .fill(Brand.gradient)
                .frame(width: size, height: size)
                .shadow(color: Brand.orange.opacity(0.35), radius: size * 0.18, y: size * 0.08)
            Image(systemName: "bitcoinsign")
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - Pressable

/// Plain button with a gentle press response — for tiles and chips that
/// draw their own background.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

// MARK: - Action tile

/// Home's primary verbs: Receive, Send, Gift. Equal-weight tiles so the
/// three things the app does read as one set; `filled` marks the one to
/// start with.
struct ActionTile: View {
    let title: String
    let systemImage: String
    var tint: Color = Brand.orange
    var filled = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            // Accessibility text sizes: icon beside the label in a full-width
            // row, so "Receive" never truncates to "Rec…".
            tileLayout {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
                    .frame(width: 40, height: 40)
                    .background(
                        Circle().fill(filled ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(tint.opacity(0.14)))
                    )
                Text(title)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, typeSize.isAccessibilitySize ? 14 : 0)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func tileLayout<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if typeSize.isAccessibilitySize {
            HStack(spacing: 12) { content(); Spacer(minLength: 0) }
        } else {
            VStack(spacing: 7) { content() }
        }
    }
}

/// Lays children out in a row normally and stacks them at accessibility
/// text sizes, where three side-by-side tiles can't fit their labels.
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var spacing: CGFloat = 10
    @ViewBuilder let content: () -> Content

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: spacing) { content() }
        } else {
            HStack(spacing: spacing) { content() }
        }
    }
}

// MARK: - Forms

/// Small uppercase caption above a form field.
struct FieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.leading, 4)
    }
}

// MARK: - Detail card

/// A receipt-style stack of label/value rows. Used by send review, the
/// payment-status sheet, and the gift sheet so every "here are the facts"
/// moment looks the same.
struct DetailRow: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    var monospaced = false
    var emphasized = false
}

struct DetailCard: View {
    let rows: [DetailRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.horizontal, 16) }
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 16)
                    Text(row.value)
                        .font(
                            row.monospaced
                                ? .system(.footnote, design: .monospaced).weight(.medium)
                                : .system(.subheadline, design: .rounded).weight(row.emphasized ? .bold : .semibold)
                        )
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
