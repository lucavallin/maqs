#if canImport(UIKit)
import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// Draws the images the map's symbol layers refer to, and names them.
///
/// Names are stable across launches: they come from SHA-256 over a description of the content, never `hashValue`.
enum MarkerImages {
    static let circleDiameter: CGFloat = 30
    static let ringWidth: CGFloat = 2
    static let selectedScale: CGFloat = 1.25
    static let haloWidth: CGFloat = 4
    static let shadowMargin: CGFloat = 3
    /// Every marker image has this size in points, so a selected marker grows around the same centre.
    static let canvasSide: CGFloat = ceil(circleDiameter * selectedScale + 2 * haloWidth + 2 * shadowMargin)

    static let plateRed = UIColor(red: 0xE2 / 255, green: 0, blue: 0x1A / 255, alpha: 1)
    static let plateCaps = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)

    /// The names of the place-kind images; `maqs-place-other` covers every other kind.
    static let placeKinds = [
        "peak", "volcano", "saddle", "pass", "alpine_hut", "wilderness_hut", "shelter", "village", "hamlet", "isolated_dwelling",
    ]

    // MARK: Names

    static func name(for content: MarkerContent, hidden: Bool, selected: Bool) -> String {
        let description = "\(describe(content))|hidden=\(hidden)|selected=\(selected)"
        return "maqs-marker-" + hex(SHA256.hash(data: Data(description.utf8)))
    }

    static func placeKindName(_ kind: String) -> String {
        placeKinds.contains(kind) ? "maqs-place-\(kind)" : "maqs-place-other"
    }

    static let plateName = "maqs-plate"

    private static func describe(_ content: MarkerContent) -> String {
        switch content {
        case .dot: "dot"
        case .count(let number): "count:\(number)"
        case .plate(let text): "plate:\(text)"
        case .image(let image): "image:" + pngDigest(image)
        case .symbol(let image, let fill): "symbol:" + pngDigest(image) + ":" + rgba(UIColor(fill))
        }
    }

    private static func pngDigest(_ image: UIImage) -> String {
        hex(SHA256.hash(data: image.pngData() ?? Data()))
    }

    private static func rgba(_ color: UIColor) -> String {
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { String(Int(($0 * 255).rounded())) }.joined(separator: ",")
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Images

    static func image(for content: MarkerContent, hidden: Bool, selected: Bool, accent: UIColor, dark: Bool) -> UIImage {
        let diameter = circleDiameter * (selected ? selectedScale : 1)
        let center = CGPoint(x: canvasSide / 2, y: canvasSide / 2)
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        let inner = circle.insetBy(dx: ringWidth, dy: ringWidth)
        let muted = dark ? UIColor(red: 230 / 255, green: 237 / 255, blue: 243 / 255, alpha: 0.5)
            : UIColor(red: 16 / 255, green: 22 / 255, blue: 32 / 255, alpha: 0.5)
        let ink = dark ? UIColor(red: 16 / 255, green: 22 / 255, blue: 32 / 255, alpha: 1) : UIColor.white
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasSide, height: canvasSide), format: .preferred())
        return renderer.image { context in
            let cg = context.cgContext
            if selected {
                accent.withAlphaComponent(0.35).setFill()
                UIBezierPath(ovalIn: circle.insetBy(dx: -haloWidth, dy: -haloWidth)).fill()
            }
            // The ring carries the shadow; the content is drawn over its inner disc.
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: circle).fill()
            cg.restoreGState()

            let disc = UIBezierPath(ovalIn: inner)
            let fill = hidden ? muted : nil
            switch content {
            case .dot:
                (fill ?? accent).setFill()
                UIBezierPath(ovalIn: inner.insetBy(dx: inner.width * 0.3, dy: inner.height * 0.3)).fill()
            case .count(let number):
                (fill ?? accent).setFill()
                disc.fill()
                draw("\(number)", in: inner, color: ink, size: inner.height * 0.55)
            case .plate(let text):
                (fill ?? plateRed).setFill()
                disc.fill()
                draw(text, in: inner, color: .white, size: inner.height * 0.45)
            case .image(let picture):
                cg.saveGState()
                disc.addClip()
                picture.draw(in: aspectFill(picture.size, in: inner))
                cg.restoreGState()
                if let fill { fill.setFill(); disc.fill() }
            case .symbol(let picture, let color):
                (fill ?? UIColor(color)).setFill()
                disc.fill()
                let side = inner.width * 0.6
                picture.draw(in: aspectFit(picture.size, in: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)))
            }
        }
    }

    static func placeKindImage(_ kind: String, dark: Bool) -> UIImage {
        let symbol = switch kind {
        case "peak", "volcano": "mountain.2.fill"
        case "saddle", "pass": "arrow.left.and.right"
        case "alpine_hut", "wilderness_hut": "house.fill"
        case "shelter": "tent.fill"
        default: "circle.fill"
        }
        let ink = dark ? UIColor(red: 230 / 255, green: 237 / 255, blue: 243 / 255, alpha: 1)
            : UIColor(red: 16 / 255, green: 22 / 255, blue: 32 / 255, alpha: 1)
        let side: CGFloat = 20
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: .preferred())
        let configuration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        return renderer.image { _ in
            if let picture = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(ink, renderingMode: .alwaysOriginal) {
                picture.draw(in: aspectFit(picture.size, in: CGRect(x: 0, y: 0, width: side, height: side)))
            } else {
                ink.setFill()
                UIBezierPath(ovalIn: CGRect(x: 5, y: 5, width: 10, height: 10)).fill()
            }
        }
    }

    /// A red-white-red plate whose middle stretches, for `icon-text-fit`.
    static func plateImage() -> UIImage {
        let size = CGSize(width: 24, height: 16)
        let renderer = UIGraphicsImageRenderer(size: size, format: .preferred())
        let plate = renderer.image { context in
            let outline = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3)
            outline.addClip()
            plateRed.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: plateCaps.top, width: size.width, height: size.height - plateCaps.top - plateCaps.bottom))
        }
        return plate.resizableImage(withCapInsets: plateCaps, resizingMode: .stretch)
    }

    // MARK: Drawing helpers

    private static func draw(_ text: String, in rect: CGRect, color: UIColor, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin], context: nil)
        string.draw(in: CGRect(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2, width: bounds.width, height: bounds.height))
    }

    private static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        return CGRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
    }

    private static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        return CGRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
    }
}
#endif
