import Foundation
import Testing

@testable import MaqsUI

@Suite struct BundledAssetsTests {
    static let stacks = ["noto_sans_regular", "noto_sans_bold"]
    static let ranges = ["0-255", "256-511", "512-767", "768-1023", "8192-8447"]

    private func styleObject(dark: Bool) throws -> Any {
        try JSONSerialization.jsonObject(with: BundledAssets.defaultStyle(dark: dark))
    }

    private func strings(in node: Any) -> [String] {
        if let text = node as? String { return [text] }
        if let list = node as? [Any] { return list.flatMap(strings(in:)) }
        if let object = node as? [String: Any] { return object.values.flatMap(strings(in:)) }
        return []
    }

    @Test(arguments: [false, true])
    func theDefaultStylesNameNoRemoteURL(dark: Bool) throws {
        let remote = try strings(in: styleObject(dark: dark))
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        #expect(remote.isEmpty)
    }

    @Test(arguments: [false, true])
    func everyTextLayerUsesABundledFontStack(dark: Bool) throws {
        let style = try #require(styleObject(dark: dark) as? [String: Any])
        let layers = try #require(style["layers"] as? [[String: Any]])
        var textLayers = 0
        for layer in layers where layer["type"] as? String == "symbol" {
            let layout = layer["layout"] as? [String: Any] ?? [:]
            guard layout["text-field"] != nil else { continue }
            textLayers += 1
            let fonts = try #require(layout["text-font"] as? [String], "\(layer["id"] ?? "?")")
            #expect(fonts.count == 1 && Self.stacks.contains(fonts[0]), "\(layer["id"] ?? "?")")
        }
        #expect(textLayers > 0)
    }

    @Test(arguments: stacks)
    func everyGlyphRangeTheStylesCanAskForIsBundled(stack: String) {
        for range in Self.ranges {
            let file = BundledAssets.directory.appending(path: "glyphs/\(stack)/\(range).pbf")
            #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), "\(stack)/\(range)")
        }
    }

    @Test func theGlyphAndSpriteURLsPointIntoTheBundle() throws {
        #expect(BundledAssets.glyphsTemplate.hasPrefix("file://"))
        #expect(BundledAssets.glyphsTemplate.hasSuffix("/glyphs/{fontstack}/{range}.pbf"))
        #expect(BundledAssets.spriteURL.hasPrefix("file://"))
        #expect(BundledAssets.spriteURL.hasSuffix("/sprite/base"))
        let sprite = try #require(URL(string: BundledAssets.spriteURL + ".json"))
        #expect(FileManager.default.fileExists(atPath: sprite.path(percentEncoded: false)))
    }

    @Test func theSpriteAndBothStylesLoadFromTheBundle() throws {
        for file in ["base.json", "base.png", "base@2x.json", "base@2x.png"] {
            let url = BundledAssets.directory.appending(path: "sprite/\(file)")
            #expect(try Data(contentsOf: url).count > 0, "\(file)")
        }
        let index = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: BundledAssets.directory.appending(path: "sprite/base.json"))
            ) as? [String: Any]
        )
        #expect(!index.isEmpty)
        for dark in [false, true] {
            let style = try #require(styleObject(dark: dark) as? [String: Any])
            let metadata = try #require(style["metadata"] as? [String: Any])
            #expect(metadata["maqs:style"] as? String == (dark ? "default-dark" : "default-light"))
        }
    }

    @Test func aMissingBundledFileIsATypedErrorNamingTheFile() {
        #expect(throws: MapError.resourcesMissing("nope.json")) {
            try BundledAssets.data(at: "styles/nope.json")
        }
    }

    @Test func everyMapErrorSaysWhatToDo() {
        let errors: [MapError] = [
            .invalidStyle("no layers"), .styleFailedToLoad, .basemapNotConfigured, .resourcesMissing("x.json"),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(MapError.invalidStyle("no layers").errorDescription?.contains("no layers") == true)
        #expect(MapError.resourcesMissing("x.json").errorDescription?.contains("x.json") == true)
    }
}
