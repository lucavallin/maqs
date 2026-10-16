import Foundation
import Testing
import MaqsTestSupport

@Suite struct FixturesTests {
    @Test("the fixture manifest is the data-ci manifest and names only fixture files")
    func manifest() throws {
        let data = try Fixtures.manifestData()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["release"] as? String == "data-ci")
        let entries = try Fixtures.entryURLs(in: data)
        #expect(!entries.isEmpty)
        for (_, file) in entries where !file.hasPrefix("base-") {
            _ = try Fixtures.url("test/\(file)")
        }
    }

    @Test("a missing fixture is a thrown error with the path")
    func missing() {
        #expect(throws: Fixtures.Missing.self) { try Fixtures.url("test/nope.bin") }
    }

    @Test("serveRelease answers the manifest, a 304 on the etag, and every entry")
    func serve() async throws {
        let server = StubServer()
        try Fixtures.serveRelease(on: server)
        let session = URLSession(configuration: server.configuration)
        let (_, response) = try await session.data(from: Fixtures.manifestURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var conditional = URLRequest(url: Fixtures.manifestURL)
        conditional.setValue("\"fixture-etag\"", forHTTPHeaderField: "If-None-Match")
        let (_, cached) = try await session.data(for: conditional)
        #expect((cached as? HTTPURLResponse)?.statusCode == 304)
        for (url, _) in try Fixtures.entryURLs(in: try Fixtures.manifestData()) {
            let (data, entryResponse) = try await session.data(from: url)
            #expect((entryResponse as? HTTPURLResponse)?.statusCode == 200)
            #expect(!data.isEmpty)
        }
    }
}
