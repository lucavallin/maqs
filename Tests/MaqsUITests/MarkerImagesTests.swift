#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit

@testable import MaqsUI

@Suite struct MarkerImagesTests {
    private static let accent = UIColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)

    private func swatch(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func contents() -> [MarkerContent] {
        [.dot, .count(7), .image(swatch(.green)), .symbol(swatch(.white), fill: .orange), .plate("12")]
    }

    private func render(_ content: MarkerContent, hidden: Bool = false, selected: Bool = false, dark: Bool = false) -> UIImage {
        MarkerImages.image(for: content, hidden: hidden, selected: selected, accent: Self.accent, dark: dark)
    }

    /// RGBA of the pixel at a point (in points) of the image.
    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let cg = try #require(image.cgImage)
        let width = cg.width, height = cg.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        try data.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let px = Int(x * image.scale), py = Int(y * image.scale)
        let offset = (py * width + px) * 4
        return (data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
    }

    @Test func everyContentIsTheCanvasSizeAtTheScreenScale() {
        for content in contents() {
            let image = render(content)
            #expect(image.size == CGSize(width: MarkerImages.canvasSide, height: MarkerImages.canvasSide))
            #expect(image.scale == UIGraphicsImageRendererFormat.preferred().scale)
            #expect(MarkerImages.canvasSide > MarkerImages.circleDiameter)
        }
    }

    @Test func theRingIsWhite() throws {
        let center = MarkerImages.canvasSide / 2
        // Halfway through the 2 pt ring of the 30 pt circle.
        let ringX = center + MarkerImages.circleDiameter / 2 - MarkerImages.ringWidth / 2
        for content in contents() {
            let p = try pixel(render(content), x: ringX, y: center)
            #expect(p.r > 250 && p.g > 250 && p.b > 250 && p.a == 255)
        }
    }

    @Test func selectedIsLargerByQuarterWithAnAccentHalo() throws {
        let center = MarkerImages.canvasSide / 2
        let radius = MarkerImages.circleDiameter * MarkerImages.selectedScale / 2
        let plain = render(.dot)
        let selected = render(.dot, selected: true)
        // A point between the two radii: transparent-ish shadow area when plain, white ring when selected.
        let x = center + radius - MarkerImages.ringWidth / 2
        let ring = try pixel(selected, x: x, y: center)
        #expect(ring.r > 250 && ring.g > 250 && ring.b > 250)
        let outsidePlain = try pixel(plain, x: x, y: center)
        #expect(!(outsidePlain.r > 250 && outsidePlain.g > 250 && outsidePlain.b > 250 && outsidePlain.a == 255))
        // The halo lies just outside the circle and is the accent at about 35 %.
        let halo = try pixel(selected, x: center + radius + MarkerImages.haloWidth / 2, y: center)
        #expect(halo.a > 60 && halo.a < 120)
        #expect(halo.b > halo.r)
    }

    private func close(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), _ r: Int, _ g: Int, _ b: Int) -> Bool {
        abs(Int(p.r) - r) <= 3 && abs(Int(p.g) - g) <= 3 && abs(Int(p.b) - b) <= 3 && p.a == 255
    }

    @Test(arguments: [false, true])
    func hiddenMarkersReadGreyAndDifferFromNormal(dark: Bool) throws {
        let center = MarkerImages.canvasSide / 2
        // Inside the disc, clear of the centred glyph.
        let x = center + MarkerImages.circleDiameter / 2 - MarkerImages.ringWidth - 3
        let grey = dark ? (115, 121, 128) : (138, 143, 150)
        let all: [MarkerContent] = [.dot, .count(3), .symbol(swatch(.white), fill: .orange), .plate("12")]
        for content in all {
            let hidden = try pixel(render(content, hidden: true, dark: dark), x: x, y: center)
            #expect(close(hidden, grey.0, grey.1, grey.2))
            let normal = try pixel(render(content, dark: dark), x: x, y: center)
            let distance = abs(Int(hidden.r) - Int(normal.r)) + abs(Int(hidden.g) - Int(normal.g)) + abs(Int(hidden.b) - Int(normal.b))
            #expect(distance > 40)
        }
    }

    @Test func hiddenGlyphsAreWhiteOnTheGreyAndPlateTextIsDark() throws {
        let center = MarkerImages.canvasSide / 2
        let dot = try pixel(render(.dot, hidden: true), x: center, y: center)
        #expect(dot.r > 240 && dot.g > 240 && dot.b > 240)
        let plate = render(.plate("88"), hidden: true)
        var darkest = 255
        for dx in stride(from: -6.0, through: 6.0, by: 1) {
            for dy in stride(from: -5.0, through: 5.0, by: 1) {
                darkest = min(darkest, Int(try pixel(plate, x: center + dx, y: center + dy).r))
            }
        }
        #expect(darkest < 80)
    }

    @Test func hiddenPhotoIsDesaturatedOverTheGrey() throws {
        let center = MarkerImages.canvasSide / 2
        let p = try pixel(render(.image(swatch(.red)), hidden: true), x: center, y: center)
        #expect(abs(Int(p.r) - Int(p.g)) < 40 && abs(Int(p.g) - Int(p.b)) < 40)
    }

    @Test func namesAreStableAndDistinct() {
        let again = contents()
        var seen = Set<String>()
        for (index, content) in contents().enumerated() {
            for hidden in [false, true] {
                for selected in [false, true] {
                    for dark in [false, true] {
                        let name = MarkerImages.name(for: content, hidden: hidden, selected: selected, accent: Self.accent, dark: dark)
                        #expect(name.hasPrefix("maqs-marker-"))
                        #expect(name == MarkerImages.name(for: again[index], hidden: hidden, selected: selected, accent: Self.accent, dark: dark))
                        seen.insert(name)
                    }
                }
            }
        }
        #expect(seen.count == 40)
    }

    @Test func theAccentChangesTheName() {
        let other = UIColor(red: 1, green: 0.33, blue: 0, alpha: 1)
        #expect(MarkerImages.name(for: .dot, hidden: false, selected: false, accent: Self.accent, dark: false)
            != MarkerImages.name(for: .dot, hidden: false, selected: false, accent: other, dark: false))
    }

    @Test func imagesWithDifferentPixelsGetDifferentNames() {
        let green = MarkerImages.name(for: .image(swatch(.green)), hidden: false, selected: false, accent: Self.accent, dark: false)
        let red = MarkerImages.name(for: .image(swatch(.red)), hidden: false, selected: false, accent: Self.accent, dark: false)
        #expect(green != red)
    }

    @Test func placeKindsHaveImagesAndUnknownKindsFallBack() {
        for kind in MarkerImages.placeKinds {
            #expect(MarkerImages.placeKindName(kind, dark: false) == "maqs-place-\(kind)-light")
            #expect(MarkerImages.placeKindName(kind, dark: true) == "maqs-place-\(kind)-dark")
            #expect(MarkerImages.placeKindImage(kind, dark: false).size.width > 0)
        }
        #expect(MarkerImages.placeKindName("spaceport", dark: true) == "maqs-place-other-dark")
        #expect(MarkerImages.plateName(dark: false) == "maqs-plate-light")
        #expect(MarkerImages.plateName(dark: true) == "maqs-plate-dark")
    }

    @Test func plateIsStretchableRedWhiteRed() throws {
        let plate = MarkerImages.plateImage()
        #expect(plate.resizingMode == .stretch)
        #expect(plate.capInsets == MarkerImages.plateCaps)
        let top = try pixel(plate, x: 12, y: 1)
        let middle = try pixel(plate, x: 12, y: 8)
        #expect(top.r > 200 && top.g < 40)
        #expect(middle.r > 250 && middle.g > 250 && middle.b > 250)
    }
}
#endif
