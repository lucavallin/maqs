import Foundation

/// Strict decoding of `sources.json` (`sources_version` 1). Unknown fields pass; wrong types, non-HTTPS URLs
/// and the other promises of `config/schemas/sources.schema.json` that clients rely on fail.
enum SourcesDocument {
    static let supportedVersion = 1

    private struct Document: Decodable {
        let sourcesVersion: Int
        let layers: Layers

        enum CodingKeys: String, CodingKey { case sourcesVersion = "sources_version", layers }

        struct Layers: Decodable { let basemap: [Source]; let terrain: [Source] }

        struct Source: Decodable {
            let id: String, provider: String, tiles: String, tilejson: String, schema: String, format: String
            let tileSize: Int?, minZoom: Int, maxZoom: Int, attribution: [String]

            enum CodingKeys: String, CodingKey {
                case id, provider, tiles, tilejson, schema, format, attribution
                case tileSize = "tile_size", minZoom = "min_zoom", maxZoom = "max_zoom"
            }
        }
    }

    private struct Probe: Decodable {
        let sourcesVersion: Int
        enum CodingKeys: String, CodingKey { case sourcesVersion = "sources_version" }
    }

    static func decode(_ data: Data) throws -> OnlineSources {
        guard let version = try? JSONDecoder().decode(Probe.self, from: data).sourcesVersion else {
            throw SourcesError.invalid("sources_version missing or not an integer")
        }
        guard version == supportedVersion else { throw SourcesError.unsupportedVersion(version) }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch let error as DecodingError {
            throw SourcesError.invalid(error.fieldDescription)
        } catch {
            throw SourcesError.invalid("not valid JSON")
        }
        return OnlineSources(
            version: version,
            basemap: try convert(document.layers.basemap, layer: "basemap", isTerrain: false),
            terrain: try convert(document.layers.terrain, layer: "terrain", isTerrain: true))
    }

    private static func convert(_ sources: [Document.Source], layer: String, isTerrain: Bool) throws -> [TileSource] {
        try sources.enumerated().map { index, source in
            func fail(_ field: String, _ reason: String) -> SourcesError {
                .invalid("\(layer).[\(index)].\(field): \(reason)")
            }
            if source.id.isEmpty { throw fail("id", "must not be empty") }
            if source.provider.isEmpty { throw fail("provider", "must not be empty") }
            let template = source.tiles.lowercased()
            guard template.hasPrefix("https://"), ["{z}", "{x}", "{y}"].allSatisfy(template.contains) else {
                throw fail("tiles", "must be https and contain {z}, {x} and {y}")
            }
            guard source.tilejson.lowercased().hasPrefix("https://"), let tilejson = URL(string: source.tilejson) else {
                throw fail("tilejson", "must be https")
            }
            guard source.minZoom >= 0, source.minZoom <= source.maxZoom else {
                throw fail("min_zoom", "must be between 0 and max_zoom, at most 22")
            }
            guard source.maxZoom <= 22 else { throw fail("max_zoom", "must be between 0 and max_zoom, at most 22") }
            if source.attribution.isEmpty { throw fail("attribution", "must not be empty") }
            if source.attribution.contains(where: \.isEmpty) { throw fail("attribution", "must not contain empty strings") }
            if isTerrain, source.tileSize != 256, source.tileSize != 512 { throw fail("tile_size", "must be 256 or 512") }
            return TileSource(id: source.id, provider: source.provider, tiles: source.tiles, tilejson: tilejson,
                              schema: source.schema, format: source.format, tileSize: source.tileSize,
                              minZoom: source.minZoom, maxZoom: source.maxZoom, attribution: source.attribution)
        }
    }
}
