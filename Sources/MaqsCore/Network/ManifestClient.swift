import Foundation

/// Fetches, validates and caches `manifest.json`. On any failure the cached manifest stays what it was.
struct ManifestClient: Sendable {
    let http: HTTPClient
    let cache: CachedDocument
    let url: URL
    let maxAge: Duration
    let now: @Sendable () -> Date

    private var host: String { url.host() ?? "" }

    /// The cached manifest, if there is one and it still decodes.
    func cached() -> (manifest: Manifest, fetchedAt: Date)? {
        stored()?.cached
    }

    /// Returns the manifest and when it was fetched. A cache stamped in the future counts as stale.
    ///
    /// - Throws: `ManifestError` for transport, status and decoding failures, and `StorageError` when the
    ///   fetched manifest cannot be written to the cache (it is then not returned). A cancelled request
    ///   throws `CancellationError`. There is no retry inside the call.
    func load(policy: RefreshPolicy) async throws -> (manifest: Manifest, fetchedAt: Date) {
        let started = now()
        let stored = stored()
        if policy == .ifStale, let cached = stored?.cached {
            let age = started.timeIntervalSince(cached.fetchedAt)
            if age >= 0, age < maxAge.seconds { return cached }
        }
        let response: HTTPClient.Response
        do {
            response = try await http.get(url, ifNoneMatch: stored?.etag)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            logger.error("manifest fetch failed: transport error")
            throw ManifestError.network(statusCode: nil)
        }
        switch response {
        case .notModified:
            guard let cached = stored?.cached else {
                logger.error("manifest fetch failed: HTTP 304 with no cached copy")
                throw ManifestError.network(statusCode: 304)
            }
            try cache.touch(fetchedAt: started)
            logger.info("manifest unchanged")
            return (cached.manifest, started)
        case .status(429):
            logger.error("manifest fetch failed: HTTP 429")
            throw ManifestError.rateLimited
        case .status(let code):
            logger.error("manifest fetch failed: HTTP \(code)")
            throw ManifestError.network(statusCode: code)
        case .ok(let data, let newETag):
            let manifest: Manifest
            do {
                manifest = try Manifest.decode(data, manifestHost: host)
            } catch let error as ManifestError {
                // The case and its field path; a ManifestError carries no document content and no URL.
                logger.error("manifest rejected: \(String(describing: error), privacy: .public)")
                throw error
            }
            try cache.write(data: data, meta: .init(etag: newETag, fetchedAt: started))
            logger.info("manifest fetched: \(manifest.release, privacy: .public), \(data.count) bytes")
            return (manifest, started)
        }
    }

    /// One cache read: the decoded manifest with its fetch time, and the etag to send. Nil when absent or undecodable.
    private func stored() -> (cached: (manifest: Manifest, fetchedAt: Date), etag: String?)? {
        guard let stored = cache.read(),
              let manifest = try? Manifest.decode(stored.data, manifestHost: host) else { return nil }
        return ((manifest, stored.meta.fetchedAt), stored.meta.etag)
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (s, attos) = components
        return TimeInterval(s) + TimeInterval(attos) / 1e18
    }
}
