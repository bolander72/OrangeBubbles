import UIKit
import WalletKit

/// Draws the image shown on payment cards in the Messages transcript.
/// MSMessageTemplateLayout renders this at roughly 300×210pt, so we draw at
/// 3× for crispness. Keeping it an image (rather than caption text) is what
/// makes the card feel like a designed object in the conversation.
enum CardImageRenderer {
    enum Kind {
        case request
        case receipt
        case gift
    }

    private static let size = CGSize(width: 300, height: 210)

    static func render(kind: Kind, request: PaymentRequest) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            drawBackground(kind: kind, in: rect, context: context.cgContext)

            // ₿ roundel
            let markRect = CGRect(x: 24, y: 24, width: 44, height: 44)
            drawMark(kind: kind, in: markRect, context: context.cgContext)

            // Title + subtitle
            let title: String
            switch kind {
            case .request: title = "Bitcoin requested"
            case .receipt: title = "Bitcoin sent"
            case .gift: title = "Bitcoin gift 🎁"
            }
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.rounded(size: 20, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            title.draw(at: CGPoint(x: 24, y: 84), withAttributes: titleAttrs)

            let amountLine: String
            if let sats = request.amountSats {
                amountLine = "\(formattedSats(sats)) sats"
            } else {
                amountLine = "Any amount"
            }
            let amountAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.rounded(size: 34, weight: .heavy),
                .foregroundColor: UIColor.white,
            ]
            amountLine.draw(at: CGPoint(x: 24, y: 110), withAttributes: amountAttrs)

            if let sats = request.amountSats {
                let btcAttrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.8),
                ]
                "\(PaymentRequest.btcString(sats: sats)) BTC".draw(
                    at: CGPoint(x: 24, y: 152),
                    withAttributes: btcAttrs
                )
            }

            // Footer: truncated address or txid
            let footer: String
            if kind == .receipt, let txid = request.txid {
                footer = "tx \(txid.prefix(8))…\(txid.suffix(8))"
            } else {
                footer = "\(request.address.prefix(12))…\(request.address.suffix(8))"
            }
            let footerAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(0.65),
            ]
            footer.draw(at: CGPoint(x: 24, y: size.height - 28), withAttributes: footerAttrs)
        }
    }

    private static func drawBackground(kind: Kind, in rect: CGRect, context: CGContext) {
        let colors: [CGColor]
        switch kind {
        case .request:
            colors = [
                UIColor(red: 0.97, green: 0.58, blue: 0.10, alpha: 1).cgColor,
                UIColor(red: 0.89, green: 0.38, blue: 0.04, alpha: 1).cgColor,
            ]
        case .receipt:
            colors = [
                UIColor(red: 0.13, green: 0.68, blue: 0.38, alpha: 1).cgColor,
                UIColor(red: 0.05, green: 0.52, blue: 0.28, alpha: 1).cgColor,
            ]
        case .gift:
            colors = [
                UIColor(red: 0.56, green: 0.27, blue: 0.90, alpha: 1).cgColor,
                UIColor(red: 0.36, green: 0.13, blue: 0.71, alpha: 1).cgColor,
            ]
        }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: [0, 1]
        ) else { return }
        context.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: rect.maxX, y: rect.maxY),
            options: []
        )

        // Oversized, faint ₿ watermark bleeding off the right edge.
        let watermarkAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.rounded(size: 190, weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.09),
        ]
        "₿".draw(at: CGPoint(x: rect.maxX - 120, y: 10), withAttributes: watermarkAttrs)
    }

    private static func drawMark(kind: Kind, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setFillColor(UIColor.white.withAlphaComponent(0.22).cgColor)
        context.fillEllipse(in: rect)
        context.restoreGState()

        let symbolName: String
        switch kind {
        case .request: symbolName = "bitcoinsign"
        case .receipt: symbolName = "checkmark"
        case .gift: symbolName = "gift.fill"
        }
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        guard let symbol = UIImage(systemName: symbolName, withConfiguration: config)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        else { return }
        let symbolRect = CGRect(
            x: rect.midX - symbol.size.width / 2,
            y: rect.midY - symbol.size.height / 2,
            width: symbol.size.width,
            height: symbol.size.height
        )
        symbol.draw(in: symbolRect)
    }

    private static func formattedSats(_ sats: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: sats)) ?? String(sats)
    }
}

extension UIFont {
    static func rounded(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
