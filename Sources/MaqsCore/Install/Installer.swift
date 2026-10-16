import Foundation
import Synchronization

/// Installs one pack: downloads every file of the chosen entries (at most two at once), verifies size and SHA-256,
/// moves the files into place, writes `pack.json` last, then sweeps the files the record no longer names.
///
/// What a crash leaves at each step: while downloading or verifying, only `downloads/` changes, and a completed file
/// there is reused after a hash check. Files are moved to `packs/<pack>/<layer>/<sha256>/<file>`, never over a file
/// the live `pack.json` names with other bytes, so until `pack.json` is replaced the old pack is whole and the moved
/// files are orphans the launch sweep removes. After `pack.json` is replaced, the new pack is whole and the old files
/// are orphans.
struct Installer: Sendable {
    /// One file to fetch for one layer.
    struct FileJob: Sendable, Equatable {
        let layer: Layer
        let entry: ManifestEntry

        /// The `DownloadSession` key: it names the bytes, so a file left in `downloads/` can only be this one.
        var key: String { "\(entry.sha256)-\(entry.file)" }
    }

    /// What one install downloads and the record it writes.
    struct Plan: Sendable {
        let id: PackID
        let release: String
        /// Files to download; layers already installed with the same SHA-256s are not in it.
        let jobs: [FileJob]
        /// The record to write when every job has been verified and moved: the existing record's layers, with the
        /// layers being installed replaced.
        let record: PackRecord
        /// Bytes to download, as the manifest lists them.
        var totalBytes: Int64 { jobs.reduce(0) { $0 + $1.entry.bytes } }
    }

    /// Most downloads one install runs at once.
    static let concurrency = 2

    let store: PackStore
    let session: DownloadSession

    /// Decides what to download. Throws `layerUnreadable` before any request when a configured layer offers no
    /// version this package reads.
    static func plan(id: PackID, release: String, selections: [Layer: ReadableVersions.Selection],
                     existing: PackRecord?) throws -> Plan {
        var jobs: [FileJob] = []
        // Starts from every installed layer: a layer left out here would be deleted by the sweep after the install.
        var files = existing?.files ?? [:]
        for (layer, selection) in selections.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            switch selection {
            case .unreadable:
                throw DownloadError.layerUnreadable(layer)
            case .readable(let version, let entries):
                if let installed = existing?.files[layer], Set(installed.map(\.sha256)) == Set(entries.map(\.sha256)) {
                    continue
                }
                jobs += entries.map { FileJob(layer: layer, entry: $0) }
                files[layer] = entries.map {
                    RecordFile(fileName: $0.file, role: $0.role, schemaVersion: version, sha256: $0.sha256,
                               bytes: $0.bytes, dataDate: $0.dataDate)
                }
            }
        }
        return Plan(id: id, release: release, jobs: jobs, record: PackRecord(id: id, release: release, files: files))
    }

    /// Runs `plan`. Throws `DownloadError` for a transfer, size, checksum or cancellation failure and `StorageError`
    /// when a file cannot be moved or the record written; in every case the installed pack is the one before the call.
    ///
    /// `progress` gets the bytes received over every file, from several threads, and once more with the final count
    /// when every download has finished.
    /// `onVerifying` is called once, when every download has finished and hashing starts.
    func run(_ plan: Plan, progress: @escaping @Sendable (DownloadProgress) -> Void,
             onVerifying: @escaping @Sendable () -> Void) async throws {
        let total = plan.totalBytes
        let received = Mutex<[String: Int64]>([:])
        let report: @Sendable (String, Int64) -> Void = { key, bytes in
            let sum = received.withLock { received in
                received[key] = bytes
                return received.values.reduce(0, +)
            }
            progress(DownloadProgress(bytesReceived: sum, totalBytes: total))
        }
        // When a download throws, leaving the group cancels the others, and each cancels its transfer.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = plan.jobs[...]
            var running = 0
            while running > 0 || !pending.isEmpty {
                while running < Self.concurrency, let job = pending.popFirst() {
                    group.addTask { try await fetch(job) { report(job.key, $0) } }
                    running += 1
                }
                _ = try await group.next()
                running -= 1
            }
        }
        // Every transfer has completed, so no callback can follow this one.
        progress(DownloadProgress(bytesReceived: received.withLock { $0.values.reduce(0, +) }, totalBytes: total))

        onVerifying()
        for job in plan.jobs {
            if Task.isCancelled { throw DownloadError.cancelled }
            try verify(job)
        }
        do {
            for job in plan.jobs {
                try store.moveIntoPlace(from: store.layout.downloadURL(fileName: job.key),
                                        to: store.layout.fileURL(plan.id, layer: job.layer, sha256: job.entry.sha256,
                                                                 fileName: job.entry.file))
            }
            try store.write(plan.record)
        } catch {
            // The record is unchanged and names none of the files moved so far; the sweep removes them, and the
            // whole directory when this was the first install.
            store.sweep(plan.id)
            throw error
        }
        store.sweep(plan.id)
        logger.info("installed \(plan.id.directoryName, privacy: .public): \(plan.jobs.count) files, \(total) bytes")
    }

    /// Reuses a completed file in `downloads/` when its size and hash match; otherwise downloads it, resuming when
    /// the session kept resume data.
    private func fetch(_ job: FileJob, progress: @escaping @Sendable (Int64) -> Void) async throws {
        if Task.isCancelled { throw DownloadError.cancelled }
        let destination = store.layout.downloadURL(fileName: job.key)
        if reuseLeftover(job, at: destination) {
            progress(job.entry.bytes)
            return
        }
        let request = DownloadSession.Request(url: job.entry.url, key: job.key)
        do {
            // The session checks for cancellation once the transfer is registered, so a cancellation that arrives
            // before then, when this handler finds nothing to cancel, still stops it.
            try await withTaskCancellationHandler {
                try await session.download(request, progress: progress)
            } onCancel: { [session] in
                session.cancel(url: job.entry.url)
            }
        } catch let error as TransferError {
            throw Self.downloadError(error, file: job.entry.file)
        } catch is CancellationError {
            throw DownloadError.cancelled
        }
    }

    /// Whether a file already at `url` is the job's bytes. One that is not is deleted, so a failed download leaves
    /// nothing to hash again next time.
    private func reuseLeftover(_ job: FileJob, at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return false }
        if Self.size(of: url) == job.entry.bytes, (try? FileHash.sha256(of: url)) == job.entry.sha256 {
            logger.info("reusing the download of \(job.entry.file, privacy: .public)")
            return true
        }
        discard(url, file: job.entry.file)
        return false
    }

    /// Size first, so a short or long file is never hashed; a file that cannot be read counts as a mismatch.
    private func verify(_ job: FileJob) throws {
        let url = store.layout.downloadURL(fileName: job.key)
        guard Self.size(of: url) == job.entry.bytes else {
            logger.error("size mismatch: \(job.entry.file, privacy: .public)")
            discard(url, file: job.entry.file)
            throw DownloadError.sizeMismatch(file: job.entry.file)
        }
        guard (try? FileHash.sha256(of: url)) == job.entry.sha256 else {
            logger.error("checksum mismatch: \(job.entry.file, privacy: .public)")
            discard(url, file: job.entry.file)
            throw DownloadError.checksumMismatch(file: job.entry.file)
        }
    }

    /// Deletes a download that is not the expected file. A failure is only logged: the next download of the key
    /// replaces the file, and verification refuses it meanwhile.
    private func discard(_ url: URL, file: String) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.error("could not delete the download of \(file, privacy: .public)")
        }
    }

    private static func size(of url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    /// The error the caller sees for a failed transfer. A status of 0 means no HTTP response, so no status.
    private static func downloadError(_ error: TransferError, file: String) -> DownloadError {
        switch error {
        case .cancelled:
            return .cancelled
        case .http(let status):
            logger.error("download of \(file, privacy: .public) failed: HTTP \(status)")
            return .network(statusCode: status == 0 ? nil : status)
        case .transport, .fileMove:
            logger.error("download of \(file, privacy: .public) failed")
            return .network(statusCode: nil)
        }
    }
}
