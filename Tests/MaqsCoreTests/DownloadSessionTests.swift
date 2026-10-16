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
        DownloadSession(configuration: server.configuration, userAgent: "T Maqs/0", orphanDirectory: layout.downloadsDirectory)
    }

    func request(_ name: String) -> DownloadSession.Request {
        DownloadSession.Request(url: URL(string: "https://github.com/dl/\(name)")!, fileName: name,
                                destination: layout.downloadURL(fileName: name), resumeDataURL: layout.resumeDataURL(fileName: name))
    }

    func downloadExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: layout.downloadURL(fileName: name).path(percentEncoded: false))
    }

    @Test("a download lands at its destination, reports progress, and sends the User-Agent")
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
        #expect(try String(contentsOf: layout.downloadURL(fileName: "c.bin"), encoding: .utf8) == "new")
    }

    @Test("concurrent downloads on one session do not mix up their destinations")
    func concurrent() async throws {
        for i in 0..<5 { server.route(request("f\(i).bin").url, body: Data("file \(i)".utf8)) }
        let session = session()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<5 { group.addTask { try await session.download(self.request("f\(i).bin")) { _ in } } }
            try await group.waitForAll()
        }
        for i in 0..<5 {
            #expect(try String(contentsOf: layout.downloadURL(fileName: "f\(i).bin"), encoding: .utf8) == "file \(i)")
        }
    }

    @Test("cancelling a running download throws cancelled and leaves no destination file")
    func cancel() async throws {
        server.route(request("slow.bin").url) { _ in StubResponse(status: 200, body: Data(repeating: 2, count: 1_000), delay: 2) }
        let session = session()
        let task = Task { try await session.download(self.request("slow.bin")) { _ in } }
        try await Task.sleep(for: .milliseconds(200))
        session.cancel(url: request("slow.bin").url)
        do {
            try await task.value
            Issue.record("expected cancellation")
        } catch let error as TransferError {
            guard case .cancelled = error else { Issue.record("wrong error \(error)"); return }
        }
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
        await #expect(throws: TransferError.cancelled(resumeData: nil)) { try await task.value }
        #expect(!downloadExists("late.bin"))
    }

    @Test("a fresh task succeeds only on 200; a task resumed from resume data also on 206", arguments: [
        (200, false, true), (206, false, false), (200, true, true), (206, true, true),
        (204, false, false), (304, true, false), (404, true, false), (416, true, false), (0, false, false),
    ])
    func successStatus(status: Int, resumed: Bool, success: Bool) {
        #expect(DownloadSession.isSuccess(status: status, resumed: resumed) == success)
    }

    @Test("sha256 of a file matches CryptoKit over its bytes")
    func hash() throws {
        let url = layout.downloadURL(fileName: "h.bin")
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
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
