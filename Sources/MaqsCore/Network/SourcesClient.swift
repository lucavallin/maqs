import Foundation

/// `sources.json`: cached copy first, bundled copy as the fallback, refreshed on request.
struct SourcesClient: Sendable {
    let http: HTTPClient
    let cache: CachedDocument
    let url: URL
    let bundled: URL
    let maxAge: Duration
    let now: @Sendable () -> Date

    /// The copy of `config/sources.json` shipped in the package; `scripts/update-fixtures.sh` keeps it in sync and CI checks it.
    static var bundledURL: URL {
        // The resource is declared in Package.swift; a missing one is a packaging error, not a runtime condition.
        Bundle.module.url(forResource: "sources", withExtension: "json")
            ?? URL(filePath: "/missing/sources.json")
    }

    /// The best copy available without a request: cached if it decodes, else bundled. `nil` means no readable
    /// copy exists, neither cached nor bundled.
    func current() -> OnlineSources? {
        if let stored = cache.read(), let sources = try? SourcesDocument.decode(stored.data) { return sources }
        guard let data = try? Data(contentsOf: bundled), let sources = try? SourcesDocument.decode(data) else {
            logger.error("bundled sources.json unreadable")
            return nil
        }
        return sources
    }

    /// Returns the sources, fetching unless the cache is fresh. A cache stamped in the future counts as stale.
    ///
    /// - Throws: `SourcesError` for transport, status and decoding failures, and `StorageError` when the
    ///   fetched file cannot be written to the cache (it is then not returned). A cancelled request throws
    ///   `CancellationError`. On any failure the cached copy stays what it was.
    func refresh(policy: RefreshPolicy) async throws -> OnlineSources {
        let started = now()
        let stored = cache.read()
        let cached = stored.flatMap { entry in (try? SourcesDocument.decode(entry.data)).map { (sources: $0, etag: entry.meta.etag, fetchedAt: entry.meta.fetchedAt) } }
        if policy == .ifStale, let cached {
            let age = started.timeIntervalSince(cached.fetchedAt)
            if age >= 0, age < maxAge.seconds { return cached.sources }
        }
        let response: HTTPClient.Response
        do {
            response = try await http.get(url, ifNoneMatch: cached?.etag)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            logger.error("sources.json fetch failed: transport error")
            throw SourcesError.network(statusCode: nil)
        }
        switch response {
        case .notModified:
            guard let cached else {
                logger.error("sources.json fetch failed: HTTP 304 with no cached copy")
                throw SourcesError.network(statusCode: 304)
            }
            try cache.touch(fetchedAt: started)
            logger.info("sources.json unchanged")
            return cached.sources
        case .status(let code):
            logger.error("sources.json fetch failed: HTTP \(code)")
            throw SourcesError.network(statusCode: code)
        case .ok(let data, let etag):
            let sources: OnlineSources
            do {
                sources = try SourcesDocument.decode(data)
            } catch let error as SourcesError {
                // The case and its field path; a SourcesError carries no document content and no URL.
                logger.error("sources.json rejected: \(String(describing: error), privacy: .public)")
                throw error
            }
            try cache.write(data: data, meta: .init(etag: etag, fetchedAt: started))
            logger.info("sources.json fetched, \(data.count) bytes")
            return sources
        }
    }
}
