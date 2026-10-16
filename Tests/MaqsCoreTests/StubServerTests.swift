import Foundation
import Testing
import MaqsTestSupport

@Suite struct StubServerTests {
    @Test("a routed URL answers with the scripted status and body")
    func routed() async throws {
        let server = StubServer()
        let url = URL(string: "https://example.test/a.json")!
        server.route(url, status: 201, headers: ["ETag": "\"x\""], body: Data("hi".utf8))
        let session = URLSession(configuration: server.configuration)
        let (data, response) = try await session.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 201)
        #expect(http.value(forHTTPHeaderField: "ETag") == "\"x\"")
        #expect(String(decoding: data, as: UTF8.self) == "hi")
        #expect(server.requests.count == 1)
    }

    @Test("an unrouted URL is a 404, never the network")
    func unrouted() async throws {
        let server = StubServer()
        let session = URLSession(configuration: server.configuration)
        let (_, response) = try await session.data(from: URL(string: "https://example.test/missing")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("a download task lands the body in a file")
    func download() async throws {
        let server = StubServer()
        let url = URL(string: "https://example.test/blob.bin")!
        server.route(url, body: Data(repeating: 7, count: 10_000))
        let session = URLSession(configuration: server.configuration)
        let (file, _) = try await session.download(from: url)
        #expect(try Data(contentsOf: file).count == 10_000)
    }
}
