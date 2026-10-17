import Foundation
import Observation
import Synchronization
import Testing
@testable import MaqsCore
import MaqsTestSupport

@MainActor
@Suite struct BasePackTests {
    let server = StubServer()
    let tmp: TemporaryDirectory
    let manifest: Manifest
    let base = PackID.base("triveneto")
    let region = PackID.region("test")

    init() throws {
        tmp = try TemporaryDirectory()
        // The real base pack is not committed: point its manifest entry at the test basemap's bytes.
        let digest = try Fixtures.digest("test/test-basemap.v1.pmtiles")
        let data = try Fixtures.manifestJSON { object in
            var packs = object["base"] as! [[String: Any]]
            var layers = packs[0]["layers"] as! [String: [[String: Any]]]
            layers["basemap"]![0]["sha256"] = digest.sha256
            layers["basemap"]![0]["bytes"] = digest.bytes
            packs[0]["layers"] = layers
            object["base"] = packs
        }
        try Fixtures.serveRelease(on: server, manifest: data)
        manifest = try Manifest.decode(data, manifestHost: "github.com")
    }

    func maqs() throws -> Maqs {
        var configuration = MaqsConfiguration(layers: [.basemap], userAgent: "Test/1")
        configuration.storageDirectory = tmp.url
        configuration.urlSessionConfiguration = server.configuration
        return try Maqs(configuration: configuration)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    /// Suspends until `condition` holds, checking again after each change to the observed state.
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        while !condition() {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }

    @Test("a base pack downloads like a region")
    func download() async throws {
        let maqs = try maqs()
        let catalog = try await maqs.refreshCatalog()
        #expect(catalog.basePacks.map(\.id) == [base])
        try await maqs.install(base)
        let pack = try #require(await maqs.installedPack(base))
        #expect(pack.files[.basemap]?.count == 1)
        #expect(pack.bundled == false)
        #expect(maqs.state.catalog?.pack(base)?.status == .installed(release: "data-ci"))
    }

    @Test("a bundled base pack is installed without a download and remove only unregisters it")
    func bundled() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        let file = try Fixtures.url("test/test-basemap.v1.pmtiles")
        try await maqs.registerBundledBasePack(id: "triveneto", basemap: file)
        let pack = try #require(await maqs.installedPack(base))
        #expect(pack.bundled && pack.release == "bundled")
        #expect(pack.files[.basemap]?.first?.url == file)
        #expect(pack.files[.basemap]?.first?.sha256 == nil)
        #expect(maqs.state.packs[base] == .installed(pack))
        #expect(maqs.state.catalog?.pack(base)?.status == .installed(release: "bundled"))
        #expect(await maqs.diskUsage().bytesByPack[base] == nil)
        #expect(!server.requests.contains { $0.url?.lastPathComponent.hasPrefix("base-") == true })
        try await maqs.remove(base)
        #expect(await maqs.installedPack(base) == nil)
        #expect(maqs.state.packs[base] == .notInstalled)
        #expect(maqs.state.catalog?.pack(base)?.status == .notInstalled)
        #expect(exists(file))
    }

    @Test("install of a pack registered as bundled returns at once: no request, no record, state unchanged")
    func installBundled() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        try await maqs.registerBundledBasePack(id: "triveneto", basemap: try Fixtures.url("test/test-basemap.v1.pmtiles"))
        let before = maqs.state.packs[base]
        try await maqs.install(base)
        #expect(!server.requests.contains { $0.url?.lastPathComponent.hasPrefix("base-") == true })
        #expect(!exists(tmp.url.appending(path: "packs/base-triveneto/pack.json")))
        #expect(maqs.state.packs[base] == before)
    }

    @Test("an install queued before a refresh uses the refreshed manifest's entries when its turn comes")
    func replansAtTurn() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        let regionEntry = try #require(manifest.regions[0].entries(for: .basemap)?.first)
        let oldBase = try #require(manifest.base[0].entries(for: .basemap)?.first)
        let (reached, signal) = AsyncStream<Void>.makeStream()
        server.route(regionEntry.url) { _ in
            signal.yield()
            return StubResponse(status: 200, body: Data(repeating: 0, count: Int(regionEntry.bytes)), delay: 30)
        }
        let first = Task { try await maqs.install(region) }
        var iterator = reached.makeAsyncIterator()
        _ = await iterator.next()
        let queued = Task { try await maqs.install(base) }
        await waitUntil { maqs.state.packs[base] == .queued }

        // The next release renames the base file; the queued install must fetch the new one.
        let digest = try Fixtures.digest("test/test-basemap.v1.pmtiles")
        let newFile = "base-triveneto-next.v1.pmtiles"
        let next = try Fixtures.manifestJSON { object in
            object["release"] = "data-next"
            var packs = object["base"] as! [[String: Any]]
            var layers = packs[0]["layers"] as! [String: [[String: Any]]]
            layers["basemap"]![0]["sha256"] = digest.sha256
            layers["basemap"]![0]["bytes"] = digest.bytes
            layers["basemap"]![0]["file"] = newFile
            layers["basemap"]![0]["url"] = "https://github.com/lucavallin/maqs/releases/download/data-next/\(newFile)"
            packs[0]["layers"] = layers
            object["base"] = packs
        }
        try Fixtures.serveRelease(on: server, manifest: next, etag: "\"next\"")
        #expect(try await maqs.refreshCatalog(policy: .always).release == "data-next")
        await maqs.cancelInstall(region)
        await #expect(throws: MaqsError.download(.cancelled)) { try await first.value }
        try await queued.value

        let pack = try #require(await maqs.installedPack(base))
        #expect(pack.release == "data-next")
        #expect(pack.files[.basemap]?.first?.url.lastPathComponent == newFile)
        #expect(server.requests.contains { $0.url?.lastPathComponent == newFile })
        #expect(!server.requests.contains { $0.url == oldBase.url })
    }

    @Test("registering a missing file is a typed storage error")
    func missingFile() async throws {
        let maqs = try maqs()
        await #expect(throws: MaqsError.storage(.fileNotFound("nope.pmtiles"))) {
            try await maqs.registerBundledBasePack(id: "x", basemap: tmp.url.appending(path: "nope.pmtiles"))
        }
        #expect(await maqs.installedPack(.base("x")) == nil)
    }

    @Test("installs run one at a time: the second pack's download starts only after the first pack's install ends")
    func oneAtATime() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        let regionEntry = try #require(manifest.regions[0].entries(for: .basemap)?.first)
        let baseEntry = try #require(manifest.base[0].entries(for: .basemap)?.first)
        let body = try Data(contentsOf: try Fixtures.url("test/test-basemap.v1.pmtiles"))
        let arrivals = Mutex<[PackID: ContinuousClock.Instant]>([:])
        let (reached, signal) = AsyncStream<Void>.makeStream()
        server.route(regionEntry.url) { [region] _ in
            arrivals.withLock { $0[region] = .now }
            signal.yield()
            return StubResponse(status: 200, body: body, delay: 0.5)
        }
        server.route(baseEntry.url) { [base] _ in
            arrivals.withLock { $0[base] = .now }
            return StubResponse(status: 200, body: body)
        }
        let first = Task { try await maqs.install(region) }
        var iterator = reached.makeAsyncIterator()
        _ = await iterator.next()
        let second = Task { try await maqs.install(base) }
        try await first.value
        try await second.value
        // The region's file arrives 0.5 s after its request, so a base download that did not wait starts sooner.
        let seen = arrivals.withLock { $0 }
        let regionArrival = try #require(seen[region])
        let baseArrival = try #require(seen[base])
        #expect(regionArrival.duration(to: baseArrival) >= .milliseconds(450))
        #expect(await maqs.installedPack(region) != nil)
        #expect(await maqs.installedPack(base) != nil)
    }

    @Test("a queued install cancelled ends at once while the running one goes on; the next queued one runs after it")
    func cancelQueued() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        let regionEntry = try #require(manifest.regions[0].entries(for: .basemap)?.first)
        let baseEntry = try #require(manifest.base[0].entries(for: .basemap)?.first)
        let (reached, signal) = AsyncStream<Void>.makeStream()
        server.route(regionEntry.url) { _ in
            signal.yield()
            return StubResponse(status: 200, body: Data(repeating: 0, count: Int(regionEntry.bytes)), delay: 30)
        }
        let isDownloading: @MainActor (PackID) -> Bool = { id in
            if case .downloading? = maqs.state.packs[id] { true } else { false }
        }
        let first = Task { try await maqs.install(region) }
        var iterator = reached.makeAsyncIterator()
        _ = await iterator.next()

        // Queued behind the running install: no request, and a cancel ends it without waiting for the first.
        let queued = Task { try await maqs.install(base) }
        await waitUntil { maqs.state.packs[base] == .queued }
        await maqs.cancelInstall(base)
        await #expect(throws: MaqsError.download(.cancelled)) { try await queued.value }
        #expect(maqs.state.packs[base] == .notInstalled)
        #expect(isDownloading(region))
        #expect(!server.requests.contains { $0.url == baseEntry.url })

        // Queued again; it runs once the first install ends.
        let next = Task { try await maqs.install(base) }
        await waitUntil { maqs.state.packs[base] == .queued }
        #expect(!server.requests.contains { $0.url == baseEntry.url })
        await maqs.cancelInstall(region)
        await #expect(throws: MaqsError.download(.cancelled)) { try await first.value }
        try await next.value
        #expect(await maqs.installedPack(base) != nil)
        #expect(await maqs.installedPack(region) == nil)
        #expect(maqs.state.packs[region] == .notInstalled)
    }
}
