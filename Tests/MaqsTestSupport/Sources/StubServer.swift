import Foundation
import Synchronization

/// One scripted HTTP response.
public struct StubResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
}

/// Routes requests of one `URLSession` to scripted responses, with no network.
///
/// Each server has an id that travels in an `X-Maqs-Stub` header added by its `configuration`, so tests
/// running in parallel never see each other's routes. Download tasks and data tasks both go through it.
public final class StubServer: Sendable {
    public typealias Handler = @Sendable (URLRequest) -> StubResponse

    public let id = UUID().uuidString
    private let routes = Mutex<[String: Handler]>([:])
    private let seen = Mutex<[URLRequest]>([])

    public init() { StubURLProtocol.register(self) }
    deinit { StubURLProtocol.unregister(id) }

    /// Scripts the response for an absolute URL (query string included).
    public func route(_ url: URL, _ handler: @escaping Handler) {
        routes.withLock { $0[url.absoluteString] = handler }
    }

    /// Scripts a fixed response for an absolute URL.
    public func route(_ url: URL, status: Int = 200, headers: [String: String] = [:], body: Data) {
        route(url) { _ in StubResponse(status: status, headers: headers, body: body) }
    }

    /// Every request this server answered, in order.
    public var requests: [URLRequest] { seen.withLock { $0 } }

    /// A foreground session configuration whose requests all reach this server.
    public var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Maqs-Stub": id]
        return configuration
    }

    func respond(to request: URLRequest) -> StubResponse {
        seen.withLock { $0.append(request) }
        guard let url = request.url, let handler = routes.withLock({ $0[url.absoluteString] }) else {
            return StubResponse(status: 404)
        }
        return handler(request)
    }
}

final class StubURLProtocol: URLProtocol {
    private static let servers = Mutex<[String: StubServer]>([:])

    static func register(_ server: StubServer) { servers.withLock { $0[server.id] = server } }
    static func unregister(_ id: String) { servers.withLock { $0[id] = nil } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "X-Maqs-Stub") != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Maqs-Stub"),
              let server = Self.servers.withLock({ $0[id] }),
              let url = request.url
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let stub = server.respond(to: request)
        var headers = stub.headers
        headers["Content-Length"] = String(stub.body.count)
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
