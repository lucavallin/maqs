import Foundation
import Synchronization
import Testing
@testable import MaqsCore
import MaqsTestSupport

@Suite struct DownloadSessionTests {
    let server = StubServer()
    let tmp: TemporaryDirectory
    let layout: StorageLayout

    init() throws {
        tmp = try TemporaryDirectory()
        layout = StorageLayout(root: tmp.url)
        try FileManager.default.createDirectory(at: layout.downloadsDirectory, withIntermediateDirectories: true)
    }

    func session() -> DownloadSession {
        DownloadSession(configuration: server.configuration, userAgent: "T Maqs/0", layout: layout)
    }

    func request(_ key: String) -> DownloadSession.Request {
        DownloadSession.Request(url: URL(string: "https://github.com/dl/\(key)")!, key: key)
    }

    func downloadExists(_ key: String) -> Bool {
        FileManager.default.fileExists(atPath: layout.downloadURL(fileName: key).path(percentEncoded: false))
    }

    func downloaded(_ key: String) throws -> String {
        try String(contentsOf: layout.downloadURL(fileName: key), encoding: .utf8)
    }

    /// Routes `key` to a delayed response and returns a stream that yields each time a request for it reaches the stub.
    func routeDelayed(_ key: String, body: String, delay: TimeInterval) -> AsyncStream<Void> {
        let (reached, continuation) = AsyncStream<Void>.makeStream()
        server.route(request(key).url) { _ in
            continuation.yield()
            return StubResponse(status: 200, body: Data(body.utf8), delay: delay)
        }
        return reached
    }

    func expectCancelled(_ task: Task<Void, any Error>) async {
        let error = await #expect(throws: TransferError.self) { try await task.value }
        guard case .cancelled = error else {
            Issue.record("expected cancellation, got \(String(describing: error))")
            return
        }
    }

    // MARK: Transfers

    @Test("a download lands at its key's destination, reports progress, and sends the User-Agent")
    func success() async throws {
        let body = Data(repeating: 1, count: 50_000)
        server.route(request("a.bin").url, body: body)
        let received = Mutex<Int64>(0)
        try await session().download(request("a.bin")) { bytes in received.withLock { $0 = bytes } }
        #expect(try Data(contentsOf: layout.downloadURL(fileName: "a.bin")) == body)
        #expect(received.withLock { $0 } == 50_000)
        #expect(server.requests.first?.value(forHTTPHeaderField: "User-Agent") == "T Maqs/0")
        #expect(server.requests.first?.value(forHTTPHeaderField: "Cache-Control") == nil)
    }

    @Test("a 404 is an http error and leaves no file")
    func notFound() async throws {
        server.route(request("b.bin").url, status: 404, body: Data("nope".utf8))
        await #expect(throws: TransferError.http(404)) { try await session().download(request("b.bin")) { _ in } }
        #expect(!downloadExists("b.bin"))
    }

    @Test("a fresh task answered with 206 is an http error and leaves no file")
    func partialContentOnFreshTask() async throws {
        server.route(request("p.bin").url, status: 206, body: Data("part".utf8))
        await #expect(throws: TransferError.http(206)) { try await session().download(request("p.bin")) { _ in } }
        #expect(!downloadExists("p.bin"))
    }

    @Test("a transport failure is a transport error and leaves no file")
    func transportFailure() async throws {
        server.route(request("t.bin").url) { _ in StubResponse(transportError: .networkConnectionLost) }
        let error = await #expect(throws: TransferError.self) { try await session().download(request("t.bin")) { _ in } }
        guard case .transport = error else {
            Issue.record("expected a transport error, got \(String(describing: error))")
            return
        }
        #expect(!downloadExists("t.bin"))
    }

    @Test("a download replaces a stale file at the destination")
    func replaces() async throws {
        try Data("old".utf8).write(to: layout.downloadURL(fileName: "c.bin"))
        server.route(request("c.bin").url, body: Data("new".utf8))
        try await session().download(request("c.bin")) { _ in }
        #expect(try downloaded("c.bin") == "new")
    }

    @Test("concurrent downloads of different keys on one session do not mix up their destinations")
    func concurrent() async throws {
        for i in 0..<5 { server.route(request("f\(i).bin").url, body: Data("file \(i)".utf8)) }
        let session = session()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 { group.addTask { try await session.download(self.request("f\(i).bin")) { _ in } } }
            try await group.waitForAll()
        }
        for i in 0..<5 { #expect(try downloaded("f\(i).bin") == "file \(i)") }
    }

    @Test("unusable resume data is discarded and the download starts fresh", arguments: ["not a property list", "empty dictionary"])
    func unusableResumeData(kind: String) async throws {
        let blob = kind == "empty dictionary"
            ? try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
            : Data(kind.utf8)
        try blob.write(to: layout.resumeDataURL(fileName: "r.bin"))
        server.route(request("r.bin").url, body: Data("fresh".utf8))
        try await session().download(request("r.bin")) { _ in }
        #expect(try downloaded("r.bin") == "fresh")
        #expect(server.requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: layout.resumeDataURL(fileName: "r.bin").path(percentEncoded: false)))
    }

    // MARK: Cancellation

    @Test("cancelling a running download throws cancelled and leaves no destination file")
    func cancel() async throws {
        let reached = routeDelayed("slow.bin", body: "slow", delay: 5)
        let session = session()
        let task = Task { try await session.download(self.request("slow.bin")) { _ in } }
        var iterator = reached.makeAsyncIterator()
        _ = await iterator.next()
        session.cancel(url: request("slow.bin").url)
        await expectCancelled(task)
        #expect(!downloadExists("slow.bin"))
    }

    @Test("a download called from an already-cancelled task is cancelled instead of running to the end")
    func alreadyCancelled() async throws {
        server.route(request("late.bin").url) { _ in StubResponse(status: 200, body: Data("late".utf8), delay: 2) }
        let session = session()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await session.download(self.request("late.bin")) { _ in }
        }
        await expectCancelled(task)
        #expect(!downloadExists("late.bin"))
    }

    // MARK: One task per key

    @Test("two downloads of one key share one request and both complete")
    func sharedTransfer() async throws {
        let reached = routeDelayed("s.bin", body: "shared", delay: 2)
        let session = session()
        let first = Task { try await session.download(self.request("s.bin")) { _ in } }
        var reachedIterator = reached.makeAsyncIterator()
        _ = await reachedIterator.next()
        let (joined, joinedContinuation) = AsyncStream<Int64>.makeStream()
        let second = Task { try await session.download(self.request("s.bin")) { joinedContinuation.yield($0) } }
        var joinedIterator = joined.makeAsyncIterator()
        _ = await joinedIterator.next()
        try await first.value
        try await second.value
        #expect(server.requests.count == 1)
        #expect(try downloaded("s.bin") == "shared")
    }

    @Test("cancelling a shared transfer cancels every download waiting on it")
    func sharedCancel() async throws {
        let reached = routeDelayed("sc.bin", body: "shared", delay: 5)
        let session = session()
        let first = Task { try await session.download(self.request("sc.bin")) { _ in } }
        var reachedIterator = reached.makeAsyncIterator()
        _ = await reachedIterator.next()
        let (joined, joinedContinuation) = AsyncStream<Int64>.makeStream()
        let second = Task { try await session.download(self.request("sc.bin")) { joinedContinuation.yield($0) } }
        var joinedIterator = joined.makeAsyncIterator()
        _ = await joinedIterator.next()
        session.cancel(url: request("sc.bin").url)
        await expectCancelled(first)
        await expectCancelled(second)
        #expect(server.requests.count == 1)
        #expect(!downloadExists("sc.bin"))
    }

    @Test("a download joins a running task for its key that it did not start, as after a relaunch")
    func joinsRestoredTask() async throws {
        let reached = routeDelayed("o.bin", body: "restored", delay: 2)
        let session = session()
        let restored = session.urlSession.downloadTask(with: request("o.bin").url)
        restored.taskDescription = "o.bin"
        restored.resume()
        var reachedIterator = reached.makeAsyncIterator()
        _ = await reachedIterator.next()
        let progress = Mutex<[Int64]>([])
        try await session.download(request("o.bin")) { bytes in progress.withLock { $0.append(bytes) } }
        #expect(server.requests.count == 1)
        #expect(try downloaded("o.bin") == "restored")
        #expect(progress.withLock { $0.first } == 0)
    }

    @Test("a task with no caller that fails keeps its resume data under its key")
    func orphanFailureKeepsResumeData() throws {
        let session = session()
        let other = URLSession(configuration: .ephemeral)
        let orphan = other.downloadTask(with: request("lost.bin").url)
        orphan.taskDescription = "lost.bin"
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                            userInfo: [NSURLSessionDownloadTaskResumeData: Data("resume".utf8)])
        session.urlSession(other, task: orphan, didCompleteWithError: error)
        #expect(try Data(contentsOf: layout.resumeDataURL(fileName: "lost.bin")) == Data("resume".utf8))
        orphan.cancel()
    }

    // MARK: Background events

    @Test("a background handler set before the events finish runs once, on the main thread")
    func backgroundHandlerFirst() async {
        let session = session()
        let (calls, callsContinuation) = AsyncStream<Bool>.makeStream()
        session.setBackgroundCompletionHandler { callsContinuation.yield(Thread.isMainThread) }
        session.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        session.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        await MainActor.run {}
        callsContinuation.finish()
        var seen: [Bool] = []
        for await onMain in calls { seen.append(onMain) }
        #expect(seen == [true])
    }

    @Test("a background handler set after the events finished runs at once, and only that one")
    func backgroundEventsFirst() async {
        let session = session()
        let (calls, callsContinuation) = AsyncStream<String>.makeStream()
        session.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        session.setBackgroundCompletionHandler { callsContinuation.yield(Thread.isMainThread ? "first on main" : "first") }
        session.setBackgroundCompletionHandler { callsContinuation.yield("second") }
        await MainActor.run {}
        callsContinuation.finish()
        var seen: [String] = []
        for await call in calls { seen.append(call) }
        #expect(seen == ["first on main"])
    }

    // MARK: Rules

    @Test("a fresh task succeeds only on 200; a task resumed from resume data also on 206", arguments: [
        (200, false, true), (206, false, false), (200, true, true), (206, true, true),
        (204, false, false), (304, true, false), (404, true, false), (416, true, false), (0, false, false),
    ])
    func successStatus(status: Int, resumed: Bool, success: Bool) {
        #expect(DownloadSession.isSuccess(status: status, resumed: resumed) == success)
    }

    @Test("a key is one path component", arguments: [
        ("a.bin", true), ("0123abcd-veneto-trails.v1.sqlite", true), ("..a", true),
        ("", false), (".", false), ("..", false), ("a/b", false), ("/a", false), ("../a", false),
    ])
    func keyValidation(key: String, valid: Bool) {
        #expect((DownloadSession.Request.validKey(key) != nil) == valid)
    }

    @Test("a request with a key that is not one path component stops the program")
    func invalidKeyTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = DownloadSession.Request(url: URL(string: "https://github.com/dl/x")!, key: "../x")
        }
    }

    // MARK: Hash and progress

    @Test("sha256 of a file larger than one read chunk matches CryptoKit over its bytes")
    func hash() throws {
        let url = layout.downloadURL(fileName: "h.bin")
        let data = Data((0..<2_621_440).map { UInt8($0 % 251) })
        try data.write(to: url)
        #expect(try FileHash.sha256(of: url) == SHA256Hex.hex(of: data))
    }

    @Test("sha256 of an empty file is the digest of no bytes, and a missing file throws")
    func hashEdges() throws {
        let empty = layout.downloadURL(fileName: "empty.bin")
        try Data().write(to: empty)
        #expect(try FileHash.sha256(of: empty) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(throws: (any Error).self) { try FileHash.sha256(of: layout.downloadURL(fileName: "missing.bin")) }
    }

    @Test("progress fraction is 0 for an unknown total and stays within 0…1")
    func progressFraction() {
        #expect(DownloadProgress(bytesReceived: 10, totalBytes: 0).fraction == 0)
        #expect(DownloadProgress(bytesReceived: 25, totalBytes: 100).fraction == 0.25)
        #expect(DownloadProgress(bytesReceived: 150, totalBytes: 100).fraction == 1)
    }
}
