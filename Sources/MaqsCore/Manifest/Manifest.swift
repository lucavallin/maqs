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
    /// a wrong type, a missing required field, a malformed id or file name, an out-of-range size, a duplicate,
    /// a non-HTTPS entry URL or a foreign host is an error. Error messages name the field path, never content.
    static func decode(_ data: Data, manifestHost: String) throws -> Manifest {
        struct Probe: Decodable {
            let manifestVersion: Int
            enum CodingKeys: String, CodingKey { case manifestVersion = "manifest_version" }
        }
        do {
            _ = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ManifestError.invalid("not valid JSON")
        }
        let version: Int
        do {
            version = try JSONDecoder().decode(Probe.self, from: data).manifestVersion
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
        try manifest.validate(manifestHost: manifestHost)
        return manifest
    }

    /// Largest file a release may hold (1.9 GiB, the pipeline's asset limit).
    private static let maxBytes: Int64 = 2_040_109_465

    private func validate(manifestHost: String) throws {
        for (index, item) in attribution.enumerated() where item.url.scheme?.lowercased() != "https" {
            throw ManifestError.invalid("attribution.[\(index)].url: must be https")
        }
        // Pack ids become directory names on disk, so they must be plain lowercase kebab-case.
        var seenIDs = Set<String>()
        for (index, region) in regions.enumerated() {
            try Self.checkID(region.id, path: "regions.[\(index)]", seen: &seenIDs)
        }
        seenIDs = []
        for (index, pack) in base.enumerated() {
            try Self.checkID(pack.id, path: "base.[\(index)]", seen: &seenIDs)
        }
        for (index, region) in regions.enumerated() where !Self.isValidBBox(region.bbox) {
            throw ManifestError.invalid("regions.[\(index)].bbox: not a valid bounding box")
        }
        // File names become paths in the shared downloads directory: same rules, and no name twice. `.resume` is the
        // suffix of the download session's resume files, so a file may not end in it (`DownloadSession.Request`).
        var seenFiles = Set<String>()
        let host = manifestHost.lowercased()
        let groups = regions.enumerated().map { ("regions.[\($0.offset)]", $0.element.layers) }
            + base.enumerated().map { ("base.[\($0.offset)]", $0.element.layers) }
        for (groupPath, layers) in groups {
            for key in layers.keys.sorted() {
                for (index, entry) in (layers[key] ?? []).enumerated() {
                    let path = "\(groupPath).layers.\(key).[\(index)]"
                    guard entry.file.count <= 128,
                          entry.file.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*\.v[1-9][0-9]*\.[a-z0-9]+/) != nil,
                          !entry.file.hasSuffix(".resume")
                    else { throw ManifestError.invalid("\(path).file: not a valid file name") }
                    guard seenFiles.insert(entry.file).inserted else {
                        throw ManifestError.invalid("\(path).file: duplicate file name")
                    }
                    guard entry.layerSchemaVersion >= 1 else {
                        throw ManifestError.invalid("\(path).layer_schema_version: must be at least 1")
                    }
                    guard entry.sha256.wholeMatch(of: /[0-9a-f]{64}/) != nil else {
                        throw ManifestError.invalid("\(path).sha256: not a lowercase hex SHA-256")
                    }
                    guard (1...Self.maxBytes).contains(entry.bytes) else {
                        throw ManifestError.invalid("\(path).bytes: out of range")
                    }
                    guard entry.url.scheme?.lowercased() == "https" else {
                        throw ManifestError.insecureURL("\(path).url")
                    }
                    guard entry.url.host()?.lowercased() == host,
                          entry.url.user() == nil, entry.url.password() == nil, entry.url.port == nil
                    else { throw ManifestError.foreignHost("\(path).url") }
                }
            }
        }
    }

    private static func isValidBBox(_ box: [Double]) -> Bool {
        guard box.count == 4, box.allSatisfy(\.isFinite) else { return false }
        return box[0] < box[2] && box[1] < box[3]
            && (-180...180).contains(box[0]) && (-180...180).contains(box[2])
            && (-90...90).contains(box[1]) && (-90...90).contains(box[3])
    }

    private static func checkID(_ id: String, path: String, seen: inout Set<String>) throws {
        guard id.count <= 64, id.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) != nil else {
            throw ManifestError.invalid("\(path).id: not a valid id")
        }
        guard seen.insert(id).inserted else { throw ManifestError.invalid("\(path).id: duplicate id") }
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
        let dayStyle = Date.ISO8601FormatStyle().year().month().day()
        guard day.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil,
              let parsed = try? Date(day, strategy: dayStyle),
              parsed.formatted(dayStyle) == day
        else {
            throw DecodingError.dataCorruptedError(forKey: .dataDate, in: c, debugDescription: "not YYYY-MM-DD")
        }
        dataDate = parsed
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
        guard text.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z/) != nil,
              let parsed = try? Date(text, strategy: .iso8601)
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an ISO 8601 UTC timestamp"))
        }
        date = parsed
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
