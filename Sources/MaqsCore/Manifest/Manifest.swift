import Foundation

/// `manifest.json` as published (`docs/data-format.md`, `manifest_version` 1). Internal: apps see ``Catalog``.
struct Manifest: Decodable, Sendable, Equatable {
    let manifestVersion: Int
    let createdAt: Date
    let release: String
    let shortbreadVersion: String
    let attribution: [ManifestAttribution]
    let regions: [ManifestRegion]
    let base: [ManifestBasePack]

    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version", createdAt = "created_at", release
        case shortbreadVersion = "shortbread_version", attribution, regions, base
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifestVersion = try c.decode(Int.self, forKey: .manifestVersion)
        createdAt = try c.decode(ISO8601Seconds.self, forKey: .createdAt).date
        release = try c.decode(String.self, forKey: .release)
        shortbreadVersion = try c.decode(String.self, forKey: .shortbreadVersion)
        attribution = try c.decode([ManifestAttribution].self, forKey: .attribution)
        regions = try c.decode([ManifestRegion].self, forKey: .regions)
        base = try c.decodeIfPresent([ManifestBasePack].self, forKey: .base) ?? []
    }

    /// The one version this package reads.
    static let supportedVersion = 1

    /// Decodes and validates a manifest. Unknown fields, unknown layer keys and unknown roles pass through;
    /// a wrong type, a missing required field, a malformed pack id, a non-HTTPS entry URL or a foreign host is an error.
    static func decode(_ data: Data, manifestHost: String) throws -> Manifest {
        struct Probe: Decodable { let manifest_version: Int }
        let version: Int
        do {
            version = try JSONDecoder().decode(Probe.self, from: data).manifest_version
        } catch {
            throw ManifestError.invalid("manifest_version missing or not an integer")
        }
        guard version == supportedVersion else { throw ManifestError.unsupportedVersion(version) }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch let error as DecodingError {
            throw ManifestError.invalid(error.fieldDescription)
        } catch {
            throw ManifestError.invalid("not valid JSON")
        }
        // Pack ids become directory names on disk, so they must be plain lowercase kebab-case.
        for (index, region) in manifest.regions.enumerated() where !isValidID(region.id) {
            throw ManifestError.invalid("regions.[\(index)].id: not a valid id")
        }
        for (index, pack) in manifest.base.enumerated() where !isValidID(pack.id) {
            throw ManifestError.invalid("base.[\(index)].id: not a valid id")
        }
        for entry in manifest.allEntries {
            guard entry.url.scheme?.lowercased() == "https" else {
                throw ManifestError.insecureURL(entry.url.absoluteString)
            }
            guard entry.url.host()?.lowercased() == manifestHost.lowercased() else {
                throw ManifestError.foreignHost(entry.url.absoluteString)
            }
        }
        return manifest
    }

    private static func isValidID(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil
    }

    var allEntries: [ManifestEntry] {
        regions.flatMap { $0.layers.values.flatMap { $0 } } + base.flatMap { $0.layers.values.flatMap { $0 } }
    }
}

struct ManifestAttribution: Decodable, Sendable, Equatable {
    let text: String
    let licence: String
    let url: URL
    /// Layer names as strings: an unknown name is kept here and ignored downstream.
    let layers: [String]
}

struct ManifestRegion: Decodable, Sendable, Equatable {
    let id: String
    let name: [String: String]
    let bbox: [Double]
    /// Keyed by manifest layer name; unknown keys are kept and ignored by ``entries(for:)``.
    let layers: [String: [ManifestEntry]]

    func entries(for layer: Layer) -> [ManifestEntry]? { layers[layer.rawValue] }
}

struct ManifestBasePack: Decodable, Sendable, Equatable {
    let id: String
    let regions: [String]
    let maxZoom: Int
    let layers: [String: [ManifestEntry]]

    enum CodingKeys: String, CodingKey { case id, regions, maxZoom = "max_zoom", layers }

    func entries(for layer: Layer) -> [ManifestEntry]? { layers[layer.rawValue] }
}

struct ManifestEntry: Decodable, Sendable, Equatable {
    let layerSchemaVersion: Int
    let file: String
    let url: URL
    let bytes: Int64
    let sha256: String
    /// `data_date`, as UTC midnight.
    let dataDate: Date
    let osmTimestamp: Date?
    /// `nil` for the main file, `"overlay"` for a trails or places tile file; anything else is ignored by selection.
    let role: String?

    enum CodingKeys: String, CodingKey {
        case layerSchemaVersion = "layer_schema_version", file, url, bytes, sha256
        case dataDate = "data_date", osmTimestamp = "osm_timestamp", role
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layerSchemaVersion = try c.decode(Int.self, forKey: .layerSchemaVersion)
        file = try c.decode(String.self, forKey: .file)
        url = try c.decode(URL.self, forKey: .url)
        bytes = try c.decode(Int64.self, forKey: .bytes)
        sha256 = try c.decode(String.self, forKey: .sha256)
        let day = try c.decode(String.self, forKey: .dataDate)
        do {
            dataDate = try Date(day, strategy: .iso8601.year().month().day())
        } catch {
            throw DecodingError.dataCorruptedError(forKey: .dataDate, in: c, debugDescription: "not YYYY-MM-DD")
        }
        osmTimestamp = try c.decodeIfPresent(ISO8601Seconds.self, forKey: .osmTimestamp)?.date
        role = try c.decodeIfPresent(String.self, forKey: .role)
    }

    init(layerSchemaVersion: Int, file: String, url: URL, bytes: Int64, sha256: String,
         dataDate: Date, osmTimestamp: Date?, role: String?) {
        self.layerSchemaVersion = layerSchemaVersion; self.file = file; self.url = url; self.bytes = bytes
        self.sha256 = sha256; self.dataDate = dataDate; self.osmTimestamp = osmTimestamp; self.role = role
    }
}

/// `YYYY-MM-DDTHH:MM:SSZ`, the one timestamp form the data files use.
struct ISO8601Seconds: Decodable {
    let date: Date
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        do {
            date = try Date(text, strategy: .iso8601)
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 UTC timestamp"))
        }
    }
}

extension DecodingError {
    /// The failing field's path and reason, without any of the document's content.
    var fieldDescription: String {
        func path(_ context: Context) -> String {
            let p = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "root" : p
        }
        switch self {
        case .keyNotFound(let key, let context): return "\(path(context)): missing \(key.stringValue)"
        case .typeMismatch(_, let context): return "\(path(context)): wrong type"
        case .valueNotFound(_, let context): return "\(path(context)): null not allowed"
        case .dataCorrupted(let context): return "\(path(context)): \(context.debugDescription)"
        @unknown default: return "unreadable"
        }
    }
}
