import Foundation

/// Access to the committed test-region outputs and the `data-ci` manifest.
public enum Fixtures {
    /// Thrown when a fixture path does not exist in the bundle.
    public struct Missing: Error, CustomStringConvertible {
        /// The path relative to `Fixtures/`.
        public let path: String
        public var description: String { "fixture not found: \(path)" }
    }

    /// The manifest URL every fixture-driven test uses; its host matches the fixture entry URLs.
    public static let manifestURL = URL(string: "https://github.com/lucavallin/maqs/releases/latest/download/manifest.json")!

    /// A fixture by path relative to `Fixtures/` (`"test/test-trails.v1.sqlite"`).
    public static func url(_ relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/").map(String.init)
        let name = parts.last ?? relativePath
        let subdirectory = (["Fixtures"] + parts.dropLast()).joined(separator: "/")
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: subdirectory) else {
            throw Missing(path: relativePath)
        }
        return url
    }

    /// The `data-ci` manifest, byte for byte.
    public static func manifestData() throws -> Data {
        try Data(contentsOf: url("manifest.json"))
    }

    /// The fixture manifest after an in-place edit of its JSON object, re-encoded.
    public static func manifestJSON(mutating edit: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: manifestData()) as? [String: Any] ?? [:]
        try edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Every `url` in a manifest, with the `file` it names.
    public static func entryURLs(in manifest: Data) throws -> [(url: URL, file: String)] {
        let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any] ?? [:]
        var result: [(URL, String)] = []
        func walk(_ packs: Any?) {
            for pack in packs as? [[String: Any]] ?? [] {
                for entries in (pack["layers"] as? [String: [[String: Any]]] ?? [:]).values {
                    for entry in entries {
                        if let s = entry["url"] as? String, let url = URL(string: s), let file = entry["file"] as? String {
                            result.append((url, file))
                        }
                    }
                }
            }
        }
        walk(object["regions"])
        walk(object["base"])
        return result
    }

    /// Serves `manifest` (default: the fixture manifest) at ``manifestURL`` and each entry URL from the
    /// fixture file of the same name. The base pack's file is not committed, so its URL serves
    /// `test/test-basemap.v1.pmtiles`; tests that install a base pack rewrite its `sha256` and `bytes` first.
    public static func serveRelease(on server: StubServer, manifest: Data? = nil, etag: String? = "\"fixture-etag\"") throws {
        let manifest = try manifest ?? manifestData()
        var base: [String: String] = ["Content-Type": "application/json"]
        if let etag { base["ETag"] = etag }
        let headers = base
        server.route(manifestURL) { request in
            if let etag, request.value(forHTTPHeaderField: "If-None-Match") == etag {
                return StubResponse(status: 304, headers: ["ETag": etag])
            }
            return StubResponse(status: 200, headers: headers, body: manifest)
        }
        for (url, file) in try entryURLs(in: manifest) {
            let local = file.hasPrefix("base-") ? "test/test-basemap.v1.pmtiles" : "test/\(file)"
            let data = try Data(contentsOf: try Self.url(local))
            server.route(url, body: data)
        }
    }

    /// SHA-256 and size of a fixture, for tests that rewrite manifest entries.
    public static func digest(_ relativePath: String) throws -> (sha256: String, bytes: Int) {
        let data = try Data(contentsOf: url(relativePath))
        return (SHA256Hex.hex(of: data), data.count)
    }
}
