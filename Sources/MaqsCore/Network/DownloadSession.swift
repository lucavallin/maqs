import Foundation
import Synchronization

/// Why a single transfer did not complete.
enum TransferError: Error, Equatable {
    /// The server's status is not a success for this task (see `DownloadSession.isSuccess`); 0 when there was no HTTP response.
    case http(Int)
    /// The transfer failed below HTTP; the payload is the error's domain and code, never its description, which can carry the URL.
    case transport(String)
    /// Cancelled by us; resume data, when the server supports ranges, is also kept at the request's `resumeDataURL`.
    case cancelled(resumeData: Data?)
    /// The downloaded file could not be moved to its destination.
    case fileMove
}

/// Delegate-driven `URLSession` download tasks with async callers, usable with a background configuration.
///
/// Each task's `taskDescription` is its file name, so a task that completes after a relaunch (when no caller is
/// waiting) still lands under `orphanDirectory/<fileName>` and is picked up by the next install.
///
/// A task that fails or is cancelled with resume data leaves it at its request's `resumeDataURL`; the next
/// `download(_:progress:)` of that request resumes from it and deletes it, so resume data is used once.
final class DownloadSession: NSObject, URLSessionDownloadDelegate, Sendable {
    struct Request: Sendable {
        let url: URL
        let fileName: String
        let destination: URL
        let resumeDataURL: URL
    }

    private struct Pending {
        let continuation: CheckedContinuation<Void, any Error>
        let request: Request
        /// Created from resume data, so a `206 Partial Content` is the expected answer.
        let resumed: Bool
        let progress: @Sendable (Int64) -> Void
        var moved = false
    }

    private let pending = Mutex<[Int: Pending]>([:])
    private let tasksByURL = Mutex<[String: URLSessionDownloadTask]>([:])
    private let backgroundCompletion = Mutex<(@Sendable () -> Void)?>(nil)
    private let sessionBox = Mutex<URLSession?>(nil)
    private let userAgent: String
    private let orphanDirectory: URL

    /// Builds the one session this object delegates for.
    ///
    /// `configuration` is a class and this init mutates the instance it is given: its `httpAdditionalHeaders` gain
    /// `User-Agent: userAgent`, which also reaches tasks resumed from resume data (they carry no request of ours).
    /// Pass a configuration nothing else uses.
    init(configuration: URLSessionConfiguration, userAgent: String, orphanDirectory: URL) {
        self.userAgent = userAgent
        self.orphanDirectory = orphanDirectory
        super.init()
        configuration.httpAdditionalHeaders = (configuration.httpAdditionalHeaders ?? [:])
            .merging(["User-Agent": userAgent]) { _, new in new }
        // The delegate methods never read `session` through this box, so events a background session delivers
        // before the next line runs are handled all the same.
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        sessionBox.withLock { $0 = session }
    }

    private var session: URLSession {
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

    /// Downloads to `request.destination`, replacing any file there; throws `TransferError`.
    ///
    /// Resumes from `request.resumeDataURL` when a non-empty file is there. A caller whose task is already cancelled
    /// gets `.cancelled`: the transfer is cancelled as soon as it is registered.
    func download(_ request: Request, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let task: URLSessionDownloadTask
            let resumed: Bool
            if let resumeData = try? Data(contentsOf: request.resumeDataURL), !resumeData.isEmpty {
                task = session.downloadTask(withResumeData: resumeData)
                resumed = true
            } else {
                var urlRequest = URLRequest(url: request.url, cachePolicy: .useProtocolCachePolicy)
                urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                task = session.downloadTask(with: urlRequest)
                resumed = false
            }
            // Used once: if this task fails with resume data of its own, that is written afresh.
            try? FileManager.default.removeItem(at: request.resumeDataURL)
            task.taskDescription = request.fileName
            pending.withLock {
                $0[task.taskIdentifier] = Pending(continuation: continuation, request: request, resumed: resumed, progress: progress)
            }
            tasksByURL.withLock { $0[request.url.absoluteString] = task }
            task.resume()
            // A cancellation handler that ran before the task was registered found nothing to cancel.
            if Task.isCancelled { cancel(url: request.url) }
        }
    }

    /// Cancels the task for `url`, keeping resume data at its request's `resumeDataURL` when the server allows it.
    /// Does nothing when no task for `url` is running.
    func cancel(url: URL) {
        guard let task = tasksByURL.withLock({ $0[url.absoluteString] }) else { return }
        let resumeURL = pending.withLock { $0[task.taskIdentifier]?.request.resumeDataURL }
        task.cancel { data in
            if let data, let resumeURL { Self.keepResumeData(data, at: resumeURL) }
        }
    }

    /// iOS: the app delegate's completion handler, invoked once, on the main thread, after the session has delivered
    /// all its events.
    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        backgroundCompletion.withLock { $0 = handler }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let target = pending.withLock { $0[downloadTask.taskIdentifier].map { (destination: $0.request.destination, resumed: $0.resumed) } }
        let destination: URL
        if let target {
            // An error body is not the file; didCompleteWithError reports the status.
            guard Self.isSuccess(status: status, resumed: target.resumed) else { return }
            destination = target.destination
        } else {
            // An orphan from before a relaunch: whether it was resumed is unknown, and the installer hashes it anyway.
            guard Self.isSuccess(status: status, resumed: true) else { return }
            guard let name = Self.orphanFileName(downloadTask.taskDescription) else {
                logger.error("discarded a finished download with no usable file name")
                return
            }
            destination = orphanDirectory.appending(path: name)
        }
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            pending.withLock { $0[downloadTask.taskIdentifier]?.moved = true }
        } catch {
            logger.error("could not keep the download of \(destination.lastPathComponent, privacy: .public)")
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        pending.withLock { $0[downloadTask.taskIdentifier]?.progress }?(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Removed under the lock, so the continuation below is resumed by exactly one call.
        guard let entry = pending.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else {
            return   // an orphan from before a relaunch; didFinishDownloadingTo already kept its file
        }
        let key = entry.request.url.absoluteString
        tasksByURL.withLock { if $0[key]?.taskIdentifier == task.taskIdentifier { $0[key] = nil } }
        if let error {
            let nsError = error as NSError
            let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if let resumeData { Self.keepResumeData(resumeData, at: entry.request.resumeDataURL) }
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                entry.continuation.resume(throwing: TransferError.cancelled(resumeData: resumeData))
            } else {
                logger.error("download of \(entry.request.fileName, privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code)")
                entry.continuation.resume(throwing: TransferError.transport("\(nsError.domain) \(nsError.code)"))
            }
            return
        }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        guard Self.isSuccess(status: status, resumed: entry.resumed) else {
            entry.continuation.resume(throwing: TransferError.http(status))
            return
        }
        guard entry.moved else {
            entry.continuation.resume(throwing: TransferError.fileMove)
            return
        }
        entry.continuation.resume()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Taken, not read: the system's handler must run exactly once.
        guard let handler = backgroundCompletion.withLock({ $0.take() }) else { return }
        DispatchQueue.main.async { handler() }   // UIKit requires the main thread
    }

    // MARK: Helpers

    /// The file name an orphan task carries, when it is one plain path component; it was set from a validated
    /// manifest file name, so anything else is not ours to write.
    private static func orphanFileName(_ description: String?) -> String? {
        guard let name = description, !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return name
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
