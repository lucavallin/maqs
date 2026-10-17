import Foundation
import Synchronization
import Testing
@testable import MaqsCore
import MaqsTestSupport

@Suite struct InstallerTests {
    let server = StubServer()
    let tmp: TemporaryDirectory
    let store: PackStore
    let installer: Installer
    let manifest: Manifest
    let id = PackID.region("test")

    init() throws {
        tmp = try TemporaryDirectory()
        store = try PackStore(root: tmp.url)
        let session = DownloadSession(configuration: server.configuration, userAgent: "T Maqs/0", layout: store.layout)
        installer = Installer(store: store, session: session)
        manifest = try Manifest.decode(try Fixtures.manifestData(), manifestHost: "github.com")
        try Fixtures.serveRelease(on: server)
    }

    struct Observed {
        let progress: [DownloadProgress]
        let verifying: Int
    }

    func plan(_ layers: Set<Layer>, manifest: Manifest? = nil, existing: PackRecord? = nil) throws -> Installer.Plan {
        let manifest = manifest ?? self.manifest
        let selections = try #require(CatalogBuilder.selections(manifest: manifest, pack: id, layers: layers))
        return try Installer.plan(id: id, release: manifest.release, selections: selections, existing: existing)
    }

    @discardableResult
    func run(_ plan: Installer.Plan) async throws -> Observed {
        let progress = Mutex<[DownloadProgress]>([])
        let verifying = Mutex(0)
        try await installer.run(plan, progress: { p in progress.withLock { $0.append(p) } }, onVerifying: {
            verifying.withLock { $0 += 1 }
        })
        return Observed(progress: progress.withLock { $0 }, verifying: verifying.withLock { $0 })
    }

    func entries(_ layer: Layer) -> [ManifestEntry] { manifest.regions[0].entries(for: layer)! }
    func main(_ layer: Layer) -> ManifestEntry { entries(layer).first { $0.role == nil }! }
    func overlay(_ layer: Layer) -> ManifestEntry { entries(layer).first { $0.role == "overlay" }! }

    func key(_ entry: ManifestEntry) -> String { "\(entry.sha256)-\(entry.file)" }
    func downloadURL(_ entry: ManifestEntry) -> URL { store.layout.downloadURL(fileName: key(entry)) }
    func installedURL(_ layer: Layer, _ entry: ManifestEntry) -> URL {
        store.layout.fileURL(id, layer: layer, sha256: entry.sha256, fileName: entry.file)
    }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
    func fixture(_ entry: ManifestEntry) throws -> Data { try Data(contentsOf: try Fixtures.url("test/\(entry.file)")) }

    /// Every file and directory under `directory`, as paths relative to it, sorted.
    func paths(under directory: URL) -> [String] {
        (FileManager.default.enumerator(atPath: directory.path(percentEncoded: false))?.allObjects as? [String] ?? []).sorted()
    }

    /// A first install that failed must leave no record and no pack directory.
    func expectNothingInstalled() throws {
        #expect(try store.record(for: id) == nil)
        #expect(!exists(store.layout.packDirectory(id)))
    }

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

    // MARK: Install

    @Test("every file of the chosen entries is installed under its SHA-256, the record is written, downloads are cleared")
    func installs() async throws {
        let plan = try plan([.trails, .places])
        #expect(plan.jobs.count == 4)
        let observed = try await run(plan)
        for job in plan.jobs {
            #expect(try FileHash.sha256(of: installedURL(job.layer, job.entry)) == job.entry.sha256)
            #expect(!exists(downloadURL(job.entry)))
        }
        #expect(try store.record(for: id) == plan.record)
        #expect(Set(plan.record.files.keys) == [.trails, .places])
        #expect(observed.progress.last == DownloadProgress(bytesReceived: plan.totalBytes, totalBytes: plan.totalBytes))
        #expect(observed.verifying == 1)
    }

    @Test("at most two downloads run at once")
    func boundedConcurrency() async throws {
        let plan = try plan([.trails, .places])
        #expect(plan.jobs.count == 4)
        let arrivals = Mutex<[Int: ContinuousClock.Instant]>([:])
        for (index, job) in plan.jobs.enumerated() {
            let body = try fixture(job.entry)
            // The first two answer after half a second; a third download that does not wait for one of them
            // reaches the stub before either has answered.
            let delay: TimeInterval = index < 2 ? 0.5 : 0
            server.route(job.entry.url) { _ in
                arrivals.withLock { $0[index] = .now }
                return StubResponse(status: 200, body: body, delay: delay)
            }
        }
        try await run(plan)
        let seen = arrivals.withLock { $0 }
        let first = min(try #require(seen[0]), try #require(seen[1]))
        for index in 2..<4 {
            let arrival = try #require(seen[index])
            #expect(first.duration(to: arrival) >= .milliseconds(450))
        }
    }

    // MARK: Verification

    @Test("a checksum mismatch installs nothing and discards the download")
    func checksum() async throws {
        let bad = main(.trails)
        server.route(bad.url, body: Data(repeating: 0, count: Int(bad.bytes)))
        let plan = try plan([.trails])
        await #expect(throws: DownloadError.checksumMismatch(file: bad.file)) { try await run(plan) }
        try expectNothingInstalled()
        #expect(!exists(downloadURL(bad)))
    }

    @Test("a size mismatch is reported before the hash, installs nothing and discards the download")
    func size() async throws {
        let bad = main(.trails)
        server.route(bad.url, body: Data("tampered".utf8))
        let plan = try plan([.trails])
        await #expect(throws: DownloadError.sizeMismatch(file: bad.file)) { try await run(plan) }
        try expectNothingInstalled()
        #expect(!exists(downloadURL(bad)))
    }

    @Test("a file whose hash matches but whose size differs from the manifest is refused")
    func listedSize() async throws {
        let data = try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            var layers = regions[0]["layers"] as! [String: [[String: Any]]]
            layers["places"]![0]["bytes"] = (layers["places"]![0]["bytes"] as! Int) + 1
            regions[0]["layers"] = layers
            object["regions"] = regions
        }
        let altered = try Manifest.decode(data, manifestHost: "github.com")
        let plan = try plan([.places], manifest: altered)
        let file = altered.regions[0].entries(for: .places)![0].file
        await #expect(throws: DownloadError.sizeMismatch(file: file)) { try await run(plan) }
        try expectNothingInstalled()
    }

    // MARK: Transfer failures

    @Test("a 404 is a network error with the status and cancels the other running download")
    func notFound() async throws {
        _ = routeSlow(main(.places), delay: 30)
        server.route(overlay(.places).url, status: 404, body: Data())
        await #expect(throws: DownloadError.network(statusCode: 404)) { try await run(try plan([.places])) }
        try expectNothingInstalled()
        // Not cancelled, the slow download would finish after 30 s and leave its file here.
        #expect(!exists(downloadURL(main(.places))))
    }

    @Test("a transport failure is a network error without a status")
    func transport() async throws {
        server.route(overlay(.places).url) { _ in StubResponse(transportError: .networkConnectionLost) }
        await #expect(throws: DownloadError.network(statusCode: nil)) { try await run(try plan([.places])) }
        try expectNothingInstalled()
    }

    // MARK: Leftovers

    @Test("a corrupt leftover download of the right size is replaced")
    func corruptLeftover() async throws {
        let entry = main(.trails)
        try Data(repeating: 0, count: Int(entry.bytes)).write(to: downloadURL(entry))
        try await run(try plan([.trails]))
        #expect(try FileHash.sha256(of: installedURL(.trails, entry)) == entry.sha256)
        #expect(server.requests.contains { $0.url == entry.url })
    }

    @Test("a valid leftover download is reused without a request")
    func validLeftover() async throws {
        for entry in entries(.trails) {
            try FileManager.default.copyItem(at: try Fixtures.url("test/\(entry.file)"), to: downloadURL(entry))
            server.route(entry.url, status: 500, body: Data())
        }
        try await run(try plan([.trails]))
        #expect(try store.record(for: id)?.files[.trails]?.count == 2)
        for entry in entries(.trails) {
            #expect(try FileHash.sha256(of: installedURL(.trails, entry)) == entry.sha256)
        }
        #expect(!server.requests.contains { $0.url?.lastPathComponent.hasPrefix("test-trails") == true })
    }

    // MARK: Updates

    @Test("an update downloads only the changed layer, puts it beside the old file, and sweeps the old file")
    func update() async throws {
        try await run(try plan([.places]))
        var existing = try #require(try store.record(for: id))
        let oldSHA = String(repeating: "0", count: 64)
        let name = main(.trails).file   // same file name, other bytes: the new file must not overwrite the old one
        existing.files[.trails] = [RecordFile(fileName: name, role: nil, schemaVersion: 1, sha256: oldSHA, bytes: 3,
                                              dataDate: Date(timeIntervalSince1970: 0))]
        try store.write(existing)
        let oldURL = store.layout.fileURL(id, layer: .trails, sha256: oldSHA, fileName: name)
        try FileManager.default.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: oldURL)
        let requestsBefore = server.requests.count

        let plan = try plan([.trails, .places], existing: existing)
        #expect(plan.jobs.map(\.layer) == [.trails, .trails])
        try await run(plan)
        #expect(try store.record(for: id) == plan.record)
        #expect(!exists(oldURL))
        for job in plan.jobs {
            #expect(try FileHash.sha256(of: installedURL(job.layer, job.entry)) == job.entry.sha256)
        }
        #expect(server.requests.count - requestsBefore == 2)
    }

    @Test("an update whose second file fails its hash leaves the old record and files untouched and adds no directory")
    func updateFailsOnSecondFile() async throws {
        try await run(try plan([.places]))
        var existing = try #require(try store.record(for: id))
        let oldSHA = String(repeating: "0", count: 64)
        let name = main(.trails).file
        existing.files[.trails] = [RecordFile(fileName: name, role: nil, schemaVersion: 1, sha256: oldSHA, bytes: 3,
                                              dataDate: Date(timeIntervalSince1970: 0))]
        try store.write(existing)
        let oldURL = store.layout.fileURL(id, layer: .trails, sha256: oldSHA, fileName: name)
        try FileManager.default.createDirectory(at: oldURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: oldURL)
        let before = paths(under: store.layout.packDirectory(id))

        let bad = overlay(.trails)
        server.route(bad.url, body: Data(repeating: 0, count: Int(bad.bytes)))
        let plan = try plan([.trails, .places], existing: existing)
        #expect(plan.jobs.map(\.entry) == [main(.trails), bad])
        await #expect(throws: DownloadError.checksumMismatch(file: bad.file)) { try await run(plan) }
        #expect(try store.record(for: id) == existing)
        #expect(paths(under: store.layout.packDirectory(id)) == before)
        #expect(try String(contentsOf: oldURL, encoding: .utf8) == "old")
        for file in try #require(existing.files[.places]) {
            let url = store.layout.fileURL(id, layer: .places, sha256: file.sha256, fileName: file.fileName)
            #expect(try FileHash.sha256(of: url) == file.sha256)
        }
    }

    @Test("an update that keeps a layer unchanged leaves that layer's files in place and named by the record")
    func keepsUnchangedLayer() async throws {
        try await run(try plan([.places]))
        let installed = try #require(try store.record(for: id))
        let kept = try #require(installed.files[.places])
        let requestsBefore = server.requests.count

        let plan = try plan([.places, .trails], existing: installed)
        #expect(plan.jobs.allSatisfy { $0.layer == .trails })
        try await run(plan)
        #expect(try store.record(for: id)?.files[.places] == kept)
        for file in kept {
            let url = store.layout.fileURL(id, layer: .places, sha256: file.sha256, fileName: file.fileName)
            #expect(try FileHash.sha256(of: url) == file.sha256)
        }
        #expect(!server.requests.dropFirst(requestsBefore).contains { $0.url?.lastPathComponent.hasPrefix("test-places") == true })
    }

    // MARK: Refusals and cancellation

    @Test("an unreadable layer refuses before any request")
    func unreadable() throws {
        let data = try Fixtures.manifestJSON { object in
            var regions = object["regions"] as! [[String: Any]]
            var layers = regions[0]["layers"] as! [String: [[String: Any]]]
            layers["curvature"] = layers["curvature"]!.map { var e = $0; e["layer_schema_version"] = 9; return e }
            regions[0]["layers"] = layers
            object["regions"] = regions
        }
        let altered = try Manifest.decode(data, manifestHost: "github.com")
        #expect(throws: DownloadError.layerUnreadable(.curvature)) { _ = try plan([.curvature, .trails], manifest: altered) }
        #expect(server.requests.isEmpty)
    }

    @Test("cancelling the install cancels every running download and leaves no record, no pack file and no download")
    func cancel() async throws {
        let plan = try plan([.trails])
        let streams = plan.jobs.map { routeSlow($0.entry, delay: 30) }
        let task = Task { try await run(plan) }
        for stream in streams {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        task.cancel()
        await #expect(throws: DownloadError.cancelled) { _ = try await task.value }
        try expectNothingInstalled()
        // Not cancelled, a download would finish after 30 s and leave its file here.
        for job in plan.jobs { #expect(!exists(downloadURL(job.entry))) }
    }
}
