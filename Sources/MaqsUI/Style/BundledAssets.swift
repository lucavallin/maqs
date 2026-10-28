import Foundation

/// The glyphs, sprite and default styles that ship in the package bundle, so an installed region
/// draws labels and icons with no network. `scripts/update-map-assets.sh` generates the files.
enum BundledAssets {
    /// The `MapAssets` folder in the package bundle. A `.copy` resource keeps the folder tree, which the
    /// glyph files need: they share file names across font stacks.
    static var directory: URL {
        (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appending(path: "MapAssets", directoryHint: .isDirectory)
    }

    /// MapLibre's glyph URL template for the bundled font stacks; the braces stay literal.
    static var glyphsTemplate: String {
        directory.appending(path: "glyphs", directoryHint: .isDirectory).absoluteString + "{fontstack}/{range}.pbf"
    }

    /// The sprite URL without extension; MapLibre adds `.json`, `.png` and the `@2x` variants.
    static var spriteURL: String {
        directory.appending(path: "sprite", directoryHint: .isDirectory).absoluteString + "base"
    }

    /// The bytes of the default style, `default-dark.json` or `default-light.json`.
    static func defaultStyle(dark: Bool) throws(MapError) -> Data {
        try data(at: "styles/\(dark ? "default-dark" : "default-light").json")
    }

    /// The bytes of a bundled file, by path relative to `MapAssets`.
    static func data(at relativePath: String) throws(MapError) -> Data {
        let file = directory.appending(path: relativePath)
        do {
            return try Data(contentsOf: file)
        } catch {
            logger.error("bundled map file unreadable: \(file.lastPathComponent, privacy: .public)")
            throw .resourcesMissing(file.lastPathComponent)
        }
    }
}
