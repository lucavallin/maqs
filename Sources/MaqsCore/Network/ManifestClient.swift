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
        guard let stored = cache.read(), let manifest = try? Manifest.decode(stored.data, manifestHost: host) else { return nil }
        return (manifest, stored.meta.fetchedAt)
    }

    func load(policy: RefreshPolicy) async throws -> (manifest: Manifest, fetchedAt: Date) {
        let cached = cached()
        if policy == .ifStale, let cached, now().timeIntervalSince(cached.fetchedAt) < maxAge.seconds {
            return cached
        }
        let etag = cache.read()?.meta.etag
        let response: HTTPClient.Response
        do {
            response = try await http.get(url, ifNoneMatch: cached == nil ? nil : etag)
        } catch {
            logger.error("manifest fetch failed: transport error")
            throw ManifestError.network(statusCode: nil)
        }
        switch response {
        case .notModified:
            guard let cached else { throw ManifestError.network(statusCode: 304) }
            try cache.touch(fetchedAt: now())
            logger.info("manifest unchanged")
            return (cached.manifest, now())
        case .status(429):
            throw ManifestError.rateLimited
        case .status(let code):
            throw ManifestError.network(statusCode: code)
        case .ok(let data, let newETag):
            let manifest = try Manifest.decode(data, manifestHost: host)
            try cache.write(data: data, meta: .init(etag: newETag, fetchedAt: now()))
            logger.info("manifest fetched: \(manifest.release, privacy: .public), \(data.count) bytes")
            return (manifest, now())
        }
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (s, attos) = components
        return TimeInterval(s) + TimeInterval(attos) / 1e18
    }
}
