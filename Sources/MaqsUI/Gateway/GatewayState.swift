import Foundation
import MaqsPMTiles
import Synchronization

/// What the gateway needs from the map: the online tile templates, whether it may use them, and how to reach them.
struct GatewayConfiguration: Sendable {
    /// The gateway's online request timeout. A tile that takes longer is answered as if there were no network.
    static let requestTimeout: TimeInterval = 15

    var templates: TileTemplates
    /// `MaqsConfiguration.onlineTiles`, and an online source exists.
    var onlineAllowed: Bool
    /// `MaqsConfiguration.fullUserAgent`, sent with every online request.
    var userAgent: String
    /// The base of the gateway's own session. It is copied, never changed; the gateway removes its cache, sets the
    /// timeout and adds the User-Agent to the copy. Tests pass a stub server's configuration here.
    var sessionConfiguration: URLSessionConfiguration = .ephemeral
}

/// How the gateway answered since the state was last reset; in memory only.
struct GatewayCounters: Sendable, Equatable {
    /// Tiles served from an installed region's archive.
    var local = 0
    /// 204s: an installed region or a base pack covers the tile and has nothing for it.
    var empty = 0
    /// Responses from the network, passed back to MapLibre.
    var online = 0
    /// Tiles served from a base pack because the network could not answer.
    var base = 0
    /// Requests that got no tile because something failed: an archive that cannot be read (answered 204), a network
    /// error that is not a connection failure, or no network answer and no base pack (answered as not connected).
    var failed = 0
    /// Requests accepted as tiles that were no longer tiles of the current templates when they started. Each is failed
    /// as not connected, so MapLibre asks again and the current templates decide; the gateway sends none of them.
    var passedThrough = 0
}

/// What the gateway tells MapLibre for one request.
enum TileAnswer: Sendable {
    case response(HTTPURLResponse, Data)
    case failure(any Error)
}

/// A line the gateway logs, reported to the test seam of ``GatewayState/resetForTesting(now:logSink:)`` next to the
/// `os.Logger` call, so tests check what is logged without reading the log store, which lags on the simulator.
enum GatewayLogEvent: Sendable, Equatable {
    /// An archive cannot be read: its file name and the `PMTilesReadError` case. Logged once per archive.
    case archiveUnreadable(file: String, error: String)
    /// A tile came back 429.
    case rateLimited
    /// A pause began, with its length.
    case pauseStarted(seconds: Int64)
    /// A pause was seen over.
    case pauseEnded
}

/// What `TileGateway` does with a request it accepted.
enum TileStart: Sendable {
    /// Answer at once.
    case answer(TileAnswer)
    /// Ask the network: hand it to ``GatewayState/send(_:completion:)``.
    case online(OnlineTile)
}

/// A tile request routed to the network. It names no session: ``GatewayState/send(_:completion:)`` takes the one
/// current when the request goes out.
struct OnlineTile: Sendable {
    let tile: TileRequest
    /// MapLibre's request URL: the answer is for it.
    let url: URL
    /// MapLibre's request as it came, its conditional headers included.
    let request: URLRequest
}

/// What ``GatewayState/send(_:completion:)`` did.
enum TileSend: Sendable {
    /// The request is on its way; the completion gets the answer.
    case sent(URLSessionDataTask)
    /// The network may no longer be asked, so this is the answer; the completion is never called.
    case answer(TileAnswer)
}

/// The state every `TileGateway` instance reads: the templates, the installed archives, the network state and the
/// pause after a 429. MapLibre calls the gateway on a background thread, so all of it sits behind one lock; archive and
/// network I/O happen outside it.
///
/// The decisions are made here, the URL loading system's plumbing is in `TileGateway`:
/// - Inside an installed region, the region's archive answers: 200 with the tile's inflated bytes, or 204.
/// - Outside every region, the network answers through the gateway's own session, unless the device is offline, a pause
///   runs or online tiles are off.
/// - When the network cannot answer (one of those three, a 429, a connection failure or a timeout), a base pack that
///   covers the tile answers; with none, the request fails as not connected, which MapLibre retries with backoff while
///   it shows what it has cached.
final class GatewayState: Sendable {
    static let shared = GatewayState()

    /// URLError codes that mean the network could not be reached: the base-pack step answers instead.
    private static let connectionFailures: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .timedOut, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
    ]

    /// What `configure` set.
    private struct Online {
        let templates: TileTemplates
        let allowed: Bool
        let userAgent: String
        let session: URLSession
    }

    private struct State {
        var online: Online?
        var table = RoutingTable(regions: [], basePacks: [])
        var offline = false
        var pause = RateLimitPause()
        /// Whether a pause has started whose end is not logged yet.
        var pauseRunning = false
        var counters = GatewayCounters()
        /// The archives opened so far, by URL; only listed ones are kept.
        var archives: [URL: PMTilesArchive] = [:]
        /// The archives whose read error has been logged, so each is logged once.
        var reported: Set<URL> = []
        var now: @Sendable () -> ContinuousClock.Instant
        /// Tests only: told of every line logged. Called with the lock held, so it must not call back into the gateway.
        var logSink: (@Sendable (GatewayLogEvent) -> Void)?

        func report(_ event: GatewayLogEvent) {
            logSink?(event)
        }

        /// Whether a pause runs; logs the end of one the first time it is seen over.
        mutating func pauseIsActive() -> Bool {
            let active = pause.isActive(at: now())
            if !active && pauseRunning {
                pauseRunning = false
                logger.notice("map online tiles resumed: the pause after a 429 is over")
                report(.pauseEnded)
            }
            return active
        }

        /// The online configuration when the network may be asked now; nil when online tiles are off, the device is
        /// offline or a pause runs.
        mutating func reachable() -> Online? {
            guard let online, online.allowed, !offline, !pauseIsActive() else { return nil }
            return online
        }

        /// The tile `url` asks for and where it goes; nil when it is not a tile of the current templates.
        mutating func decide(_ url: URL) -> (TileRequest, Decision)? {
            guard let online, let tile = online.templates.request(for: url) else { return nil }
            switch TileRouter.route(tile, in: table) {
            case .local(let archive):
                return (tile, .local(archive))
            case .empty:
                return (tile, .empty)
            case .online:
                return (tile, reachable() == nil ? .fallback : .online)
            }
        }
    }

    /// Where a tile goes, decided under the lock.
    private enum Decision {
        case local(URL)
        case empty
        case online
        case fallback
    }

    private let state: Mutex<State>

    private init() {
        state = Mutex(State(now: { .now }))
    }

    // MARK: Set by the map

    /// Replaces the templates, the online switch, the User-Agent and the session; the pause, the table and the counters
    /// stay. Requests already sent finish on the old session, which is invalidated once they have.
    func configure(_ configuration: GatewayConfiguration) {
        let online = Online(templates: configuration.templates, allowed: configuration.onlineAllowed,
                            userAgent: configuration.userAgent, session: Self.session(for: configuration))
        let replaced = state.withLock { state in
            let old = state.online?.session
            state.online = online
            return old
        }
        replaced?.finishTasksAndInvalidate()
    }

    /// Replaces what is installed. Archives the new table no longer lists are dropped; one still answering a request
    /// closes when that request is done.
    func setTable(_ table: RoutingTable) {
        let listed = table.archiveURLs
        state.withLock { state in
            state.table = table
            state.archives = state.archives.filter { listed.contains($0.key) }
            state.reported.formIntersection(listed)
        }
    }

    /// While offline, tiles outside the installed regions skip the network and go to the base-pack step at once.
    func setOffline(_ offline: Bool) {
        state.withLock { $0.offline = offline }
    }

    /// Whether online tiles are paused after a 429.
    var isPaused: Bool {
        state.withLock { $0.pauseIsActive() }
    }

    var counters: GatewayCounters {
        state.withLock { $0.counters }
    }

    /// Back to the state of a fresh process, with `now` as the clock and `logSink` told of every line logged (none by
    /// default). Tests share ``shared`` and call this first.
    func resetForTesting(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                         logSink: (@Sendable (GatewayLogEvent) -> Void)? = nil) {
        let replaced = state.withLock { state in
            let old = state.online?.session
            state = State(now: now, logSink: logSink)
            return old
        }
        replaced?.invalidateAndCancel()
    }

    // MARK: Read by TileGateway

    /// Whether `request` asks for a tile of the current templates.
    func isTile(_ request: URLRequest) -> Bool {
        guard let url = request.url, let templates = state.withLock({ $0.online?.templates }) else { return false }
        return templates.request(for: url) != nil
    }

    /// Decides what a request gets: an answer at once, or a trip to the network.
    func start(_ request: URLRequest) -> TileStart {
        guard let url = request.url, case let (tile, decision)? = state.withLock({ $0.decide(url) }) else {
            count(\.passedThrough)
            return .answer(.failure(URLError(.notConnectedToInternet)))
        }
        switch decision {
        case .local(let archive):
            return .answer(read(tile, from: archive, for: url, counting: \.local))
        case .empty:
            count(\.empty)
            return .answer(Self.localAnswer(nil, for: url))
        case .fallback:
            return .answer(fallback(tile, for: url))
        case .online:
            return .online(OnlineTile(tile: tile, url: url, request: request))
        }
    }

    /// Sends a tile ``start(_:)`` routed online, on the session current now, and hands the answer to `completion`.
    ///
    /// The task is created and resumed under the lock, so `configure` cannot invalidate the session in between: a task
    /// created on an invalidated session raises an Objective-C exception, which Swift cannot catch. A later
    /// `finishTasksAndInvalidate` lets the task finish. `configure` may have run since ``start(_:)``, so the current
    /// configuration applies, and when it no longer lets the network be asked (online tiles turned off, offline, a
    /// pause) the fallback answers instead.
    ///
    /// The request keeps MapLibre's headers, the conditional ones included, except `User-Agent`: that is always the
    /// configured one, whatever MapLibre's session was given.
    func send(_ online: OnlineTile, completion: @escaping @Sendable (TileAnswer) -> Void) -> TileSend {
        let task: URLSessionDataTask? = state.withLock { state in
            guard let current = state.reachable() else { return nil }
            var outbound = online.request
            outbound.setValue(current.userAgent, forHTTPHeaderField: "User-Agent")
            // There is no cache to ignore; the policy only says so. MapLibre's ambient cache is the cache.
            outbound.cachePolicy = .reloadIgnoringLocalCacheData
            outbound.timeoutInterval = GatewayConfiguration.requestTimeout
            let task = current.session.dataTask(with: outbound) { data, response, error in
                completion(self.finish(online, data: data, response: response, error: error))
            }
            task.resume()
            return task
        }
        guard let task else { return .answer(fallback(online.tile, for: online.url)) }
        return .sent(task)
    }

    /// The configuration of the gateway's current session (a copy), for tests.
    var sessionConfigurationForTesting: URLSessionConfiguration? {
        state.withLock { $0.online?.session.configuration }
    }

    /// Settles what the network answered: the pause, the counters and what MapLibre gets. A cancelled request is
    /// answered with its error and not counted: `stopLoading` cancelled it, and the gateway drops the answer.
    private func finish(_ online: OnlineTile, data: Data?, response: URLResponse?, error: (any Error)?) -> TileAnswer {
        if let error {
            let code = (error as? URLError)?.code
            if code == .cancelled { return .failure(error) }
            if let code, Self.connectionFailures.contains(code) { return fallback(online.tile, for: online.url) }
            count(\.failed)
            return .failure(error)
        }
        guard let http = response as? HTTPURLResponse else {
            count(\.failed)
            return .failure(URLError(.badServerResponse))
        }
        if http.statusCode == 429 {
            rateLimited(online.tile)
            return fallback(online.tile, for: online.url)
        }
        if (200..<300).contains(http.statusCode) || http.statusCode == 304 { succeeded() }
        count(\.online)
        return .response(Self.decoded(http, for: online.url), data ?? Data())
    }

    // MARK: Routing

    /// The answer when the network cannot give one: a base pack's tile, or a connection error.
    private func fallback(_ tile: TileRequest, for url: URL) -> TileAnswer {
        switch state.withLock({ TileRouter.fallback(tile, in: $0.table) }) {
        case .local(let archive):
            return read(tile, from: archive, for: url, counting: \.base)
        case .unavailable:
            count(\.failed)
            return .failure(URLError(.notConnectedToInternet))
        }
    }

    // MARK: Archives

    /// The tile from `archive`: 200 with its bytes, or 204 when the archive lacks it or cannot be read.
    private func read(_ tile: TileRequest, from archive: URL, for url: URL,
                      counting counter: WritableKeyPath<GatewayCounters, Int>) -> TileAnswer {
        let data: Data?
        do {
            data = try opened(archive).tile(z: tile.z, x: tile.x, y: tile.y)
        } catch {
            reportOnce(error, archive: archive)
            count(\.failed)
            return Self.localAnswer(nil, for: url)
        }
        count(data == nil ? \.empty : counter)
        return Self.localAnswer(data, for: url)
    }

    /// The archive at `url`, opened on first use and kept while the table lists it. An open archive keeps answering
    /// after its file is removed: its descriptor stays open.
    private func opened(_ url: URL) throws(PMTilesReadError) -> PMTilesArchive {
        if let archive = state.withLock({ $0.archives[url] }) { return archive }
        let archive = try PMTilesArchive(url: url)
        return state.withLock { state in
            if let first = state.archives[url] { return first }
            // The table may have changed while the file was opened; an archive it no longer lists answers this
            // request and is not kept.
            if state.table.archiveURLs.contains(url) { state.archives[url] = archive }
            return archive
        }
    }

    private func reportOnce(_ error: PMTilesReadError, archive: URL) {
        let first = state.withLock { state in
            let first = state.reported.insert(archive).inserted
            if first {
                state.report(.archiveUnreadable(file: archive.lastPathComponent, error: String(describing: error)))
            }
            return first
        }
        guard first else { return }
        logger.error("map archive \(archive.lastPathComponent, privacy: .public) cannot be read (\(String(describing: error), privacy: .public)): its tiles are answered empty")
    }

    // MARK: The pause

    private func rateLimited(_ tile: TileRequest) {
        logger.error("map tile \(Self.describe(tile), privacy: .private): status 429")
        let seconds: Int64? = state.withLock { state in
            state.report(.rateLimited)
            // A 429 during a pause answers a request sent before it began: the same burst, ignored.
            guard !state.pauseIsActive() else { return nil }
            let now = state.now()
            state.pause.rateLimited(at: now)
            state.pauseRunning = true
            let seconds = state.pause.end.map { ($0 - now).components.seconds } ?? 0
            state.report(.pauseStarted(seconds: seconds))
            return seconds
        }
        if let seconds {
            logger.notice("map online tiles paused for \(seconds, privacy: .public) s after a 429")
        }
    }

    /// A tile came back. One that arrives during a pause answers a request sent before the 429, so it says nothing
    /// about the server's limit now and must not undo the doubling.
    private func succeeded() {
        state.withLock { state in
            if !state.pauseIsActive() { state.pause.succeeded() }
        }
    }

    // MARK: Answers

    private func count(_ counter: WritableKeyPath<GatewayCounters, Int>) {
        state.withLock { $0.counters[keyPath: counter] += 1 }
    }

    /// A local answer: 200 with the tile's bytes, or 204 with none.
    ///
    /// The bytes are inflated and carry no `Content-Encoding`: MapLibre parses what it is given and would fail on gzip.
    /// There is no `Cache-Control` and no `Expires`: MapLibre turns an expiry already past into one in the future (it
    /// takes it for clock skew). With none, it asks on every load and never on a timer, and still draws its copy offline.
    private static func localAnswer(_ data: Data?, for url: URL) -> TileAnswer {
        guard let response = HTTPURLResponse(url: url, statusCode: data == nil ? 204 : 200, httpVersion: "HTTP/1.1",
                                             headerFields: [:])
        else { return .failure(URLError(.badURL)) }
        return .response(response, data ?? Data())
    }

    /// The network's response for MapLibre's URL. URLSession has already decoded the body but keeps
    /// `Content-Encoding` and the encoded `Content-Length`, which would describe bytes MapLibre never sees, so those
    /// two go; the status and every other header, the caching ones included, stay as the provider sent them.
    private static func decoded(_ response: HTTPURLResponse, for url: URL) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        for case let (name as String, value as String) in response.allHeaderFields {
            let lowercased = name.lowercased()
            guard lowercased != "content-encoding", lowercased != "content-length" else { continue }
            headers[name] = value
        }
        return HTTPURLResponse(
            url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: headers) ?? response
    }

    /// The gateway's own session: a copy of the configuration given, with no cache (MapLibre's ambient cache is the
    /// only one; MapLibre sends its own conditional headers), the gateway's timeout and the app's User-Agent, which
    /// ``send(_:completion:)`` also sets on each request. Nothing that disables caching is added. `TileGateway` is taken
    /// out of the copy's protocols, so the gateway's requests never come back to it, and redirects are followed only on
    /// the same host.
    private static func session(for configuration: GatewayConfiguration) -> URLSession {
        // `copy()` of a URLSessionConfiguration always returns one; the fallback exists only to satisfy the cast.
        let copy = configuration.sessionConfiguration.copy() as? URLSessionConfiguration ?? .ephemeral
        var headers = copy.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = configuration.userAgent
        copy.httpAdditionalHeaders = headers
        copy.urlCache = nil
        copy.requestCachePolicy = .reloadIgnoringLocalCacheData
        copy.timeoutIntervalForRequest = GatewayConfiguration.requestTimeout
        let gateway = ObjectIdentifier(TileGateway.self)
        copy.protocolClasses = copy.protocolClasses?.filter { ObjectIdentifier($0) != gateway }
        return URLSession(configuration: copy, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    private static func describe(_ tile: TileRequest) -> String {
        "\(tile.z)/\(tile.x)/\(tile.y)"
    }
}

/// Follows a redirect only to the scheme, host and port of the request it answers: the gateway talks only to the hosts
/// its templates name, which come from `sources.json`. A redirect anywhere else is refused, and the 3xx goes back to
/// MapLibre as the response, which MapLibre treats as an error and retries with backoff.
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url, Self.sameOrigin(from, to) else {
            logger.notice("map tile redirect to another host refused: status \(response.statusCode, privacy: .public)")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased()
            && a.port == b.port
    }
}

private extension RoutingTable {
    /// Every archive the table names.
    var archiveURLs: Set<URL> {
        Set(regions.flatMap { $0.archives.map(\.url) } + basePacks.map(\.url))
    }
}
