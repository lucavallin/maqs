import Foundation
import Synchronization

/// One scripted HTTP response.
public struct StubResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    /// When set, the request fails at the transport level with this error instead of getting a response.
    public var transportError: URLError.Code?
    /// Seconds to wait before the response (or the transport error) is delivered; a task cancelled meanwhile gets nothing.
    public var delay: TimeInterval
    /// When set, the response is held until the test releases the gate, however long that takes.
    public var gate: StubGate?
    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data(), transportError: URLError.Code? = nil,
                delay: TimeInterval = 0, gate: StubGate? = nil) {
        self.status = status; self.headers = headers; self.body = body; self.transportError = transportError; self.delay = delay
        self.gate = gate
    }
}

/// Holds back the responses that name it until the test calls `release()`, so a test can keep a request in flight
/// for exactly as long as it needs instead of guessing a delay. Release it in a `defer`, so a failing test does not
/// leave requests waiting.
public final class StubGate: Sendable {
    private let released = Mutex(false)

    public init() {}

    /// Lets every held response through, and every later one at once.
    public func release() { released.withLock { $0 = true } }

    /// Whether `release()` has been called.
    public var isReleased: Bool { released.withLock { $0 } }
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
    /// How often a response held by a `StubGate` checks whether it was released.
    private static let gatePollInterval: TimeInterval = 0.005
    private static let servers = Mutex<[String: StubServer]>([:])
    /// Set by `stopLoading`, so a delayed response is not delivered to a cancelled task.
    private let stopped = Mutex(false)
    private let delayed = Mutex<Delayed?>(nil)

    private struct Delayed {
        let stub: StubResponse
        let response: HTTPURLResponse
        let modes: [RunLoop.Mode]
    }

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
        guard stub.delay > 0 || stub.gate != nil else {
            deliver(stub, response: response)
            return
        }
        // A selector on the client thread's run loop, not a dispatch queue: a `@Sendable` closure cannot capture this
        // non-Sendable `URLProtocol`, and URLProtocol expects its client to be called from the thread that started loading.
        let modes = [RunLoop.current.currentMode ?? .default]
        delayed.withLock { $0 = Delayed(stub: stub, response: response, modes: modes) }
        perform(#selector(deliverDelayed), with: nil, afterDelay: stub.delay, inModes: modes)
    }

    @objc private func deliverDelayed() {
        guard let delayed = delayed.withLock({ $0 }) else { return }
        if let gate = delayed.stub.gate, !gate.isReleased {
            // Polled on the same run loop for the reason above; `stopLoading` cancels the next poll.
            perform(#selector(deliverDelayed), with: nil, afterDelay: Self.gatePollInterval, inModes: delayed.modes)
            return
        }
        deliver(delayed.stub, response: delayed.response)
    }

    private func deliver(_ stub: StubResponse, response: HTTPURLResponse) {
        guard !stopped.withLock({ $0 }) else { return }
        if let code = stub.transportError {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }
}
