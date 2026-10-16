import Foundation
import Synchronization
import Testing
@testable import MaqsCore
import MaqsTestSupport

@Suite struct ManifestClientTests {
    let server = StubServer()
    let tmp: TemporaryDirectory
    let clock = Clock()

    final class Clock: Sendable {
        private let value = Mutex(Date(timeIntervalSince1970: 1_000_000))
        var now: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    init() throws { tmp = try TemporaryDirectory() }

    func client(maxAge: Duration = .seconds(3_600)) -> ManifestClient {
        let http = HTTPClient(session: URLSession(configuration: server.configuration), userAgent: "Test/1 Maqs/0")
        return ManifestClient(http: http, cache: StorageLayout(root: tmp.url).manifest, url: Fixtures.manifestURL,
                              maxAge: maxAge, now: { [clock] in clock.now })
    }

    @Test("the first load fetches, caches the manifest and its etag, and records the fetch time")
    func firstLoad() async throws {
        try Fixtures.serveRelease(on: server)
        let loaded = try await client().load(policy: .ifStale)
        #expect(loaded.manifest.release == "data-ci")
        #expect(loaded.fetchedAt == clock.now)
        #expect(server.requests.count == 1)
        #expect(server.requests[0].value(forHTTPHeaderField: "User-Agent") == "Test/1 Maqs/0")
        #expect(server.requests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        let cached = try #require(StorageLayout(root: tmp.url).manifest.read())
        #expect(cached.meta.etag == "\"fixture-etag\"")
    }

    @Test("ifStale makes no request while the cache is fresh, and fetches once it is stale")
    func ifStale() async throws {
        try Fixtures.serveRelease(on: server)
        _ = try await client().load(policy: .ifStale)
        clock.advance(100)
        _ = try await client().load(policy: .ifStale)
        #expect(server.requests.count == 1)
        clock.advance(3_600)
        _ = try await client().load(policy: .ifStale)
        #expect(server.requests.count == 2)
    }

    @Test("always sends If-None-Match and a 304 keeps the manifest but refreshes the fetch time")
    func notModified() async throws {
        try Fixtures.serveRelease(on: server)
        _ = try await client().load(policy: .always)
        clock.advance(10)
        let second = try await client().load(policy: .always)
        #expect(server.requests.count == 2)
        #expect(server.requests[1].value(forHTTPHeaderField: "If-None-Match") == "\"fixture-etag\"")
        #expect(second.fetchedAt == clock.now)
        #expect(second.manifest.release == "data-ci")
    }

    @Test("a 429 is rateLimited and the cached manifest stays")
    func rateLimited() async throws {
        try Fixtures.serveRelease(on: server)
        _ = try await client().load(policy: .always)
        server.route(Fixtures.manifestURL, status: 429, body: Data())
        await #expect(throws: ManifestError.rateLimited) { _ = try await client().load(policy: .always) }
        #expect(client().cached()?.manifest.release == "data-ci")
    }

    @Test("a 500 is a network error with the status code")
    func serverError() async throws {
        server.route(Fixtures.manifestURL, status: 500, body: Data())
        await #expect(throws: ManifestError.network(statusCode: 500)) { _ = try await client().load(policy: .always) }
        #expect(client().cached() == nil)
    }

    @Test("a rejected body keeps the previous cached manifest")
    func rejectedBody() async throws {
        try Fixtures.serveRelease(on: server)
        _ = try await client().load(policy: .always)
        let bad = try Fixtures.manifestJSON { $0["manifest_version"] = 2 }
        server.route(Fixtures.manifestURL, body: bad)
        await #expect(throws: ManifestError.unsupportedVersion(2)) { _ = try await client().load(policy: .always) }
        #expect(client().cached()?.manifest.release == "data-ci")
    }

    @Test("a new client over the same directory starts from the cache")
    func persistence() async throws {
        try Fixtures.serveRelease(on: server)
        _ = try await client().load(policy: .always)
        let fresh = client()
        let cached = try #require(fresh.cached())
        #expect(cached.manifest.release == "data-ci")
        #expect(cached.fetchedAt == clock.now)
    }

    @Test("a cached manifest that no longer decodes is dropped, not served")
    func corruptCache() async throws {
        let document = StorageLayout(root: tmp.url).manifest
        try document.write(data: Data("nope".utf8), meta: .init(etag: nil, fetchedAt: clock.now))
        #expect(client().cached() == nil)
    }

    @Test("the session never sends no-cache")
    func noCacheHeader() async throws {
        try Fixtures.serveRelease(on: server)
        _ = try await client().load(policy: .always)
        #expect(server.requests[0].value(forHTTPHeaderField: "Cache-Control") == nil)
        #expect(server.requests[0].cachePolicy == .useProtocolCachePolicy)
    }
}
