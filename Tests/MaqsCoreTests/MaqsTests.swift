import Foundation
import Testing
@testable import MaqsCore
import MaqsTestSupport

@MainActor
@Suite struct MaqsTests {
    let server = StubServer()
    let tmp: TemporaryDirectory
    let manifest: Manifest
    let test = PackID.region("test")

    init() throws {
        tmp = try TemporaryDirectory()
        try Fixtures.serveRelease(on: server)
        manifest = try Manifest.decode(try Fixtures.manifestData(), manifestHost: "github.com")
    }

    func maqs(layers: Set<Layer> = [.trails, .places], onlineTiles: Bool = true) throws -> Maqs {
        var configuration = MaqsConfiguration(layers: layers, userAgent: "Test/1")
        configuration.storageDirectory = tmp.url
        configuration.urlSessionConfiguration = server.configuration
        configuration.onlineTiles = onlineTiles
        return try Maqs(configuration: configuration)
    }

    func entries(_ layer: Layer) throws -> [ManifestEntry] { try #require(manifest.regions[0].entries(for: layer)) }
    func main(_ layer: Layer) throws -> ManifestEntry { try #require(try entries(layer).first { $0.role == nil }) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
    var downloads: URL { tmp.url.appending(path: "downloads", directoryHint: .isDirectory) }

    /// Routes `entry` to a body of its listed size, delivered after `delay` seconds, and returns a stream that yields
    /// each time a request for it reaches the stub.
    func routeSlow(_ entry: ManifestEntry, delay: TimeInterval) -> AsyncStream<Void> {
        let (reached, continuation) = AsyncStream<Void>.makeStream()
        let body = Data(repeating: 0, count: Int(entry.bytes))
        server.route(entry.url) { _ in
            continuation.yield()
            return StubResponse(status: 200, body: body, delay: delay)
        }
        return reached
    }

    /// Waits until every stream has yielded once.
    func waitForRequests(_ streams: [AsyncStream<Void>]) async {
        for stream in streams {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    // MARK: Discovery

    @Test("refreshCatalog publishes the catalog and clears the last error")
    func refresh() async throws {
        let maqs = try maqs()
        let catalog = try await maqs.refreshCatalog(policy: .always)
        #expect(catalog.release == "data-ci")
        #expect(maqs.state.catalog == catalog)
        #expect(maqs.state.lastRefreshError == nil)
        #expect(maqs.state.packs[test] == nil || maqs.state.packs[test] == .notInstalled)
    }

    @Test("a failed refresh is a typed error, recorded in state, and the previous catalog stays")
    func refreshFails() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog(policy: .always)
        server.route(Fixtures.manifestURL, status: 429, body: Data())
        await #expect(throws: MaqsError.manifest(.rateLimited)) { _ = try await maqs.refreshCatalog(policy: .always) }
        #expect(maqs.state.lastRefreshError == .manifest(.rateLimited))
        #expect(maqs.state.catalog?.release == "data-ci")
    }

    @Test("a cancelled refresh rethrows CancellationError and leaves lastRefreshError as it was")
    func refreshCancelled() async throws {
        let maqs = try maqs()
        server.route(Fixtures.manifestURL, status: 429, body: Data())
        await #expect(throws: MaqsError.manifest(.rateLimited)) { _ = try await maqs.refreshCatalog(policy: .always) }
        let (reached, signal) = AsyncStream<Void>.makeStream()
        server.route(Fixtures.manifestURL) { _ in
            signal.yield()
            return StubResponse(status: 200, body: Data(), delay: 30)
        }
        let task = Task { try await maqs.refreshCatalog(policy: .always) }
        await waitForRequests([reached])
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(maqs.state.lastRefreshError == .manifest(.rateLimited))
        #expect(maqs.state.catalog == nil)
    }

    @Test("a refresh deletes downloads no entry of the new manifest names, with their resume data, and keeps the rest")
    func prunesDownloads() async throws {
        let maqs = try maqs()
        let staleKey = String(repeating: "0", count: 64) + "-old.v1.sqlite"
        let entry = try main(.trails)
        let currentKey = "\(entry.sha256)-\(entry.file)"
        let stale = [downloads.appending(path: staleKey), downloads.appending(path: staleKey + ".resume")]
        let current = [downloads.appending(path: currentKey), downloads.appending(path: currentKey + ".resume")]
        for url in stale + current { try Data("x".utf8).write(to: url) }
        _ = try await maqs.refreshCatalog(policy: .always)
        for url in stale { #expect(!exists(url)) }
        for url in current { #expect(exists(url)) }
    }

    @Test("a refresh while an install runs leaves downloads alone")
    func keepsDownloadsDuringInstall() async throws {
        let maqs = try maqs(layers: [.trails])
        _ = try await maqs.refreshCatalog()
        let reached = try entries(.trails).map { routeSlow($0, delay: 30) }
        let task = Task { try await maqs.install(test) }
        await waitForRequests(reached)
        let stale = downloads.appending(path: String(repeating: "0", count: 64) + "-old.v1.sqlite")
        try Data("x".utf8).write(to: stale)
        _ = try await maqs.refreshCatalog(policy: .always)
        #expect(exists(stale))
        await maqs.cancelInstall(test)
        await #expect(throws: MaqsError.download(.cancelled)) { try await task.value }
    }

    // MARK: Install

    @Test("install before any catalog is noCatalog; an unknown pack is notInCatalog")
    func installPreconditions() async throws {
        let maqs = try maqs()
        await #expect(throws: MaqsError.download(.noCatalog)) { try await maqs.install(test) }
        _ = try await maqs.refreshCatalog()
        await #expect(throws: MaqsError.download(.notInCatalog(.region("atlantis")))) { try await maqs.install(.region("atlantis")) }
        #expect(maqs.state.packs[.region("atlantis")] == nil)
    }

    @Test("a pack that offers none of the configured layers is notInCatalog and nothing is written")
    func noConfiguredLayer() async throws {
        let maqs = try maqs(layers: [.trails])
        _ = try await maqs.refreshCatalog()
        let base = PackID.base("triveneto")
        await #expect(throws: MaqsError.download(.notInCatalog(base))) { try await maqs.install(base) }
        #expect(!exists(tmp.url.appending(path: "packs/base-triveneto")))
        #expect(maqs.state.packs[base] == nil)
        #expect(server.requests.count == 1)
    }

    @Test("install walks downloading → verifying → installed and the catalog shows installed")
    func install() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        try await maqs.install(test)
        guard case .installed(let pack)? = maqs.state.packs[test] else {
            Issue.record("not installed: \(String(describing: maqs.state.packs[test]))")
            return
        }
        #expect(pack.files[.trails]?.count == 2)
        #expect(pack.files[.places]?.count == 2)
        #expect(pack.files.values.flatMap { $0 }.allSatisfy { exists($0.url) })
        #expect(await maqs.installedPack(test) == pack)
        #expect(maqs.state.catalog?.pack(test)?.status == .installed(release: "data-ci"))
        let usage = await maqs.diskUsage()
        #expect(usage.bytesByPack[test] == pack.bytes)
        #expect(usage.downloadsBytes == 0)
        #expect(usage.total == pack.bytes)
    }

    @Test("concurrent installs of one pack are one install")
    func concurrentInstalls() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        let before = server.requests.count
        async let first: Void = maqs.install(test)
        async let second: Void = maqs.install(test)
        _ = try await (first, second)
        #expect(server.requests.count - before == 4)
        #expect(await maqs.installedPack(test) != nil)
    }

    @Test("a second install of a running pack joins it: one download, the same outcome for both calls")
    func joinsRunningInstall() async throws {
        let maqs = try maqs(layers: [.trails])
        _ = try await maqs.refreshCatalog()
        let main = try main(.trails)
        // A same-size body with other bytes: the install fails at the checksum, after the request.
        let reached = routeSlow(main, delay: 0.5)
        let first = Task { try await maqs.install(test) }
        await waitForRequests([reached])
        let second = Task { try await maqs.install(test) }
        let failure = MaqsError.download(.checksumMismatch(file: main.file))
        await #expect(throws: failure) { try await first.value }
        await #expect(throws: failure) { try await second.value }
        #expect(server.requests.filter { $0.url == main.url }.count == 1)
        #expect(maqs.state.packs[test] == .failed(failure))
    }

    @Test("a checksum failure leaves the pack failed with the typed error and nothing installed")
    func failedInstall() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        let main = try main(.trails)
        server.route(main.url, body: Data(repeating: 0, count: Int(main.bytes)))
        await #expect(throws: MaqsError.download(.checksumMismatch(file: main.file))) { try await maqs.install(test) }
        #expect(maqs.state.packs[test] == .failed(.download(.checksumMismatch(file: main.file))))
        #expect(await maqs.installedPack(test) == nil)
    }

    @Test("cancelInstall returns the pack to notInstalled and the call throws cancelled")
    func cancel() async throws {
        let maqs = try maqs(layers: [.trails])
        _ = try await maqs.refreshCatalog()
        let reached = try entries(.trails).map { routeSlow($0, delay: 30) }
        let task = Task { try await maqs.install(test) }
        await waitForRequests(reached)
        await maqs.cancelInstall(test)
        await #expect(throws: MaqsError.download(.cancelled)) { try await task.value }
        #expect(maqs.state.packs[test] == .notInstalled)
        #expect(await maqs.installedPack(test) == nil)
    }

    @Test("cancelling an update leaves the installed pack installed")
    func cancelUpdate() async throws {
        let maqs = try maqs(layers: [.places])
        _ = try await maqs.refreshCatalog()
        try await maqs.install(test)
        let installed = try #require(await maqs.installedPack(test))
        let grown = try self.maqs(layers: [.places, .trails])
        _ = try await grown.refreshCatalog()
        let reached = try entries(.trails).map { routeSlow($0, delay: 30) }
        let task = Task { try await grown.install(test) }
        await waitForRequests(reached)
        await grown.cancelInstall(test)
        await #expect(throws: MaqsError.download(.cancelled)) { try await task.value }
        #expect(grown.state.packs[test] == .installed(installed))
    }

    @Test("remove deletes the pack and updates state and catalog")
    func remove() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        try await maqs.install(test)
        try await maqs.remove(test)
        #expect(maqs.state.packs[test] == .notInstalled)
        #expect(await maqs.installedPack(test) == nil)
        #expect(maqs.state.catalog?.pack(test)?.status == .notInstalled)
        #expect(!exists(tmp.url.appending(path: "packs/region-test")))
    }

    @Test("a new instance over the same directory starts from the installed packs and the cached catalog")
    func persistence() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        try await maqs.install(test)
        let again = try self.maqs()
        #expect(again.state.catalog?.release == "data-ci")
        guard case .installed(let pack)? = again.state.packs[test] else {
            Issue.record("not restored")
            return
        }
        #expect(pack.files[.trails]?.count == 2)
        #expect(again.state.catalog?.pack(test)?.status == .installed(release: "data-ci"))
    }

    // MARK: Progress

    @Test("progress keeps the maximum, publishes at most every 256 KiB, and always publishes the final value")
    func progressThrottle() {
        func progress(_ bytes: Int64) -> DownloadProgress { DownloadProgress(bytesReceived: bytes, totalBytes: 1_000_000) }
        var throttle = Maqs.ProgressThrottle()
        #expect(throttle.accept(progress(100)) == nil)
        #expect(throttle.accept(progress(300_000)) == progress(300_000))
        #expect(throttle.accept(progress(200_000)) == nil)
        #expect(throttle.accept(progress(400_000)) == nil)
        #expect(throttle.accept(progress(350_000)) == nil)
        #expect(throttle.accept(progress(600_000)) == progress(600_000))
        #expect(throttle.accept(progress(1_000_000)) == progress(1_000_000))
        #expect(throttle.accept(progress(1_000_000)) == nil)
        #expect(throttle.accept(progress(900_000)) == nil)
    }

    // MARK: Online sources

    @Test("onlineTiles false hides the sources and refreshOnlineSources makes no request")
    func optOut() async throws {
        let maqs = try maqs(onlineTiles: false)
        #expect(await maqs.onlineSources == nil)
        #expect(try await maqs.refreshOnlineSources(policy: .always) == nil)
        #expect(server.requests.isEmpty)
        let online = try self.maqs(onlineTiles: true)
        #expect(await online.onlineSources?.basemap.first?.id == "versatiles-osm")
    }

    @Test("the User-Agent on every request is the app string plus the package token")
    func userAgent() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog(policy: .always)
        try await maqs.install(test)
        #expect(!server.requests.isEmpty)
        #expect(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "Test/1 Maqs/\(MaqsVersion.string)" })
    }
}
