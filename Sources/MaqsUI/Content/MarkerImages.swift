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

    /// A place marker's disc, ring included: smaller than the app's markers, so the overlay stays quieter than them.
    static let placeDiameter: CGFloat = 20
    /// A place marker image's side in points: the disc and room for its shadow.
    static let placeCanvasSide: CGFloat = placeDiameter + 2 * shadowMargin

    static let plateRed = UIColor(red: 0xE2 / 255, green: 0, blue: 0x1A / 255, alpha: 1)
    static let plateCaps = UIEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)

    /// The kinds with a place-kind image; `maqs-place-other` covers every other kind. Settlements (`village`, `hamlet`,
    /// `isolated_dwelling`) have none: the style draws them as a name only.
    static let placeKinds = ["peak", "volcano", "saddle", "pass", "alpine_hut", "wilderness_hut", "shelter"]

    // MARK: Names

    /// The name carries everything that changes the pixels: the content, the variant, the scheme and the accent.
    static func name(for content: MarkerContent, hidden: Bool, selected: Bool, accent: UIColor, dark: Bool) -> String {
        let description = "\(describe(content))|hidden=\(hidden)|selected=\(selected)|dark=\(dark)|accent=\(rgbaHex(accent))"
        return "maqs-marker-" + hex(SHA256.hash(data: Data(description.utf8)))
    }

    static func placeKindName(_ kind: String, dark: Bool) -> String {
        "maqs-place-\(placeKinds.contains(kind) ? kind : "other")-\(dark ? "dark" : "light")"
    }

    static func plateName(dark: Bool) -> String { "maqs-plate-\(dark ? "dark" : "light")" }

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

    private static func rgbaHex(_ color: UIColor) -> String {
        var (red, green, blue, alpha): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
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
        // Hidden markers read grey in both schemes: the inactive-line grey, opaque, with white glyphs.
        let grey = dark ? UIColor(red: 0x73 / 255, green: 0x79 / 255, blue: 0x80 / 255, alpha: 1)
            : UIColor(red: 0x8A / 255, green: 0x8F / 255, blue: 0x96 / 255, alpha: 1)
        let ink = dark ? UIColor(red: 16 / 255, green: 22 / 255, blue: 32 / 255, alpha: 1) : UIColor.white
        let plateInk = UIColor(red: 16 / 255, green: 22 / 255, blue: 32 / 255, alpha: 1)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvasSide, height: canvasSide), format: .preferred())
        return renderer.image { context in
            let cg = context.cgContext
            if selected {
                accent.withAlphaComponent(0.35).setFill()
                UIBezierPath(ovalIn: circle.insetBy(dx: -haloWidth, dy: -haloWidth)).fill()
            }
            drawRing(circle, in: cg)

            let disc = UIBezierPath(ovalIn: inner)
            if hidden {
                grey.setFill()
                disc.fill()
            }
            switch content {
            case .dot:
                (hidden ? UIColor.white : accent).setFill()
                UIBezierPath(ovalIn: inner.insetBy(dx: inner.width * 0.3, dy: inner.height * 0.3)).fill()
            case .count(let number):
                if !hidden { accent.setFill(); disc.fill() }
                draw("\(number)", in: inner, color: hidden ? .white : ink, size: inner.height * 0.55)
            case .plate(let text):
                if !hidden { plateRed.setFill(); disc.fill() }
                draw(text, in: inner, color: hidden ? plateInk : .white, size: inner.height * 0.45)
            case .image(let picture):
                cg.saveGState()
                disc.addClip()
                let frame = aspectFill(picture.size, in: inner)
                if hidden {
                    desaturated(picture, size: frame.size).draw(in: frame, blendMode: .normal, alpha: 0.5)
                } else {
                    picture.draw(in: frame)
                }
                cg.restoreGState()
            case .symbol(let picture, let color):
                if !hidden { UIColor(color).setFill(); disc.fill() }
                let side = inner.width * 0.6
                let box = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
                let glyph = hidden ? picture.withTintColor(.white, renderingMode: .alwaysOriginal) : picture
                glyph.draw(in: aspectFit(glyph.size, in: box))
            }
        }
    }

    /// The picture scaled to `size` and stripped of colour.
    private static func desaturated(_ picture: UIImage, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: .preferred()).image { context in
            let rect = CGRect(origin: .zero, size: size)
            picture.draw(in: rect)
            UIColor.gray.setFill()
            context.cgContext.setBlendMode(.color)
            context.fill(rect)
        }
    }

    /// A place of the overlay: its kind's pictogram on a small disc inside the white ring, in the map's ink in light
    /// (`#101620`, white pictogram) and the dark road colour in dark (`#2E343E`, `#E6EDF3` pictogram).
    static func placeKindImage(_ kind: String, dark: Bool) -> UIImage {
        let symbol = switch kind {
        case "peak", "volcano": "mountain.2.fill"
        case "saddle", "pass": "arrow.left.and.right"
        case "alpine_hut", "wilderness_hut": "house.fill"
        case "shelter": "tent.fill"
        default: "mappin"
        }
        let fill = dark ? UIColor(red: 0x2E / 255, green: 0x34 / 255, blue: 0x3E / 255, alpha: 1)
            : UIColor(red: 0x10 / 255, green: 0x16 / 255, blue: 0x20 / 255, alpha: 1)
        let ink = dark ? UIColor(red: 0xE6 / 255, green: 0xED / 255, blue: 0xF3 / 255, alpha: 1) : UIColor.white
        let circle = CGRect(x: shadowMargin, y: shadowMargin, width: placeDiameter, height: placeDiameter)
        let inner = circle.insetBy(dx: ringWidth, dy: ringWidth)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: placeCanvasSide, height: placeCanvasSide), format: .preferred())
        let configuration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        return renderer.image { context in
            drawRing(circle, in: context.cgContext)
            fill.setFill()
            UIBezierPath(ovalIn: inner).fill()
            let box = inner.insetBy(dx: inner.width * 0.2, dy: inner.height * 0.2)
            if let picture = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(ink, renderingMode: .alwaysOriginal) {
                picture.draw(in: aspectFit(picture.size, in: box))
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

    /// The white disc of a round marker with its shadow, 0 1 3 at 25 % black; the content is drawn over the disc
    /// inside the ring.
    private static func drawRing(_ circle: CGRect, in cg: CGContext) {
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.25).cgColor)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: circle).fill()
        cg.restoreGState()
    }

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
