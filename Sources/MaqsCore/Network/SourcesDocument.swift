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

    private static let urlReason = "must be an https URL with a host and no credentials"

    /// An https URL with a host and no userinfo.
    private static func isPlainHTTPS(_ string: String) -> Bool {
        guard string.lowercased().hasPrefix("https://"), let components = URLComponents(string: string),
              let host = components.host, !host.isEmpty else { return false }
        return components.user == nil && components.password == nil
    }

    private static func convert(_ sources: [Document.Source], layer: String, isTerrain: Bool) throws -> [TileSource] {
        if sources.isEmpty { throw SourcesError.invalid("\(layer): must not be empty") }
        return try sources.enumerated().map { index, source in
            func fail(_ field: String, _ reason: String) -> SourcesError {
                .invalid("\(layer).[\(index)].\(field): \(reason)")
            }
            if source.id.isEmpty { throw fail("id", "must not be empty") }
            if source.id.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) == nil { throw fail("id", "must be lowercase kebab-case") }
            if source.provider.isEmpty { throw fail("provider", "must not be empty") }
            guard source.tiles.lowercased().hasPrefix("https://"), ["{z}", "{x}", "{y}"].allSatisfy(source.tiles.contains) else {
                throw fail("tiles", "must be https and contain {z}, {x} and {y}")
            }
            let probe = ["{z}", "{x}", "{y}"].reduce(source.tiles) { $0.replacingOccurrences(of: $1, with: "0") }
            guard isPlainHTTPS(probe) else { throw fail("tiles", urlReason) }
            guard isPlainHTTPS(source.tilejson), let tilejson = URL(string: source.tilejson) else { throw fail("tilejson", urlReason) }
            if isTerrain {
                if source.schema != "terrarium" { throw fail("schema", "must be terrarium") }
                if source.format != "webp", source.format != "png" { throw fail("format", "must be webp or png") }
            } else {
                if source.schema != "shortbread-1.0" { throw fail("schema", "must be shortbread-1.0") }
                if source.format != "mvt" { throw fail("format", "must be mvt") }
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
