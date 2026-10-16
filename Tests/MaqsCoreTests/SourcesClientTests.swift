import Foundation
import Synchronization
import Testing
@testable import MaqsCore
import MaqsTestSupport

@Suite struct SourcesClientTests {
    let server = StubServer()
    let tmp: TemporaryDirectory
    let url = URL(string: "https://raw.githubusercontent.com/lucavallin/maqs/main/config/sources.json")!
    let now = Date(timeIntervalSince1970: 5_000_000)

    init() throws { tmp = try TemporaryDirectory() }

    func client(at date: Date? = nil) -> SourcesClient {
        let stamp = date ?? now
        return SourcesClient(http: HTTPClient(session: URLSession(configuration: server.configuration), userAgent: "T Maqs/0"),
                             cache: StorageLayout(root: tmp.url).sources, url: url, bundled: SourcesClient.bundledURL,
                             maxAge: .seconds(3_600), now: { stamp })
    }

    /// The bundled document with one source entry changed (or a top-level key, when `layer` is nil).
    func bundledData(layer: String = "terrain", _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: SourcesClient.bundledURL)) as? [String: Any])
        var layers = try #require(object["layers"] as? [String: [[String: Any]]])
        change(&layers[layer]![0])
        object["layers"] = layers
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("with nothing cached the bundled copy is served and matches config/sources.json")
    func bundledFallback() throws {
        let sources = try #require(client().current())
        #expect(sources.version == 1)
        #expect(sources.basemap.first?.id == "versatiles-osm")
        #expect(sources.basemap.first?.schema == "shortbread-1.0")
        #expect(sources.terrain.first?.tileSize == 512)
        #expect(sources.terrain.first?.maxZoom == 12)
        #expect(sources.terrain.first?.attribution == ["© Mapterhorn"])
        #expect(server.requests.isEmpty)
    }

    @Test("refresh fetches, caches, and the cached copy is preferred to the bundled one")
    func refresh() async throws {
        server.route(url, headers: ["ETag": "\"s1\""], body: try bundledData(layer: "basemap") { $0["id"] = "versatiles-osm-next" })
        let refreshed = try await client().refresh(policy: .always)
        #expect(refreshed.basemap.first?.id == "versatiles-osm-next")
        #expect(client().current()?.basemap.first?.id == "versatiles-osm-next")
    }

    @Test("an unsupported sources_version is a typed error and the last good copy stays")
    func unsupported() async throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: SourcesClient.bundledURL)) as? [String: Any])
        object["sources_version"] = 7
        server.route(url, body: try JSONSerialization.data(withJSONObject: object))
        await #expect(throws: SourcesError.unsupportedVersion(7)) { _ = try await client().refresh(policy: .always) }
        #expect(client().current()?.basemap.first?.id == "versatiles-osm")
    }

    @Test("a 304 keeps the cache; a 500 is a network error")
    func statuses() async throws {
        server.route(url, headers: ["ETag": "\"s1\""], body: try Data(contentsOf: SourcesClient.bundledURL))
        _ = try await client().refresh(policy: .always)
        server.route(url) { request in
            request.value(forHTTPHeaderField: "If-None-Match") == "\"s1\"" ? StubResponse(status: 304) : StubResponse(status: 500)
        }
        _ = try await client().refresh(policy: .always)
        server.route(url, status: 500, body: Data())
        await #expect(throws: SourcesError.network(statusCode: 500)) { _ = try await client().refresh(policy: .always) }
    }

    @Test("a 304 persists the new fetch date")
    func notModifiedStamps() async throws {
        server.route(url, headers: ["ETag": "\"s1\""], body: try Data(contentsOf: SourcesClient.bundledURL))
        _ = try await client().refresh(policy: .always)
        server.route(url, status: 304, body: Data())
        let later = now.addingTimeInterval(500)
        _ = try await client(at: later).refresh(policy: .always)
        #expect(StorageLayout(root: tmp.url).sources.read()?.meta.fetchedAt == later)
    }

    @Test("ifStale serves a fresh cache without a request, and treats a future-stamped cache as stale")
    func freshness() async throws {
        server.route(url, headers: ["ETag": "\"s1\""], body: try Data(contentsOf: SourcesClient.bundledURL))
        _ = try await client().refresh(policy: .always)
        _ = try await client(at: now.addingTimeInterval(100)).refresh(policy: .ifStale)
        #expect(server.requests.count == 1)
        _ = try await client(at: now.addingTimeInterval(-100)).refresh(policy: .ifStale)
        #expect(server.requests.count == 2)
        _ = try await client(at: now.addingTimeInterval(3_600)).refresh(policy: .ifStale)
        #expect(server.requests.count == 2 + 1)
    }

    @Test("a transport error is a network error without a status code")
    func transport() async throws {
        server.route(url) { _ in StubResponse(transportError: .notConnectedToInternet) }
        await #expect(throws: SourcesError.network(statusCode: nil)) { _ = try await client().refresh(policy: .always) }
    }

    @Test("a cancelled request is a CancellationError, not a network error")
    func cancelled() async throws {
        server.route(url) { _ in StubResponse(transportError: .cancelled) }
        await #expect(throws: CancellationError.self) { _ = try await client().refresh(policy: .always) }
    }

    struct Invalid: Sendable, CustomTestStringConvertible {
        let name: String
        let layer: String
        let change: @Sendable (inout [String: Any]) -> Void
        let message: String
        var testDescription: String { name }
    }

    static let invalidCases: [Invalid] = [
        .init(name: "http tiles", layer: "terrain", change: { $0["tiles"] = "http://t.example/{z}/{x}/{y}" },
              message: "terrain.[0].tiles: must be https and contain {z}, {x} and {y}"),
        .init(name: "tiles without {y}", layer: "basemap", change: { $0["tiles"] = "https://t.example/{z}/{x}" },
              message: "basemap.[0].tiles: must be https and contain {z}, {x} and {y}"),
        .init(name: "http tilejson", layer: "basemap", change: { $0["tilejson"] = "http://t.example/tiles.json" },
              message: "basemap.[0].tilejson: must be an https URL with a host and no credentials"),
        .init(name: "negative min zoom", layer: "basemap", change: { $0["min_zoom"] = -1 },
              message: "basemap.[0].min_zoom: must be between 0 and max_zoom, at most 22"),
        .init(name: "min above max", layer: "basemap", change: { $0["min_zoom"] = 15 },
              message: "basemap.[0].min_zoom: must be between 0 and max_zoom, at most 22"),
        .init(name: "max above 22", layer: "terrain", change: { $0["max_zoom"] = 23 },
              message: "terrain.[0].max_zoom: must be between 0 and max_zoom, at most 22"),
        .init(name: "empty id", layer: "basemap", change: { $0["id"] = "" }, message: "basemap.[0].id: must not be empty"),
        .init(name: "empty provider", layer: "terrain", change: { $0["provider"] = "" }, message: "terrain.[0].provider: must not be empty"),
        .init(name: "no attribution", layer: "basemap", change: { $0["attribution"] = [String]() },
              message: "basemap.[0].attribution: must not be empty"),
        .init(name: "empty attribution string", layer: "terrain", change: { $0["attribution"] = [""] },
              message: "terrain.[0].attribution: must not contain empty strings"),
        .init(name: "missing tile size", layer: "terrain", change: { $0["tile_size"] = nil },
              message: "terrain.[0].tile_size: must be 256 or 512"),
        .init(name: "odd tile size", layer: "terrain", change: { $0["tile_size"] = 300 },
              message: "terrain.[0].tile_size: must be 256 or 512"),
        .init(name: "uppercase placeholder", layer: "basemap", change: { $0["tiles"] = "https://t.example/{Z}/{x}/{y}" },
              message: "basemap.[0].tiles: must be https and contain {z}, {x} and {y}"),
        .init(name: "tiles without host", layer: "basemap", change: { $0["tiles"] = "https:///{z}/{x}/{y}" },
              message: "basemap.[0].tiles: must be an https URL with a host and no credentials"),
        .init(name: "tiles with credentials", layer: "terrain", change: { $0["tiles"] = "https://u:p@t.example/{z}/{x}/{y}" },
              message: "terrain.[0].tiles: must be an https URL with a host and no credentials"),
        .init(name: "tilejson with credentials", layer: "terrain", change: { $0["tilejson"] = "https://u@t.example/tiles.json" },
              message: "terrain.[0].tilejson: must be an https URL with a host and no credentials"),
        .init(name: "tilejson without host", layer: "basemap", change: { $0["tilejson"] = "https:///tiles.json" },
              message: "basemap.[0].tilejson: must be an https URL with a host and no credentials"),
        .init(name: "id not kebab-case", layer: "basemap", change: { $0["id"] = "Versa_Tiles" },
              message: "basemap.[0].id: must be lowercase kebab-case"),
        .init(name: "basemap schema", layer: "basemap", change: { $0["schema"] = "terrarium" },
              message: "basemap.[0].schema: must be shortbread-1.0"),
        .init(name: "basemap format", layer: "basemap", change: { $0["format"] = "png" },
              message: "basemap.[0].format: must be mvt"),
        .init(name: "terrain schema", layer: "terrain", change: { $0["schema"] = "shortbread-1.0" },
              message: "terrain.[0].schema: must be terrarium"),
        .init(name: "terrain format", layer: "terrain", change: { $0["format"] = "mvt" },
              message: "terrain.[0].format: must be webp or png"),
    ]

    @Test("an empty layer list is rejected", arguments: ["basemap", "terrain"])
    func emptyLayer(_ layer: String) throws {
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: SourcesClient.bundledURL)) as? [String: Any])
        var layers = try #require(object["layers"] as? [String: [[String: Any]]])
        layers[layer] = []
        object["layers"] = layers
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: SourcesError.invalid("\(layer): must not be empty")) { try SourcesDocument.decode(data) }
    }

    @Test("a corrupt cached file falls back to the bundled copy and a refresh overwrites it without If-None-Match")
    func corruptCache() async throws {
        let cache = StorageLayout(root: tmp.url).sources
        try cache.write(data: Data("{not json".utf8), meta: .init(etag: "\"old\"", fetchedAt: now))
        #expect(client().current()?.basemap.first?.id == "versatiles-osm")
        server.route(url, headers: ["ETag": "\"s2\""], body: try Data(contentsOf: SourcesClient.bundledURL))
        _ = try await client().refresh(policy: .always)
        #expect(server.requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(cache.read()?.meta.etag == "\"s2\"")
        #expect(try SourcesDocument.decode(#require(cache.read()).data).version == 1)
    }

    @Test("a document that breaks the schema is rejected naming the field only", arguments: invalidCases)
    func invalid(_ testCase: Invalid) throws {
        let data = try bundledData(layer: testCase.layer, testCase.change)
        #expect(throws: SourcesError.invalid(testCase.message)) { try SourcesDocument.decode(data) }
    }
}
