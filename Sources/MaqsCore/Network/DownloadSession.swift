import Foundation
import Synchronization

/// Delegate-driven `URLSession` download tasks with async callers, usable with a background configuration.
///
/// A request's `key` decides everything on disk: the file lands at `layout.downloadURL(fileName: key)`, resume data
/// is kept at `layout.resumeDataURL(fileName: key)`, and the task's `taskDescription` is the key, so a task that
/// finishes after a relaunch, when no caller is waiting, leaves its file or resume data where the next download of
/// that key looks. The installer's key names the bytes (`<sha256>-<file>`), so a leftover can only be the same bytes.
///
/// One task runs per key: a `download(_:progress:)` for a key whose task is running, started in this process or
/// restored after a relaunch, waits for that task, and every caller waiting on it gets the same outcome.
final class DownloadSession: NSObject, URLSessionDownloadDelegate, Sendable {
    /// One file to fetch.
    struct Request: Sendable {
        let url: URL
        let key: String

        /// `key` must be one path component (non-empty, no `/`, not `.` or `..`); anything else is a programming error.
        init(url: URL, key: String) {
            guard Self.validKey(key) != nil else {
                preconditionFailure("DownloadSession.Request key is not one path component")
            }
            self.url = url
            self.key = key
        }

        /// `candidate` when it can name a file directly under `downloads/`, nil otherwise.
        static func validKey(_ candidate: String?) -> String? {
            guard let candidate, !candidate.isEmpty, !candidate.contains("/"), candidate != ".", candidate != ".." else {
                return nil
            }
            return candidate
        }
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Void, any Error>
        let progress: @Sendable (Int64) -> Void
    }

    /// The running task for one key and every caller waiting for it.
    private struct Transfer {
        let task: URLSessionDownloadTask
        let url: URL
        /// Created from resume data, or restored after a relaunch (unknown), so a `206 Partial Content` is accepted.
        let resumed: Bool
        var waiters: [Waiter]
        var bytesWritten: Int64
    }

    private struct State {
        var transfers: [String: Transfer] = [:]
        /// Tasks whose file was moved into place; an entry lives until its task completes.
        var movedTaskIDs: Set<Int> = []
        /// Every task that completed in this process, so a caller never waits on a task an `allTasks` snapshot still
        /// listed but that will not call back again. One integer per task for the life of the process.
        var completedTaskIDs: Set<Int> = []

        func transfer(for task: URLSessionTask) -> Transfer? {
            guard let key = Request.validKey(task.taskDescription), let transfer = transfers[key],
                  transfer.task.taskIdentifier == task.taskIdentifier else { return nil }
            return transfer
        }
    }

    private struct BackgroundEvents {
        var handler: (@Sendable () -> Void)?
        /// The session delivered all its events before the app handed over its handler.
        var finishedWithoutHandler = false
    }

    private enum Registration {
        case started(URLSessionDownloadTask)
        case joined(URLSessionDownloadTask, bytesWritten: Int64)
    }

    private let state = Mutex(State())
    private let backgroundEvents = Mutex(BackgroundEvents())
    private let sessionBox = Mutex<URLSession?>(nil)
    private let userAgent: String
    private let layout: StorageLayout

    /// Builds the one session this object delegates for.
    ///
    /// `configuration` is a class and this init mutates the instance it is given: its `httpAdditionalHeaders` gain
    /// `User-Agent: userAgent`, which also reaches tasks resumed from resume data (they carry no request of ours).
    /// Pass a configuration nothing else uses.
    init(configuration: URLSessionConfiguration, userAgent: String, layout: StorageLayout) {
        self.userAgent = userAgent
        self.layout = layout
        super.init()
        configuration.httpAdditionalHeaders = (configuration.httpAdditionalHeaders ?? [:])
            .merging(["User-Agent": userAgent]) { _, new in new }
        // The delegate methods never read the session through this box, so events a background session delivers
        // before the next line runs are handled all the same.
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionBox.withLock { $0 = session }
    }

    /// The one `URLSession`; internal so tests can stand in for a task restored after a relaunch.
    var urlSession: URLSession {
        guard let session = sessionBox.withLock({ $0 }) else {
            // Set in init before any caller can reach this object; optional only because `self` is the delegate.
            preconditionFailure("DownloadSession used before its URLSession was created")
        }
        return session
    }

    /// Whether `status` means the file arrived: 200 for a fresh task, 200 or 206 for a task resumed from resume data
    /// (it asks for the rest of the file with a `Range` header; a server that ignores it sends the whole file with 200).
    static func isSuccess(status: Int, resumed: Bool) -> Bool {
        status == 200 || (resumed && status == 206)
    }

    /// Downloads `request.url` to `layout.downloadURL(fileName: request.key)`, replacing any file there; throws
    /// `TransferError`.
    ///
    /// Resumes from the key's resume data when it is usable. `progress` receives the bytes the current transfer has
    /// written; a caller that joins a running transfer gets one call at once with the bytes written so far. When the
    /// calling task is cancelled the transfer is cancelled, for every caller waiting on it.
    func download(_ request: Request, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let running = await urlSession.allTasks
            .compactMap { $0 as? URLSessionDownloadTask }
            .filter { $0.taskDescription == request.key }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let waiter = Waiter(continuation: continuation, progress: progress)
            let registration = state.withLock { state -> Registration in
                if let transfer = state.transfers[request.key] {
                    state.transfers[request.key]?.waiters.append(waiter)
                    return .joined(transfer.task, bytesWritten: transfer.bytesWritten)
                }
                let completed = state.completedTaskIDs
                if let restored = running.first(where: { $0.state != .completed && !completed.contains($0.taskIdentifier) }) {
                    let bytesWritten = restored.countOfBytesReceived
                    state.transfers[request.key] = Transfer(task: restored, url: request.url, resumed: true,
                                                            waiters: [waiter], bytesWritten: bytesWritten)
                    return .joined(restored, bytesWritten: bytesWritten)
                }
                let (task, resumed) = makeTask(for: request)
                state.transfers[request.key] = Transfer(task: task, url: request.url, resumed: resumed,
                                                        waiters: [waiter], bytesWritten: 0)
                return .started(task)
            }
            // Checked after registering, before the task runs: a cancellation handler that ran earlier found nothing
            // to cancel. Cancelling the task resumes this caller through didCompleteWithError, like any other.
            switch registration {
            case .joined(let task, let bytesWritten):
                progress(bytesWritten)
                if Task.isCancelled { cancelKeepingResumeData(task, key: request.key) }
            case .started(let task):
                if Task.isCancelled { cancelKeepingResumeData(task, key: request.key) } else { task.resume() }
            }
        }
    }

    /// Cancels the transfer for `url`, keeping resume data at its key's resume URL when the server allows it; every
    /// caller waiting on it gets `.cancelled`. Does nothing when no transfer for `url` is running.
    func cancel(url: URL) {
        let found = state.withLock { state in
            state.transfers.first { $0.value.url.absoluteString == url.absoluteString }.map { (task: $0.value.task, key: $0.key) }
        }
        guard let found else { return }
        cancelKeepingResumeData(found.task, key: found.key)
    }

    /// iOS: the app delegate's completion handler, run once on the main thread after the session has delivered all
    /// its events; at once when they were delivered before this call.
    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        let runNow = backgroundEvents.withLock { events in
            guard events.finishedWithoutHandler else {
                events.handler = handler
                return false
            }
            events.finishedWithoutHandler = false
            return true
        }
        if runNow { DispatchQueue.main.async { handler() } }   // UIKit requires the main thread
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let key = Request.validKey(downloadTask.taskDescription) else {
            logger.error("discarded a finished download with no usable key")
            return
        }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        // No transfer means a task restored after a relaunch that nobody has joined: whether it was resumed is
        // unknown, and the installer hashes the file anyway.
        let resumed = state.withLock { $0.transfer(for: downloadTask)?.resumed } ?? true
        // An error body is not the file; didCompleteWithError reports the status.
        guard Self.isSuccess(status: status, resumed: resumed) else { return }
        let destination = layout.downloadURL(fileName: key)
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            state.withLock { _ = $0.movedTaskIDs.insert(downloadTask.taskIdentifier) }
        } catch {
            logger.error("could not keep the download of \(key, privacy: .public)")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let callbacks = state.withLock { state -> [@Sendable (Int64) -> Void] in
            guard let transfer = state.transfer(for: downloadTask), let key = Request.validKey(downloadTask.taskDescription) else {
                return []
            }
            state.transfers[key]?.bytesWritten = totalBytesWritten
            return transfer.waiters.map(\.progress)
        }
        for callback in callbacks { callback(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let key = Request.validKey(task.taskDescription)
        let nsError = error.map { $0 as NSError }
        let resumeData = nsError?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        // One lock for all of it, so each waiter is resumed by exactly one call and the next download of this key
        // either runs before the resume data is written or sees all of it.
        let (transfer, moved) = state.withLock { state -> (Transfer?, Bool) in
            state.completedTaskIDs.insert(task.taskIdentifier)
            let moved = state.movedTaskIDs.remove(task.taskIdentifier) != nil
            guard let key else { return (nil, moved) }
            if let resumeData { Self.keepResumeData(resumeData, at: layout.resumeDataURL(fileName: key)) }
            guard state.transfer(for: task) != nil else { return (nil, moved) }
            return (state.transfers.removeValue(forKey: key), moved)
        }
        guard let transfer, let key else {
            // A task restored after a relaunch that nobody joined: its file was kept by didFinishDownloadingTo, its
            // resume data above, both where the next download of its key looks.
            if let nsError, let key {
                logger.error("download of \(key, privacy: .public) with no caller failed: \(nsError.domain, privacy: .public) \(nsError.code)")
            }
            return
        }
        let outcome: Result<Void, TransferError>
        if let nsError {
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                outcome = .failure(.cancelled(resumeData: resumeData))
            } else {
                logger.error("download of \(key, privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code)")
                outcome = .failure(.transport("\(nsError.domain) \(nsError.code)"))
            }
        } else {
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            if !Self.isSuccess(status: status, resumed: transfer.resumed) {
                outcome = .failure(.http(status))
            } else if !moved {
                outcome = .failure(.fileMove)
            } else {
                outcome = .success(())
            }
        }
        for waiter in transfer.waiters { waiter.continuation.resume(with: outcome) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Taken, not read: the system's handler must run exactly once.
        let handler = backgroundEvents.withLock { events -> (@Sendable () -> Void)? in
            guard let handler = events.handler.take() else {
                events.finishedWithoutHandler = true
                return nil
            }
            return handler
        }
        guard let handler else { return }
        DispatchQueue.main.async { handler() }   // UIKit requires the main thread
    }

    // MARK: Helpers

    /// A task for `request`, resuming from its key's resume data when that is usable, fresh otherwise. Runs under
    /// the state lock, so no resume data is written for this key meanwhile.
    ///
    /// The resume file is read and deleted before URLSession sees it: `downloadTask(withResumeData:)` raises an
    /// uncaught Objective-C exception on bytes it cannot parse (seen with non-plist bytes and with a wrongly typed
    /// value), so only a property-list dictionary is handed over, and a blob that still crashes it does so once,
    /// not on every launch.
    private func makeTask(for request: Request) -> (task: URLSessionDownloadTask, resumed: Bool) {
        let resumeURL = layout.resumeDataURL(fileName: request.key)
        let resumeData = try? Data(contentsOf: resumeURL)
        try? FileManager.default.removeItem(at: resumeURL)
        if let resumeData {
            if Self.isPropertyListDictionary(resumeData) {
                let task = urlSession.downloadTask(withResumeData: resumeData)
                if task.originalRequest?.url?.absoluteString == request.url.absoluteString {
                    task.taskDescription = request.key
                    return (task, true)
                }
                // Never started and has no key: it completes as cancelled and is ignored.
                task.cancel()
            }
            logger.error("discarded resume data of \(request.key, privacy: .public) that does not resume its URL")
        }
        var urlRequest = URLRequest(url: request.url, cachePolicy: .useProtocolCachePolicy)
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let task = urlSession.downloadTask(with: urlRequest)
        task.taskDescription = request.key
        return (task, false)
    }

    /// Cancels `task` by its object, keeping resume data only while the task is still registered: once it has
    /// completed, a newer download of the key may already have used and deleted the blob.
    private func cancelKeepingResumeData(_ task: URLSessionDownloadTask, key: String) {
        task.cancel { [self] data in
            guard let data else { return }
            state.withLock { state in
                guard state.transfer(for: task) != nil else { return }
                Self.keepResumeData(data, at: layout.resumeDataURL(fileName: key))
            }
        }
    }

    private static func isPropertyListDictionary(_ data: Data) -> Bool {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any]
    }

    private static func keepResumeData(_ data: Data, at url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("could not keep resume data \(url.lastPathComponent, privacy: .public)")
        }
    }
}
