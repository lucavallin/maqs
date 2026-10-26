import Foundation

/// Elevation tiles from an online terrarium source, with the etiquette a free demo server needs: an identifying
/// User-Agent, the HTTP cache honoured, at most four requests at once, one request per tile however many callers want
/// it, and no request at all during a 429 cool-down. Every failure is a `TileLoad.missing` value, never thrown.
actor OnlineTileProvider: TileProvider {
    private static let concurrentRequests = 4

    /// What one request came back with, worked out off the actor (the decode is the expensive part).
    private enum Response: Sendable {
        case tile(ElevationTile, bytes: Int)
        case undecodable(bytes: Int)
        case status(Int, bytes: Int)
        case transportFailure(code: Int?)
    }

    nonisolated let zoomRange: ClosedRange<Int>
    nonisolated let tileSize: Int
    nonisolated let isOnline = true
    /// Built from a copy of the configuration given, so the caller's object is never changed.
    nonisolated let session: URLSession
    private let source: OnlineTerrainSource
    private let userAgent: String
    private let now: @Sendable () -> ContinuousClock.Instant
    private let limiter = AsyncLimiter(limit: concurrentRequests)
    private var coolDown = CoolDown()
    /// Whether a cool-down has started whose end is not logged yet.
    private var coolDownRunning = false
    /// The callers waiting on each tile being fetched, by waiter id. A key is present exactly while its fetch runs.
    private var flights: [TileKey: [UInt64: CheckedContinuation<TileLoad, any Error>]] = [:]
    private var nextWaiter: UInt64 = 0

    /// `userAgent` is sent as given, so it already carries the package token. `cacheDirectory` nil keeps the
    /// configuration's own `urlCache`.
    init(source: OnlineTerrainSource, userAgent: String, sessionConfiguration: URLSessionConfiguration,
         cacheDirectory: URL?, diskCacheBytes: Int, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        // `copy()` of a URLSessionConfiguration always returns one; the fallback exists only to satisfy the cast.
        let configuration = sessionConfiguration.copy() as? URLSessionConfiguration ?? .default
        if let cacheDirectory {
            configuration.urlCache = URLCache(memoryCapacity: 0, diskCapacity: diskCacheBytes, directory: cacheDirectory)
        }
        // The server's Cache-Control decides: a repeated look within its lifetime costs no request.
        configuration.requestCachePolicy = .useProtocolCachePolicy
        self.session = URLSession(configuration: configuration)
        self.source = source
        self.userAgent = userAgent
        self.now = now
        self.zoomRange = source.minZoom...source.maxZoom
        self.tileSize = source.tileSize
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    nonisolated func covers(_ key: TileKey) -> Bool {
        zoomRange.contains(key.z)
    }

    /// Joins the fetch of `key` already running, or starts one. A cancelled caller throws `CancellationError` at once;
    /// the fetch carries on for the other callers.
    func load(_ key: TileKey) async throws -> TileLoad {
        try Task.checkCancellation()
        guard !isCoolingDown(at: now()) else { return .missing(.rateLimited) }
        let waiter = nextWaiter
        nextWaiter &+= 1
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if flights[key] == nil {
                    flights[key] = [waiter: continuation]
                    // Unstructured on purpose: cancelling the caller that started it must not cancel it.
                    Task { await self.fetch(key) }
                } else {
                    flights[key]?[waiter] = continuation
                }
            }
        } onCancel: {
            // Runs after the continuation is stored: the actor is busy until the caller suspends.
            Task { await self.leave(key, waiter: waiter) }
        }
        // The result can arrive before the cancellation handler's task runs.
        try Task.checkCancellation()
        return result
    }

    /// Callers waiting on the fetch of `key`, for tests; 0 when none runs.
    func waiters(for key: TileKey) -> Int {
        flights[key]?.count ?? 0
    }

    private func leave(_ key: TileKey, waiter: UInt64) {
        flights[key]?.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
    }

    /// Fetches one tile through the limiter, then hands the result to every caller still waiting and ends the flight.
    private func fetch(_ key: TileKey) async {
        let result: TileLoad
        if let url = source.url(for: key) {
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (session, tileSize) = (session, tileSize)
            do {
                result = try await limiter.run { [request] in
                    // A 429 may have arrived while this request waited for its turn.
                    guard await self.mayRequest() else { return .missing(.rateLimited) }
                    let response = await Self.perform(request, on: session, tileSize: tileSize)
                    // Settled before the slot is given back, so a request queued behind a 429 sees the cool-down.
                    return await self.settle(response, for: key)
                }
            } catch {
                // The limiter throws only on cancellation, and nothing cancels this task.
                result = .missing(.networkFailure)
            }
        } else {
            logger.error("online terrain template gave no URL for tile \(Self.describe(key), privacy: .private)")
            result = .missing(.networkFailure)
        }
        for continuation in (flights.removeValue(forKey: key) ?? [:]).values {
            continuation.resume(returning: result)
        }
    }

    private static func perform(_ request: URLRequest, on session: URLSession, tileSize: Int) async -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .transportFailure(code: (error as? URLError)?.code.rawValue)
        }
        guard let http = response as? HTTPURLResponse else { return .transportFailure(code: nil) }
        guard http.statusCode == 200 else { return .status(http.statusCode, bytes: data.count) }
        do {
            return .tile(try TerrariumDecoder.decode(data, expectedSize: tileSize), bytes: data.count)
        } catch {
            return .undecodable(bytes: data.count)
        }
    }

    /// Logs the outcome, updates the cool-down and turns the response into a tile load.
    private func settle(_ response: Response, for key: TileKey) -> TileLoad {
        let tile = Self.describe(key)
        switch response {
        case .tile(let decoded, let bytes):
            logger.info("online terrain tile \(tile, privacy: .private): status 200, \(bytes, privacy: .public) bytes")
            coolDown.succeeded()
            return .tile(decoded)
        case .undecodable(let bytes):
            logger.error("online terrain tile \(tile, privacy: .private): status 200, \(bytes, privacy: .public) bytes that are not a \(self.tileSize, privacy: .public) px terrarium tile")
            return .missing(.networkFailure)
        case .status(404, let bytes):
            logger.info("online terrain tile \(tile, privacy: .private): status 404, \(bytes, privacy: .public) bytes")
            return .missing(.noData)
        case .status(429, let bytes):
            logger.error("online terrain tile \(tile, privacy: .private): status 429, \(bytes, privacy: .public) bytes")
            startCoolDown()
            return .missing(.rateLimited)
        case .status(let status, let bytes):
            logger.error("online terrain tile \(tile, privacy: .private): status \(status, privacy: .public), \(bytes, privacy: .public) bytes")
            return .missing(.networkFailure)
        case .transportFailure(let code):
            logger.error("online terrain tile \(tile, privacy: .private): transport error \(code ?? 0, privacy: .public)")
            return .missing(.networkFailure)
        }
    }

    private func startCoolDown() {
        let instant = now()
        // A 429 during a cool-down answers a request sent before it began; CoolDown ignores it and so does the log.
        guard !isCoolingDown(at: instant) else { return }
        coolDown.rateLimited(at: instant)
        coolDownRunning = true
        let seconds = coolDown.end.map { ($0 - instant).components.seconds } ?? 0
        logger.notice("online terrain cool-down started: no requests for \(seconds, privacy: .public) s")
    }

    private func mayRequest() -> Bool {
        !isCoolingDown(at: now())
    }

    /// Whether a cool-down is running; logs the end of one the first time it is seen over.
    private func isCoolingDown(at instant: ContinuousClock.Instant) -> Bool {
        let active = coolDown.isActive(at: instant)
        if !active && coolDownRunning {
            coolDownRunning = false
            logger.notice("online terrain cool-down ended")
        }
        return active
    }

    private static func describe(_ key: TileKey) -> String {
        "\(key.z)/\(key.x)/\(key.y)"
    }
}
