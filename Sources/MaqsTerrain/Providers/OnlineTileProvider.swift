import Foundation

/// Elevation tiles from an online terrarium source, with the etiquette a free demo server needs: an identifying
/// User-Agent, the HTTP cache honoured, at most four requests at once, one request per tile however many callers want
/// it, none for a tile nobody waits for any more, and none at all during a 429 cool-down. Every failure is a
/// `TileLoad.missing` value, never thrown.
actor OnlineTileProvider: TileProvider {
    private static let concurrentRequests = 4

    /// What one request came back with, worked out off the actor (the decode is the expensive part).
    private enum Response: Sendable {
        case tile(ElevationTile, bytes: Int)
        case undecodable(bytes: Int)
        case status(Int, bytes: Int)
        case transportFailure(code: Int?)
    }

    /// One fetch of one tile and the callers waiting for it, by waiter id. The id tells a fetch its own flight from a
    /// later one for the same tile.
    private struct Flight {
        let id: UInt64
        var waiters: [UInt64: CheckedContinuation<TileLoad, any Error>]
    }

    /// What a fetch does when its limiter slot comes up.
    private enum Turn {
        case send
        case coolingDown
        /// Every caller left while the fetch waited; the flight has ended.
        case abandoned
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
    /// The flight of each tile being fetched. A key is present from the first caller until its fetch ends or is abandoned.
    private var flights: [TileKey: Flight] = [:]
    /// Source of waiter and flight ids.
    private var nextID: UInt64 = 0

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
    /// the fetch carries on for the other callers, and sends no request if none is left when its turn comes.
    func load(_ key: TileKey) async throws -> TileLoad {
        try Task.checkCancellation()
        guard !isCoolingDown(at: now()) else { return .missing(.rateLimited) }
        let waiter = takeID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if flights[key] == nil {
                    let flight = takeID()
                    flights[key] = Flight(id: flight, waiters: [waiter: continuation])
                    // Unstructured on purpose: cancelling the caller that started it must not cancel it.
                    Task { await self.fetch(key, flight: flight) }
                } else {
                    flights[key]?.waiters[waiter] = continuation
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
        flights[key]?.waiters.count ?? 0
    }

    /// Whether a flight for `key` exists, for tests.
    func isFetching(_ key: TileKey) -> Bool {
        flights[key] != nil
    }

    private func takeID() -> UInt64 {
        defer { nextID &+= 1 }
        return nextID
    }

    private func leave(_ key: TileKey, waiter: UInt64) {
        flights[key]?.waiters.removeValue(forKey: waiter)?.resume(throwing: CancellationError())
    }

    /// Fetches one tile through the limiter, then hands the result to every caller still waiting and ends the flight.
    /// A request already sent completes even when nobody waits any more; its result is dropped.
    private func fetch(_ key: TileKey, flight: UInt64) async {
        let result: TileLoad
        if let url = source.url(for: key) {
            var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (session, tileSize) = (session, tileSize)
            let outcome: TileLoad?
            do {
                outcome = try await limiter.run { [request] () async -> TileLoad? in
                    switch await self.turn(of: key, flight: flight) {
                    case .abandoned: return nil
                    case .coolingDown: return .missing(.rateLimited)
                    case .send: break
                    }
                    let response = await Self.perform(request, on: session, tileSize: tileSize)
                    // Settled before the slot is given back, so a request queued behind a 429 sees the cool-down.
                    return await self.settle(response, for: key)
                }
            } catch {
                // The limiter throws only on cancellation, and nothing cancels this task.
                outcome = .missing(.networkFailure)
            }
            // An abandoned flight was ended in `turn`; the key may belong to a newer flight by now.
            guard let outcome else { return }
            result = outcome
        } else {
            logger.error("online terrain template gave no URL for tile \(Self.describe(key), privacy: .private)")
            result = .missing(.networkFailure)
        }
        guard let ended = flights[key], ended.id == flight else { return }
        flights[key] = nil
        for continuation in ended.waiters.values {
            continuation.resume(returning: result)
        }
    }

    /// Decides, when the fetch's limiter slot comes up, whether its request goes out. A flight nobody waits for any more
    /// ends here, in the same actor step as the check, so a caller arriving later starts a fresh flight instead of
    /// joining one that will never send.
    private func turn(of key: TileKey, flight: UInt64) -> Turn {
        guard let current = flights[key], current.id == flight, !current.waiters.isEmpty else {
            if flights[key]?.id == flight { flights[key] = nil }
            logger.info("online terrain tile \(Self.describe(key), privacy: .private): not requested, nobody waits for it")
            return .abandoned
        }
        // A 429 may have arrived while this request waited for its turn.
        return isCoolingDown(at: now()) ? .coolingDown : .send
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
            // A tile that arrives during a pause answers a request sent before the 429 (it usually trails the 429,
            // having a body to carry), so it says nothing about the server's limit now and must not undo the doubling.
            if !isCoolingDown(at: now()) { coolDown.succeeded() }
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
