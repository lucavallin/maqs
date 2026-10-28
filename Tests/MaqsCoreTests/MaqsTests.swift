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

    func maqs(layers: Set<Layer> = [.trails, .places], onlineTiles: Bool = true, root: URL? = nil,
              userAgent: String = "Test/1") throws -> Maqs {
        var configuration = MaqsConfiguration(layers: layers, userAgent: userAgent)
        configuration.storageDirectory = root ?? tmp.url
        configuration.urlSessionConfiguration = server.configuration
        configuration.onlineTiles = onlineTiles
        return try Maqs(configuration: configuration)
    }

    func entries(_ layer: Layer) throws -> [ManifestEntry] { try #require(manifest.regions[0].entries(for: layer)) }
    func main(_ layer: Layer) throws -> ManifestEntry { try #require(try entries(layer).first { $0.role == nil }) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
    func fixture(_ entry: ManifestEntry) throws -> Data { try Data(contentsOf: try Fixtures.url("test/\(entry.file)")) }
    var downloads: URL { tmp.url.appending(path: "downloads", directoryHint: .isDirectory) }

    /// Routes `entry` to `body` (default: zeros of its listed size), delivered after `delay` seconds or, with a `gate`,
    /// once the test releases it, and returns a stream that yields each time a request for it reaches the stub.
    func routeSlow(_ entry: ManifestEntry, delay: TimeInterval = 0, gate: StubGate? = nil, body: Data? = nil)
        -> AsyncStream<Void> {
        let (reached, continuation) = AsyncStream<Void>.makeStream()
        let body = body ?? Data(repeating: 0, count: Int(entry.bytes))
        server.route(entry.url) { _ in
            continuation.yield()
            return StubResponse(status: 200, body: body, delay: delay, gate: gate)
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

    // MARK: Configuration

    @Test("a blank userAgent is refused before anything is written", arguments: ["", "   "])
    func blankUserAgent(_ userAgent: String) {
        let root = tmp.url.appending(path: "root", directoryHint: .isDirectory)
        #expect(throws: MaqsError.invalidConfiguration("userAgent: must not be blank")) {
            _ = try maqs(root: root, userAgent: userAgent)
        }
        #expect(!exists(root))
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

    /// Ids that break the manifest's rule (lowercase kebab-case, at most 64 characters), path traversals first.
    nonisolated static let invalidIDs = ["triveneto/../../victim", "triveneto/../../../victim", "../victim", "", "Triveneto", "a b",
                             "-a", "a-", "a--b", "é", String(repeating: "a", count: 65)]

    @Test("remove refuses an invalid pack id and deletes nothing outside the packs folder", arguments: invalidIDs)
    func removeInvalidID(_ id: String) async throws {
        let root = tmp.url.appending(path: "root", directoryHint: .isDirectory)
        let maqs = try maqs(root: root)
        // The folder a traversal starts from exists, as it does once the base pack is installed.
        try FileManager.default.createDirectory(at: root.appending(path: "packs/base-triveneto"), withIntermediateDirectories: true)
        let victims = [tmp.url.appending(path: "victim"), root.appending(path: "victim")]
        for victim in victims {
            try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: victim.appending(path: "pack.json"))
        }
        await #expect(throws: MaqsError.storage(.invalidPackID(.base(id)))) { try await maqs.remove(.base(id)) }
        for victim in victims { #expect(exists(victim.appending(path: "pack.json"))) }
        #expect(maqs.state.packs[.base(id)] == nil)
    }

    @Test("install, registerBundledBasePack and installedPack refuse an invalid pack id", arguments: invalidIDs)
    func invalidIDElsewhere(_ id: String) async throws {
        // A pack folder sits three levels below the temporary directory, as deep as the longest traversal in
        // `invalidIDs` climbs, so no path this test computes leaves it.
        let root = tmp.url.appending(path: "root", directoryHint: .isDirectory)
        let maqs = try maqs(root: root)
        _ = try await maqs.refreshCatalog()
        await #expect(throws: MaqsError.download(.notInCatalog(.base(id)))) { try await maqs.install(.base(id)) }
        await #expect(throws: MaqsError.download(.notInCatalog(.region(id)))) { try await maqs.install(.region(id)) }
        let file = try Fixtures.url("test/test-basemap.v1.pmtiles")
        await #expect(throws: MaqsError.storage(.invalidPackID(.base(id)))) {
            try await maqs.registerBundledBasePack(id: id, basemap: file)
        }
        // A record planted at the id's path is not read.
        try FileManager.default.createDirectory(at: root.appending(path: "packs/base-triveneto"), withIntermediateDirectories: true)
        try? PackStore(root: root).write(PackRecord(id: .base(id), release: "planted", files: [:]))
        #expect(await maqs.installedPack(.base(id)) == nil)
        #expect(maqs.state.packs[.base(id)] == nil)
        #expect(maqs.state.packs[.region(id)] == nil)
        #expect(server.requests.count == 1)
    }

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
        let gate = StubGate()
        defer { gate.release() }
        // A same-size body with other bytes: the install fails at the checksum, after the request.
        let reached = routeSlow(main, gate: gate)
        let first = Task { try await maqs.install(test) }
        await waitForRequests([reached])
        // What install(_:) waits for, registered while the answer is held, so it can only join the running install.
        let second = try #require(try await maqs.startInstall(test))
        gate.release()
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

    @Test("an install called after cancelInstall, before the cancelled one has ended, starts afresh instead of joining it")
    func retryAfterCancel() async throws {
        let maqs = try maqs(layers: [.trails])
        _ = try await maqs.refreshCatalog()
        let entries = try entries(.trails)
        let reached = entries.map { routeSlow($0, delay: 30) }
        let first = Task { try await maqs.install(test) }
        await waitForRequests(reached)
        // New requests get the real files; the held ones stay held until they are cancelled.
        for entry in entries { server.route(entry.url, body: try fixture(entry)) }
        await maqs.cancelInstall(test)
        try await maqs.install(test)
        await #expect(throws: MaqsError.download(.cancelled)) { try await first.value }
        let pack = try #require(await maqs.installedPack(test))
        #expect(maqs.state.packs[test] == .installed(pack))
    }

    /// Starts an install of the `test` region whose requests are held, waits until they reach the stub, and routes
    /// the real files for every later request, so an install that is not stopped installs the pack.
    func startHeldInstall(_ maqs: Maqs) async throws -> Task<Void, any Error> {
        let entries = try entries(.trails)
        let reached = entries.map { routeSlow($0, delay: 30) }
        let first = Task { try await maqs.install(test) }
        await waitForRequests(reached)
        for entry in entries { server.route(entry.url, body: try fixture(entry)) }
        return first
    }

    @Test("a retry cancelled while the cancelled install before it is still settling throws cancelled and fetches nothing")
    func cancelRetryWhileSettling() async throws {
        let maqs = try maqs(layers: [.trails])
        _ = try await maqs.refreshCatalog()
        let first = try await startHeldInstall(maqs)
        let requests = server.requests.count
        let pack = test
        let retry = try await retryWhileSettling(pack, on: maqs) { $0.cancelInstall(pack) }
        await #expect(throws: MaqsError.download(.cancelled)) { try await retry.value }
        await #expect(throws: MaqsError.download(.cancelled)) { try await first.value }
        #expect(server.requests.count == requests)
        #expect(await maqs.installedPack(test) == nil)
        #expect(maqs.state.packs[test] == .notInstalled)
    }

    @Test("remove after cancelInstall and a retry, while the cancelled install is settling, leaves nothing installed")
    func removeRetryWhileSettling() async throws {
        let maqs = try maqs(layers: [.trails])
        _ = try await maqs.refreshCatalog()
        let first = try await startHeldInstall(maqs)
        let retry = try await retryWhileSettling(test, on: maqs)
        try await maqs.remove(test)
        let directory = tmp.url.appending(path: "packs/region-test")
        #expect(!exists(directory))
        _ = try? await retry.value
        await #expect(throws: MaqsError.download(.cancelled)) { try await first.value }
        #expect(!exists(directory))
        #expect(await maqs.installedPack(test) == nil)
        #expect(maqs.state.packs[test] == .notInstalled)
    }

    @Test("remove during an install cancels it and leaves no pack.json and no pack files")
    func removeDuringInstall() async throws {
        let maqs = try maqs(layers: [.trails])
        _ = try await maqs.refreshCatalog()
        // The real files, held until the test ends, so the install is still running when remove is called.
        let gate = StubGate()
        defer { gate.release() }
        let reached = try entries(.trails).map { routeSlow($0, gate: gate, body: try fixture($0)) }
        let task = Task { try await maqs.install(test) }
        await waitForRequests(reached)
        try await maqs.remove(test)
        await #expect(throws: MaqsError.download(.cancelled)) { try await task.value }
        #expect(!exists(tmp.url.appending(path: "packs/region-test")))
        #expect(await maqs.installedPack(test) == nil)
        #expect(maqs.state.packs[test] == .notInstalled)
    }

    @Test("remove deletes the pack's downloads and their resume data, and keeps other files in downloads")
    func removeDeletesDownloads() async throws {
        let maqs = try maqs()
        _ = try await maqs.refreshCatalog()
        let entry = try main(.trails)
        let key = "\(entry.sha256)-\(entry.file)"
        let own = [downloads.appending(path: key), downloads.appending(path: key + ".resume")]
        let baseEntry = try #require(manifest.base[0].entries(for: .basemap)?.first)
        let other = downloads.appending(path: "\(baseEntry.sha256)-\(baseEntry.file)")
        for url in own + [other] { try Data(repeating: 1, count: 1_000).write(to: url) }
        let before = await maqs.diskUsage().downloadsBytes
        try await maqs.remove(test)
        for url in own { #expect(!exists(url)) }
        #expect(exists(other))
        #expect(await maqs.diskUsage().downloadsBytes == before - 2_000)
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

    @Test("progress keeps the maximum, publishes at most every 256 KiB and every 100 ms, and always the final value")
    func progressThrottle() {
        let start = ContinuousClock.now
        var throttle = Maqs.ProgressThrottle()
        func accept(_ bytes: Int64, at milliseconds: Int) -> Int64? {
            throttle.accept(DownloadProgress(bytesReceived: bytes, totalBytes: 2_000_000),
                            at: start.advanced(by: .milliseconds(milliseconds)))?.bytesReceived
        }
        #expect(accept(100, at: 0) == nil)                    // under 256 KiB
        #expect(accept(300_000, at: 10) == 300_000)
        #expect(accept(700_000, at: 50) == nil)               // 400 KB more, but only 40 ms later
        #expect(accept(650_000, at: 200) == nil)              // enough bytes and time, but below the 700 KB seen
        #expect(accept(750_000, at: 300) == 750_000)
        #expect(accept(800_000, at: 500) == nil)              // 200 ms later, but only 50 KB more
        #expect(accept(1_900_000, at: 600) == 1_900_000)
        #expect(accept(2_000_000, at: 610) == 2_000_000)      // the final value: 10 ms and 100 KB after the last
        #expect(accept(2_000_000, at: 900) == nil)
        #expect(accept(1_500_000, at: 950) == nil)
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

/// Cancels the install of `pack`, calls `install` again and runs `then`, all in one turn of the actor: the cancelled
/// install needs the actor to end, so it is still settling throughout. Returns the new install.
private func retryWhileSettling(_ pack: PackID, on maqs: isolated Maqs,
                                then: @Sendable (isolated Maqs) async throws -> Void = { _ in }) async throws
    -> Task<Void, any Error> {
    maqs.cancelInstall(pack)
    let retry = try #require(try maqs.startInstall(pack))
    try await then(maqs)
    return retry
}
