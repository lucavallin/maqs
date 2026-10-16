import Foundation

/// When a cached document is good enough.
public enum RefreshPolicy: Sendable, Equatable {
    /// Use the cache while it is younger than the configured maximum age; fetch otherwise.
    case ifStale
    /// Always ask the server, with `If-None-Match` so an unchanged document costs no body.
    case always
}

/// Small-document GETs with the package's User-Agent and conditional requests. Not for pack files.
struct HTTPClient: Sendable {
    enum Response: Sendable, Equatable {
        case ok(Data, etag: String?)
        case notModified
        case status(Int)
    }

    let session: URLSession
    let userAgent: String

    func get(_ url: URL, ifNoneMatch etag: String?) async throws -> Response {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return .status(0) }
        switch http.statusCode {
        case 200: return .ok(data, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304: return .notModified
        default: return .status(http.statusCode)
        }
    }
}
