import Foundation

/// The entry point of `MaqsCore`: region discovery, downloads, installed packs, and the online sources.
///
/// Create one instance per app with a ``MaqsConfiguration``, read ``state`` from SwiftUI, call
/// ``refreshCatalog(policy:)`` to learn what the latest data release offers, and ``install(_:)`` to download a pack.
/// `MaqsTerrain` and `MaqsData` open the files that ``installedPack(_:)`` returns.
///
/// Installs run one at a time, in call order. A pack waiting for its turn already shows
/// ``PackState/downloading(_:)`` with no bytes received, so the app can offer to cancel it.
public actor Maqs {
    /// The configuration this instance was created with.
    public nonisolated let configuration: MaqsConfiguration
    /// Observable state for SwiftUI.
    @MainActor public let state: MaqsState

    private let store: PackStore
    private let manifestClient: ManifestClient
    private let sourcesClient: SourcesClient
    private nonisolated let downloadSession: DownloadSession
    private let installer: Installer
    /// The manifest behind the catalog, and when it was fetched.
    private var manifest: (manifest: Manifest, fetchedAt: Date)?
    /// Base packs the app registered from its own bundle in this process.
    private var bundled: [PackID: InstalledPack] = [:]
    /// The install of every pack that is queued or running; a second ``install(_:)`` of the pack joins it.
    private var installs: [PackID: Task<Void, any Error>] = [:]
    /// Installs in call order: the first one runs, the others wait for their turn.
    private var line: [QueuedInstall] = []
    private var nextTicket = 0

    private struct QueuedInstall {
        let ticket: Int
        /// Set while the install waits; resumed when it reaches the front of the line.
        var turn: CheckedContinuation<Void, any Error>?
    }

    private enum InstallEvent: Sendable {
        case progress(DownloadProgress)
        case verifying
    }

    /// Creates the storage root (excluded from backup), sweeps files no record names, and restores the installed
    /// packs and the catalog of the cached manifest. No request is made.
    ///
    /// - Throws: ``MaqsError/storage(_:)`` when the storage root cannot be created.
    @MainActor public init(configuration: MaqsConfiguration) throws {
        let store: PackStore
        do {
            store = try PackStore(root: configuration.storageDirectory ?? StorageLayout.defaultRoot())
        } catch let error as StorageError {
            throw MaqsError.storage(error)
        }
        let http = HTTPClient(session: URLSession(configuration: Self.copy(configuration.urlSessionConfiguration)),
                              userAgent: configuration.fullUserAgent)
        let manifestClient = ManifestClient(http: http, cache: store.layout.manifest, url: configuration.manifestURL,
                                            maxAge: configuration.catalogMaxAge, now: configuration.now)
        let downloadConfiguration: URLSessionConfiguration
        if let identifier = configuration.backgroundSessionIdentifier {
            downloadConfiguration = .background(withIdentifier: identifier)
            downloadConfiguration.sessionSendsLaunchEvents = true
            downloadConfiguration.isDiscretionary = false
        } else {
            downloadConfiguration = Self.copy(configuration.urlSessionConfiguration)
        }
        let downloadSession = DownloadSession(configuration: downloadConfiguration, userAgent: configuration.fullUserAgent,
                                              layout: store.layout)
        // The only all-packs sweep: nothing installs yet, so it cannot race an install.
        store.sweep()
        let installed = store.records().mapValues { store.installedPack(from: $0) }
        let cached = manifestClient.cached()
        let state = MaqsState()
        state.packs = installed.mapValues { .installed($0) }
        if let cached {
            state.catalog = CatalogBuilder.build(manifest: cached.manifest, fetchedAt: cached.fetchedAt,
                                                 layers: configuration.layers, installed: installed)
        }

        self.configuration = configuration
        self.store = store
        self.manifestClient = manifestClient
        sourcesClient = SourcesClient(http: http, cache: store.layout.sources, url: configuration.sourcesURL,
                                      bundled: SourcesClient.bundledURL, maxAge: configuration.catalogMaxAge,
                                      now: configuration.now)
        self.downloadSession = downloadSession
        installer = Installer(store: store, session: downloadSession)
        manifest = cached
        self.state = state
    }

    // MARK: Discovery

    /// Loads the latest manifest (per `policy`) and publishes its catalog in ``MaqsState/catalog``.
    ///
    /// After a successful refresh, and only while no install is queued or running, downloads that no entry of the
    /// manifest names are deleted with their resume data.
    ///
    /// - Throws: ``MaqsError/manifest(_:)`` when the manifest cannot be fetched or is rejected, and
    ///   ``MaqsError/storage(_:)`` when it cannot be cached. The previous catalog stays, and the error is also set in
    ///   ``MaqsState/lastRefreshError``. A cancelled call throws `CancellationError` and changes nothing.
    @discardableResult
    public func refreshCatalog(policy: RefreshPolicy = .ifStale) async throws -> Catalog {
        let loaded: (manifest: Manifest, fetchedAt: Date)
        do {
            loaded = try await manifestClient.load(policy: policy)
        } catch let error as CancellationError {
            throw error
        } catch {
            let failure = Self.typed(error, fallback: .manifest(.network(statusCode: nil)))
            await publish { $0.lastRefreshError = failure }
            throw failure
        }
        manifest = loaded
        pruneDownloads(keeping: loaded.manifest)
        let catalog = catalog(from: loaded)
        await publish {
            $0.catalog = catalog
            $0.lastRefreshError = nil
        }
        return catalog
    }

    // MARK: Packs

    /// Downloads and installs every configured layer of `pack` that is missing or changed, then publishes
    /// ``PackState/installed(_:)`` and the updated catalog.
    ///
    /// Installs run one at a time, in call order. A second call for a pack that is already queued or running joins
    /// that install: both return or throw together. Cancelling the calling task does not stop the install; call
    /// ``cancelInstall(_:)``.
    ///
    /// After an update the previous files of the changed layers are removed, so a URL from an earlier
    /// ``InstalledPack`` that was not opened yet may no longer exist: read ``installedPack(_:)`` again after this
    /// returns. A file that is already open stays readable until it is closed.
    ///
    /// - Throws: ``MaqsError/download(_:)``: `noCatalog` before any catalog is loaded; `notInCatalog` when the catalog
    ///   does not list the pack or the pack offers none of the configured layers (nothing is written, the state is
    ///   unchanged); `layerUnreadable`; a size, checksum or network failure (the pack becomes ``PackState/failed(_:)``);
    ///   `cancelled` after ``cancelInstall(_:)`` (the pack returns to installed if it was, else not installed).
    ///   ``MaqsError/storage(_:)`` when the files cannot be moved into place. Whatever was installed before stays.
    public func install(_ pack: PackID) async throws {
        if let running = installs[pack] {
            try await running.value
            return
        }
        let queuedBytes = try makePlan(pack).totalBytes
        let ticket = nextTicket
        nextTicket += 1
        line.append(QueuedInstall(ticket: ticket))
        let task = Task { try await self.runInstall(pack, ticket: ticket, queuedBytes: queuedBytes) }
        installs[pack] = task
        try await task.value
    }

    /// Cancels the install of `pack`, queued or running; its ``install(_:)`` throws `cancelled`. Resume data is kept
    /// where the server allows it, so the next install continues where this one stopped. Does nothing when no
    /// install of `pack` is queued or running.
    public func cancelInstall(_ pack: PackID) {
        installs[pack]?.cancel()
    }

    /// Deletes a downloaded pack, or unregisters a bundled one without touching the app's file. An install of the
    /// pack that is queued or running is cancelled first.
    ///
    /// - Throws: ``MaqsError/storage(_:)`` when the files cannot be deleted; the state shows what is left.
    public func remove(_ pack: PackID) async throws {
        // Wait for the cancelled install to stop, so it cannot write `pack.json` after the files are gone.
        while let running = installs[pack] {
            running.cancel()
            _ = try? await running.value
        }
        var failure: MaqsError?
        if bundled.removeValue(forKey: pack) == nil {
            do {
                try store.removePack(pack)
            } catch {
                failure = Self.typed(error, fallback: .storage(.writeFailed(pack.directoryName)))
            }
        }
        let settled = settledState(pack)
        let catalog = buildCatalog()
        await publish {
            $0.packs[pack] = settled
            $0.catalog = catalog
        }
        if let failure { throw failure }
    }

    /// Registers a base pack the app ships in its own bundle (ADR 0007): it counts as installed, is never
    /// downloaded, and is never reported as having an update. The file is recorded as `layer_schema_version` 1 with
    /// no SHA-256. Not persisted: call it on every launch.
    ///
    /// - Throws: ``MaqsError/storage(_:)`` with ``StorageError/fileNotFound(_:)`` when `url` is not a regular file.
    public func registerBundledBasePack(id: String, basemap url: URL) async throws {
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize
        else { throw MaqsError.storage(.fileNotFound(url.lastPathComponent)) }
        let pack = PackID.base(id)
        let file = InstalledFile(url: url, role: nil, schemaVersion: 1, sha256: nil, bytes: Int64(size), dataDate: nil)
        let installed = InstalledPack(id: pack, release: "bundled", files: [.basemap: [file]], bundled: true)
        bundled[pack] = installed
        let catalog = buildCatalog()
        await publish {
            $0.packs[pack] = .installed(installed)
            $0.catalog = catalog
        }
        logger.info("registered bundled base pack \(pack.directoryName, privacy: .public)")
    }

    /// The installed files of a pack, or `nil` when it is not installed or its record is unreadable.
    ///
    /// An update removes the files it replaces: read this again after ``install(_:)`` returns rather than keeping
    /// URLs from an earlier result that were not opened yet.
    public func installedPack(_ pack: PackID) -> InstalledPack? {
        if let bundled = bundled[pack] { return bundled }
        do {
            guard let record = try store.record(for: pack) else { return nil }
            return store.installedPack(from: record)
        } catch {
            logger.error("pack record unreadable: \(pack.directoryName, privacy: .public)")
            return nil
        }
    }

    /// Bytes on disk: installed files per downloaded pack, and pending downloads with their resume data.
    public func diskUsage() -> DiskUsage {
        let byPack = store.records().mapValues { store.installedPack(from: $0).bytes }
        let pending = (try? FileManager.default.contentsOfDirectory(at: store.layout.downloadsDirectory,
                                                                     includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let pendingBytes = pending.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return DiskUsage(bytesByPack: byPack, downloadsBytes: pendingBytes)
    }

    // MARK: Online sources

    /// The online providers: the cached `sources.json`, else the copy bundled with the package. `nil` when
    /// ``MaqsConfiguration/onlineTiles`` is `false`, or when no readable copy exists.
    public var onlineSources: OnlineSources? {
        configuration.onlineTiles ? sourcesClient.current() : nil
    }

    /// Refreshes `sources.json` from `main` (per `policy`) and returns the providers. Returns `nil` without any
    /// request when ``MaqsConfiguration/onlineTiles`` is `false`.
    ///
    /// - Throws: ``MaqsError/sources(_:)`` when the file cannot be fetched or is rejected, and ``MaqsError/storage(_:)``
    ///   when it cannot be cached; the last good copy stays in use. A cancelled call throws `CancellationError`.
    @discardableResult
    public func refreshOnlineSources(policy: RefreshPolicy = .ifStale) async throws -> OnlineSources? {
        guard configuration.onlineTiles else { return nil }
        do {
            return try await sourcesClient.refresh(policy: policy)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.typed(error, fallback: .sources(.network(statusCode: nil)))
        }
    }

    #if os(iOS)
    /// Forward `application(_:handleEventsForBackgroundURLSession:completionHandler:)` here. When `identifier` is
    /// ``MaqsConfiguration/backgroundSessionIdentifier``, the handler runs on the main thread once the session has
    /// delivered every event; for any other identifier this does nothing and the app keeps the handler.
    public nonisolated func handleEventsForBackgroundURLSession(identifier: String,
                                                                completionHandler: @escaping @Sendable () -> Void) {
        guard identifier == configuration.backgroundSessionIdentifier else { return }
        downloadSession.setBackgroundCompletionHandler(completionHandler)
    }
    #endif

    // MARK: Install queue

    /// One install, from its place in the line to its final state. Every state change of the pack happens here, in
    /// order, so the last thing published is the outcome.
    private func runInstall(_ pack: PackID, ticket: Int, queuedBytes: Int64) async throws {
        defer {
            installs[pack] = nil
            leaveLine(ticket)
        }
        await publish { $0.packs[pack] = .downloading(DownloadProgress(bytesReceived: 0, totalBytes: queuedBytes)) }
        do {
            try await waitForTurn(ticket)
            try Task.checkCancellation()
            // Planned again: a refresh may have replaced the manifest while this install waited.
            let plan = try makePlan(pack)
            if plan.totalBytes != queuedBytes {
                await publish { $0.packs[pack] = .downloading(DownloadProgress(bytesReceived: 0, totalBytes: plan.totalBytes)) }
            }
            try await download(plan, for: pack)
            let installed = bundled[pack] ?? store.installedPack(from: plan.record)
            let catalog = buildCatalog()
            await publish {
                $0.packs[pack] = .installed(installed)
                $0.catalog = catalog
            }
        } catch {
            let failure = error is CancellationError
                ? MaqsError.download(.cancelled)
                : Self.typed(error, fallback: .download(.network(statusCode: nil)))
            let cancelled = failure == .download(.cancelled)
            let settled = cancelled ? settledState(pack) : .failed(failure)
            await publish { $0.packs[pack] = settled }
            if cancelled {
                logger.info("install of \(pack.directoryName, privacy: .public) cancelled")
            } else {
                logger.error("install of \(pack.directoryName, privacy: .public) failed")
            }
            throw failure
        }
    }

    /// Runs `plan`, applying its progress to the state on the main actor. Returns once every event has been applied,
    /// so nothing from this install reaches the state after its outcome.
    private func download(_ plan: Installer.Plan, for pack: PackID) async throws {
        // Progress is cumulative and `verifying` comes last, so when the main actor falls behind only the newest
        // events matter.
        let (events, sink) = AsyncStream.makeStream(of: InstallEvent.self, bufferingPolicy: .bufferingNewest(64))
        let state = state
        let applier = Task { @MainActor in
            var throttle = ProgressThrottle()
            for await event in events {
                // A pack that is no longer downloading (removed, or already verifying) keeps its state.
                guard case .downloading? = state.packs[pack] else { continue }
                switch event {
                case .progress(let progress):
                    if let accepted = throttle.accept(progress) { state.packs[pack] = .downloading(accepted) }
                case .verifying:
                    state.packs[pack] = .verifying
                }
            }
        }
        do {
            try await installer.run(plan, progress: { sink.yield(.progress($0)) }, onVerifying: { sink.yield(.verifying) })
        } catch {
            sink.finish()
            await applier.value
            throw error
        }
        sink.finish()
        await applier.value
    }

    /// Returns when `ticket` is at the front of the line. A cancelled waiter leaves the line at once and throws
    /// `CancellationError`; one whose turn has already come checks for cancellation itself.
    private func waitForTurn(_ ticket: Int) async throws {
        guard line.first?.ticket != ticket else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (turn: CheckedContinuation<Void, any Error>) in
                guard let index = line.firstIndex(where: { $0.ticket == ticket }) else {
                    turn.resume(throwing: CancellationError())
                    return
                }
                if index == 0 { turn.resume() } else { line[index].turn = turn }
            }
        } onCancel: {
            Task { await self.cancelWaiting(ticket) }
        }
    }

    private func cancelWaiting(_ ticket: Int) {
        guard let index = line.firstIndex(where: { $0.ticket == ticket }), index > 0, let turn = line[index].turn else { return }
        line.remove(at: index)
        turn.resume(throwing: CancellationError())
    }

    /// Takes `ticket` out of the line; when it was at the front, the next install's turn begins.
    private func leaveLine(_ ticket: Int) {
        guard let index = line.firstIndex(where: { $0.ticket == ticket }) else { return }
        line.remove(at: index)
        guard index == 0, let next = line.first?.turn else { return }
        line[0].turn = nil
        next.resume()
    }

    // MARK: Helpers

    /// The plan for `pack` against the current manifest and record. Throws before anything is written.
    private func makePlan(_ pack: PackID) throws -> Installer.Plan {
        guard let manifest else { throw MaqsError.download(.noCatalog) }
        guard let selections = CatalogBuilder.selections(manifest: manifest.manifest, pack: pack, layers: configuration.layers),
              !selections.isEmpty
        else { throw MaqsError.download(.notInCatalog(pack)) }
        let existing: PackRecord?
        do {
            existing = try store.record(for: pack)
        } catch {
            // An unreadable record means a full install, which replaces it.
            logger.error("pack record unreadable, installing in full: \(pack.directoryName, privacy: .public)")
            existing = nil
        }
        do {
            return try Installer.plan(id: pack, release: manifest.manifest.release, selections: selections, existing: existing)
        } catch {
            throw Self.typed(error, fallback: .download(.notInCatalog(pack)))
        }
    }

    /// Deletes every file in the downloads folder that no entry of `manifest` names, resume data included. Keys are
    /// `<sha256>-<file>`, so a file is kept when its name starts with a listed SHA-256 and a hyphen. Skipped while an
    /// install is queued or running: its plan can come from the previous manifest.
    private func pruneDownloads(keeping manifest: Manifest) {
        guard installs.isEmpty else { return }
        let layers = manifest.regions.map(\.layers) + manifest.base.map(\.layers)
        let listed = Set(layers.flatMap { $0.values.joined() }.map(\.sha256))
        let fileManager = FileManager.default
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: store.layout.downloadsDirectory, includingPropertiesForKeys: nil)
        } catch {
            logger.error("downloads folder unreadable")
            return
        }
        var deleted = 0
        for url in contents {
            let name = url.lastPathComponent
            let digest = name.prefix { $0 != "-" }
            if digest.count < name.count, listed.contains(String(digest)) { continue }
            do {
                try fileManager.removeItem(at: url)
                deleted += 1
            } catch {
                logger.error("could not delete the stale download \(name, privacy: .public)")
            }
        }
        if deleted > 0 { logger.info("deleted \(deleted) stale downloads") }
    }

    /// What a pack is when nothing runs for it: installed when a record or a bundled file says so, else not installed.
    private func settledState(_ pack: PackID) -> PackState {
        installedPack(pack).map(PackState.installed) ?? .notInstalled
    }

    private func installedPacks() -> [PackID: InstalledPack] {
        var result = store.records().mapValues { store.installedPack(from: $0) }
        for (id, pack) in bundled { result[id] = pack }
        return result
    }

    private func catalog(from manifest: (manifest: Manifest, fetchedAt: Date)) -> Catalog {
        CatalogBuilder.build(manifest: manifest.manifest, fetchedAt: manifest.fetchedAt, layers: configuration.layers,
                             installed: installedPacks())
    }

    private func buildCatalog() -> Catalog? {
        manifest.map(catalog(from:))
    }

    private func publish(_ update: @MainActor @Sendable (MaqsState) -> Void) async {
        let state = state
        await MainActor.run { update(state) }
    }

    /// The ``MaqsError`` for an error thrown inside the package; `fallback` stands in for a type no callee documents.
    private static func typed(_ error: any Error, fallback: MaqsError) -> MaqsError {
        switch error {
        case let error as MaqsError: return error
        case let error as ManifestError: return .manifest(error)
        case let error as DownloadError: return .download(error)
        case let error as StorageError: return .storage(error)
        case let error as SourcesError: return .sources(error)
        default:
            logger.error("unexpected error type \(String(describing: type(of: error)), privacy: .public)")
            return fallback
        }
    }

    /// A configuration nothing else holds: `DownloadSession` mutates the one it is given.
    private static func copy(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        // `copy()` of a URLSessionConfiguration always returns one; the fallback exists only to satisfy the cast.
        configuration.copy() as? URLSessionConfiguration ?? .default
    }
}

extension Maqs {
    /// Decides which progress values reach ``MaqsState``: never one smaller than already seen (concurrent downloads
    /// report slightly out of order), and at most one per 256 KiB, except a value that reaches the total.
    struct ProgressThrottle {
        static let step: Int64 = 262_144
        private var highest: Int64 = 0
        private var published: Int64 = 0

        /// `progress` when it should be published, `nil` when it should be dropped.
        mutating func accept(_ progress: DownloadProgress) -> DownloadProgress? {
            guard progress.bytesReceived > highest else { return nil }
            highest = progress.bytesReceived
            let complete = progress.bytesReceived >= progress.totalBytes
            guard complete || progress.bytesReceived - published >= Self.step else { return nil }
            published = progress.bytesReceived
            return progress
        }
    }
}
