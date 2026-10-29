import Foundation
import MaqsCore
import MaqsPMTiles
import MaqsTestSupport
import Synchronization
import Testing

@testable import MaqsUI

/// A clock the test moves by hand.
private final class TestClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(by duration: Duration) { instant.withLock { $0 += duration } }
}

/// Collects what the gateway reports through its log seam.
private final class LogRecorder: Sendable {
    private let recorded = Mutex<[GatewayLogEvent]>([])
    var events: [GatewayLogEvent] { recorded.withLock { $0 } }
    func record(_ event: GatewayLogEvent) { recorded.withLock { $0.append(event) } }
}

/// Stands in for the URL loading system when a test drives a `TileGateway` itself; records the failures it is told.
private final class RecordingClient: NSObject, URLProtocolClient, Sendable {
    private let failures = Mutex<[URLError.Code?]>([])
    private let responses = Mutex(0)

    /// The `URLError` code of each failure, nil for an error of another kind.
    var failureCodes: [URLError.Code?] { failures.withLock { $0 } }
    var responseCount: Int { responses.withLock { $0 } }

    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse,
                     cacheStoragePolicy policy: URLCache.StoragePolicy) {
        responses.withLock { $0 += 1 }
    }
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) {}
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol) {}
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: any Error) {
        failures.withLock { $0.append((error as? URLError)?.code) }
    }
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {}
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {}
}

extension SharedGatewaySuite {
    @Suite(.timeLimit(.minutes(1))) struct TileGatewayTests {
        private static let host = "tiles.gateway.invalid"
        private static let templates = TileTemplates(
            basemap: "https://\(host)/osm/{z}/{x}/{y}", terrain: "https://\(host)/elevation/{z}/{x}/{y}")
        private static let userAgent = "Test/1 Maqs/0.1.0"
        /// Around Nevegal, the installed region of these tests.
        private static let regionBox = BoundingBox(minLon: 12.0, minLat: 45.9, maxLon: 12.4, maxLat: 46.2)
        /// Around Paris, far from the region: a base pack's box.
        private static let baseBox = BoundingBox(minLon: 2.0, minLat: 48.5, maxLon: 2.8, maxLat: 49.0)
        private static let inside = tile(lon: 12.20, lat: 46.07)
        private static let insideOther = tile(lon: 12.25, lat: 46.10)
        private static let outside = tile(lon: 2.35, lat: 48.85)
        private static let outsideOther = tile(lon: 2.40, lat: 48.85)

        private let server = StubServer()
        private let directory: TemporaryDirectory
        private let clock = TestClock()
        private let logged = LogRecorder()
        /// MapLibre's side: a session whose tile requests reach the gateway.
        private let session: URLSession

        init() throws {
            directory = try TemporaryDirectory()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [TileGateway.self]
            session = URLSession(configuration: configuration)
            let (clock, logged) = (clock, logged)
            GatewayState.shared.resetForTesting(now: { clock.now }, logSink: { logged.record($0) })
        }

        // MARK: Helpers

        /// The z14 tile (by default) that holds a point.
        private static func tile(_ layer: TileLayer = .basemap, z: Int = 14, lon: Double, lat: Double) -> TileRequest {
            let n = Double(1 << z)
            let latitude = lat * .pi / 180
            let x = Int((lon + 180) / 360 * n)
            let y = Int((1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2 * n)
            return TileRequest(layer: layer, z: z, x: x, y: y)
        }

        private static func url(_ tile: TileRequest) throws -> URL {
            let path = tile.layer == .basemap ? "osm" : "elevation"
            return try #require(URL(string: "https://\(host)/\(path)/\(tile.z)/\(tile.x)/\(tile.y)"))
        }

        private static func archive(_ pack: PackID, _ url: URL, layer: TileLayer = .basemap,
                                    bounds: BoundingBox) -> LocalArchive {
            LocalArchive(pack: pack, layer: layer, url: url, minZoom: 0, maxZoom: 14, bounds: bounds, dataDate: nil)
        }

        /// A table with one installed region, `test`, whose basemap is the archive at `url`.
        private static func region(_ url: URL) -> RoutingTable {
            RoutingTable(
                regions: [InstalledRegion(id: "test", bbox: regionBox,
                                          archives: [archive(.region("test"), url, bounds: regionBox)])],
                basePacks: [])
        }

        /// A table with no region and one base pack, whose basemap is the archive at `url`.
        private static func basePack(_ url: URL) -> RoutingTable {
            RoutingTable(regions: [], basePacks: [archive(.base("base-test"), url, bounds: baseBox)])
        }

        private func configure(onlineAllowed: Bool = true, sessionConfiguration: URLSessionConfiguration? = nil) {
            GatewayState.shared.configure(GatewayConfiguration(
                templates: Self.templates, onlineAllowed: onlineAllowed, userAgent: Self.userAgent,
                sessionConfiguration: sessionConfiguration ?? server.configuration))
        }

        /// Writes an archive of uncompressed tiles into the test's directory.
        private func writeArchive(_ name: String, _ tiles: [(TileRequest, Data)]) throws -> URL {
            let url = directory.url.appending(path: name)
            try PMTilesWriter.write(tiles: tiles.map { (z: $0.0.z, x: $0.0.x, y: $0.0.y, data: $0.1) }, to: url,
                                    metadata: [:])
            return url
        }

        private func get(_ tile: TileRequest, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: try Self.url(tile))
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await session.data(for: request)
            return (data, try #require(response as? HTTPURLResponse))
        }

        /// The code of the `URLError` a tile request fails with; nil, and a recorded issue, when it does not fail so.
        private func failure(_ tile: TileRequest) async throws -> URLError.Code? {
            let url = try Self.url(tile)
            let error = await #expect(throws: URLError.self) { _ = try await session.data(from: url) }
            return error?.code
        }

        private var counters: GatewayCounters { GatewayState.shared.counters }

        /// Waits until `condition` holds, polling rather than sleeping; the cancellation check lets the suite's time
        /// limit end the wait should the condition never come true.
        private static func waitUntil(_ condition: () -> Bool) async throws {
            while !condition() {
                try Task.checkCancellation()
                await Task.yield()
            }
        }

        // MARK: Installed regions

        @Test func aTileInsideAnInstalledRegionComesFromItsArchive() async throws {
            let tile = Data("region tile".utf8)
            configure()
            GatewayState.shared.setTable(Self.region(try writeArchive("region.pmtiles", [(Self.inside, tile)])))
            let (data, response) = try await get(Self.inside)
            #expect(response.statusCode == 200)
            #expect(data == tile)
            #expect(server.requests.isEmpty)
            #expect(counters.local == 1)
        }

        /// MapLibre parses the bytes it is given and does not inflate them. It caches local answers either way; with no
        /// expiry it asks the gateway again on every load, never on a timer, and still draws the cached copy offline.
        @Test func aLocalTileIsServedInflatedWithNoExpiry() async throws {
            let fixture = try Fixtures.url("test/test-basemap.v1.pmtiles")
            let tile = TileRequest(layer: .basemap, z: 14, x: 8749, y: 5822)
            let expected = try #require(try PMTilesArchive(url: fixture).tile(z: tile.z, x: tile.x, y: tile.y))
            configure()
            GatewayState.shared.setTable(Self.region(fixture))
            let (data, response) = try await get(tile)
            #expect(data == expected)
            #expect(!data.starts(with: [0x1F, 0x8B]))
            #expect(response.value(forHTTPHeaderField: "Content-Encoding") == nil)
            #expect(response.value(forHTTPHeaderField: "Cache-Control") == nil)
            #expect(response.value(forHTTPHeaderField: "Expires") == nil)
        }

        @Test func aMissingTileInsideARegionIsEmpty() async throws {
            configure()
            GatewayState.shared.setTable(
                Self.region(try writeArchive("region.pmtiles", [(Self.inside, Data("tile".utf8))])))
            let (data, response) = try await get(Self.insideOther)
            #expect(response.statusCode == 204)
            #expect(data.isEmpty)
            #expect(response.value(forHTTPHeaderField: "Cache-Control") == nil)
            #expect(response.value(forHTTPHeaderField: "Expires") == nil)
            #expect(server.requests.isEmpty)
            #expect(counters.empty == 1)
        }

        @Test func aLayerTheRegionLacksIsEmptyNeverOnline() async throws {
            configure()
            GatewayState.shared.setTable(
                Self.region(try writeArchive("region.pmtiles", [(Self.inside, Data("tile".utf8))])))
            let (_, response) = try await get(Self.tile(.terrain, z: 12, lon: 12.20, lat: 46.07))
            #expect(response.statusCode == 204)
            #expect(server.requests.isEmpty)
        }

        @Test func anUnreadableArchiveAnswersEmptyAndCountsAFailure() async throws {
            let url = directory.url.appending(path: "corrupt.pmtiles")
            try Data(repeating: 7, count: 300).write(to: url)
            configure()
            GatewayState.shared.setTable(Self.region(url))
            let (data, response) = try await get(Self.inside)
            #expect(response.statusCode == 204)
            #expect(data.isEmpty)
            #expect(server.requests.isEmpty)
            #expect(counters.failed == 1)
        }

        @Test func anUnreadableArchiveIsLoggedOnce() async throws {
            let name = "corrupt.pmtiles"
            let url = directory.url.appending(path: name)
            try Data(repeating: 7, count: 300).write(to: url)
            configure()
            GatewayState.shared.setTable(Self.region(url))
            for tile in [Self.inside, Self.insideOther, Self.inside] {
                _ = try await get(tile)
            }
            #expect(counters.failed == 3)
            #expect(logged.events == [.archiveUnreadable(file: name, error: "notPMTiles")])
        }

        /// Review Focus 3: the open descriptor keeps a removed file readable.
        @Test func anArchiveDeletedAfterItWasOpenedStillAnswers() async throws {
            let first = Data("first".utf8)
            let second = Data("second".utf8)
            let url = try writeArchive("region.pmtiles", [(Self.inside, first), (Self.insideOther, second)])
            configure()
            GatewayState.shared.setTable(Self.region(url))
            #expect(try await get(Self.inside).0 == first)
            try FileManager.default.removeItem(at: url)
            #expect(try await get(Self.insideOther).0 == second)
        }

        @Test func aTableThatNoLongerListsAnArchiveClosesIt() async throws {
            let url = try writeArchive("region.pmtiles", [(Self.inside, Data("tile".utf8))])
            configure()
            GatewayState.shared.setTable(Self.region(url))
            _ = try await get(Self.inside)
            try FileManager.default.removeItem(at: url)
            GatewayState.shared.setTable(RoutingTable(regions: [], basePacks: []))
            // Listed again: the archive must be opened anew, and the file is gone.
            GatewayState.shared.setTable(Self.region(url))
            let (_, response) = try await get(Self.inside)
            #expect(response.statusCode == 204)
            #expect(counters.failed == 1)
        }

        // MARK: Online

        @Test func aTileOutsideEveryRegionGoesOnlineWithTheAppsUserAgent() async throws {
            let body = Data("online tile".utf8)
            server.route(try Self.url(Self.outside), body: body)
            configure()
            let (data, response) = try await get(Self.outside, headers: ["If-None-Match": "\"v1\""])
            #expect(response.statusCode == 200)
            #expect(data == body)
            #expect(server.requests.count == 1)
            let sent = try #require(server.requests.first)
            #expect(sent.value(forHTTPHeaderField: "User-Agent") == Self.userAgent)
            #expect(sent.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
            #expect(sent.value(forHTTPHeaderField: "Pragma") == nil)
            #expect(sent.value(forHTTPHeaderField: "Cache-Control")?.contains("no-cache") != true)
            #expect(counters.online == 1)
        }

        /// The identifying User-Agent does not depend on what MapLibre's session was given.
        @Test func theConfiguredUserAgentReplacesTheRequestsOwn() async throws {
            server.route(try Self.url(Self.outside), body: Data("online tile".utf8))
            configure()
            _ = try await get(Self.outside, headers: ["User-Agent": "MapLibre Native/6.31.0 SomeApp/1"])
            let sent = try #require(server.requests.first)
            #expect(sent.value(forHTTPHeaderField: "User-Agent") == Self.userAgent)
        }

        /// The gateway talks only to the hosts its templates name.
        @Test func aRedirectToAnotherHostIsNotFollowed() async throws {
            let elsewhere = try #require(URL(string: "https://elsewhere.invalid/osm/14/1/1"))
            server.route(try Self.url(Self.outside), status: 302, headers: ["Location": elsewhere.absoluteString],
                         body: Data())
            server.route(elsewhere, body: Data("elsewhere".utf8))
            configure()
            let (data, response) = try await get(Self.outside)
            #expect(response.statusCode == 302)
            #expect(data.isEmpty)
            #expect(server.requests.count == 1)
            #expect(!server.requests.contains { $0.url?.host == "elsewhere.invalid" })
        }

        @Test func aRedirectOnTheSameHostIsFollowed() async throws {
            let moved = try Self.url(Self.outsideOther)
            let body = Data("moved tile".utf8)
            server.route(try Self.url(Self.outside), status: 301, headers: ["Location": moved.absoluteString],
                         body: Data())
            server.route(moved, body: body)
            configure()
            let (data, response) = try await get(Self.outside)
            #expect(response.statusCode == 200)
            #expect(data == body)
            #expect(server.requests.map(\.url) == [try Self.url(Self.outside), moved])
        }

        /// URLSession has decoded the body by the time the gateway sees it, so the headers that describe the encoded
        /// bytes would be wrong for MapLibre; the caching headers are the provider's and pass unchanged.
        @Test func anOnlineResponseKeepsItsCachingHeadersAndLosesItsEncodingOnes() async throws {
            let headers = ["Cache-Control": "max-age=21600", "ETag": "\"v2\"", "Content-Encoding": "gzip"]
            server.route(try Self.url(Self.outside), headers: headers, body: Data("online tile".utf8))
            configure()
            let (_, response) = try await get(Self.outside)
            #expect(response.value(forHTTPHeaderField: "Cache-Control") == "max-age=21600")
            #expect(response.value(forHTTPHeaderField: "ETag") == "\"v2\"")
            #expect(response.value(forHTTPHeaderField: "Content-Encoding") == nil)
            #expect(response.value(forHTTPHeaderField: "Content-Length") == nil)
        }

        @Test func anOnlineErrorStatusIsPassedBack() async throws {
            server.route(try Self.url(Self.outside), status: 404, body: Data())
            configure()
            let (_, response) = try await get(Self.outside)
            #expect(response.statusCode == 404)
            #expect(!GatewayState.shared.isPaused)
        }

        @Test func a429PausesOnlineTiles() async throws {
            server.route(try Self.url(Self.outside), status: 429, body: Data())
            configure()
            #expect(try await failure(Self.outside) == .notConnectedToInternet)
            #expect(GatewayState.shared.isPaused)
            clock.advance(by: .seconds(59))
            #expect(try await failure(Self.outsideOther) == .notConnectedToInternet)
            #expect(server.requests.count == 1)
            #expect(GatewayState.shared.isPaused)
        }

        /// A pause is logged once when it starts, and once when it ends, the first time it is seen over.
        @Test func aPauseIsLoggedWhenItStartsAndWhenItEnds() async throws {
            server.route(try Self.url(Self.outside), status: 429, body: Data())
            configure()
            _ = try await failure(Self.outside)
            #expect(logged.events == [.rateLimited, .pauseStarted(seconds: 60)])
            clock.advance(by: .seconds(61))
            #expect(!GatewayState.shared.isPaused)
            #expect(!GatewayState.shared.isPaused)
            #expect(logged.events == [.rateLimited, .pauseStarted(seconds: 60), .pauseEnded])
        }

        @Test func a429IsAnsweredFromABasePackThatCoversTheTile() async throws {
            let tile = Data("base tile".utf8)
            server.route(try Self.url(Self.outside), status: 429, body: Data())
            configure()
            GatewayState.shared.setTable(Self.basePack(try writeArchive("base.pmtiles", [(Self.outside, tile)])))
            let (data, _) = try await get(Self.outside)
            #expect(data == tile)
            #expect(GatewayState.shared.isPaused)
            #expect(counters.base == 1)
        }

        /// A tile after the pause is a success outside it, so the next pause is 60 s again.
        @Test func onlineTilesResumeWhenThePauseIsOver() async throws {
            server.route(try Self.url(Self.outside), status: 429, body: Data())
            let body = Data("online tile".utf8)
            server.route(try Self.url(Self.outsideOther), body: body)
            configure()
            _ = try await failure(Self.outside)
            clock.advance(by: .seconds(61))
            #expect(!GatewayState.shared.isPaused)
            #expect(try await get(Self.outsideOther).0 == body)
            _ = try await failure(Self.outside)
            #expect(server.requests.count == 3)
            clock.advance(by: .seconds(59))
            #expect(GatewayState.shared.isPaused)
            clock.advance(by: .seconds(2))
            #expect(!GatewayState.shared.isPaused)
        }

        /// A 200 for a request sent before the 429 came back says nothing about the server's limit now.
        @Test func aTileFromBeforeThePauseDoesNotUndoTheDoubling() async throws {
            let gate = StubGate()
            defer { gate.release() }
            let body = Data("online tile".utf8)
            server.route(try Self.url(Self.outsideOther)) { _ in StubResponse(status: 200, body: body, gate: gate) }
            server.route(try Self.url(Self.outside), status: 429, body: Data())
            configure()
            let early = Task { try await get(Self.outsideOther) }
            try await Self.waitUntil { server.requests.count == 1 }
            #expect(try await failure(Self.outside) == .notConnectedToInternet)
            gate.release()
            #expect(try await early.value.0 == body)
            clock.advance(by: .seconds(61))
            #expect(!GatewayState.shared.isPaused)
            _ = try await failure(Self.outside)
            // The second 429 starts a 120 s pause, not 60 s.
            clock.advance(by: .seconds(119))
            #expect(GatewayState.shared.isPaused)
            clock.advance(by: .seconds(2))
            #expect(!GatewayState.shared.isPaused)
        }

        @Test(arguments: [URLError.Code.cannotConnectToHost, .timedOut, .networkConnectionLost])
        func aConnectionFailureFallsBackToABasePack(_ code: URLError.Code) async throws {
            let tile = Data("base tile".utf8)
            server.route(try Self.url(Self.outside)) { _ in StubResponse(transportError: code) }
            configure()
            GatewayState.shared.setTable(Self.basePack(try writeArchive("base.pmtiles", [(Self.outside, tile)])))
            let (data, _) = try await get(Self.outside)
            #expect(data == tile)
            #expect(server.requests.count == 1)
            #expect(counters.base == 1)
        }

        /// A hotel's captive portal answers HTTPS with its own certificate or breaks the handshake: the network cannot
        /// give the tile, so a base pack answers instead of a blank tile.
        @Test(arguments: [
            URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        ])
        func aCaptivePortalOrTLSFailureFallsBackToABasePack(_ code: URLError.Code) async throws {
            let tile = Data("base tile".utf8)
            server.route(try Self.url(Self.outside)) { _ in StubResponse(transportError: code) }
            configure()
            GatewayState.shared.setTable(Self.basePack(try writeArchive("base.pmtiles", [(Self.outside, tile)])))
            let (data, _) = try await get(Self.outside)
            #expect(data == tile)
            #expect(server.requests.count == 1)
            #expect(counters.base == 1)
            #expect(counters.failed == 0)
        }

        @Test func withNoNetworkABasePackAnswers() async throws {
            let tile = Data("base tile".utf8)
            configure()
            GatewayState.shared.setTable(Self.basePack(try writeArchive("base.pmtiles", [(Self.outside, tile)])))
            GatewayState.shared.setOffline(true)
            let (data, response) = try await get(Self.outside)
            #expect(response.statusCode == 200)
            #expect(data == tile)
            #expect(response.value(forHTTPHeaderField: "Cache-Control") == nil)
            #expect(response.value(forHTTPHeaderField: "Expires") == nil)
            #expect(server.requests.isEmpty)
            #expect(counters.base == 1)
        }

        @Test func withOnlineTilesOffNothingReachesTheNetwork() async throws {
            server.route(try Self.url(Self.outside), body: Data("online tile".utf8))
            configure(onlineAllowed: false)
            #expect(try await failure(Self.outside) == .notConnectedToInternet)
            #expect(server.requests.isEmpty)
            #expect(counters.failed == 1)
        }

        // MARK: The gateway's own session

        /// The second step of an online tile, as `TileGateway` takes it; the answer the completion or the call gives.
        private static func send(_ online: OnlineTile) async -> TileAnswer {
            await withCheckedContinuation { continuation in
                let sent = GatewayState.shared.send(online) { continuation.resume(returning: $0) }
                if case .answer(let answer) = sent { continuation.resume(returning: answer) }
            }
        }

        /// The online step of a tile request, from `start`; nil, and a recorded issue, when it is not routed online.
        private static func routedOnline(_ tile: TileRequest) throws -> OnlineTile? {
            guard case .online(let online) = GatewayState.shared.start(URLRequest(url: try url(tile))) else {
                Issue.record("the tile was not routed online")
                return nil
            }
            return online
        }

        /// A runtime reconfiguration invalidates the old session. A task created on it would raise an Objective-C
        /// exception, which Swift cannot catch; the request goes out on the session current when it is sent.
        @Test func aReconfigurationBetweenRoutingAndSendingUsesTheNewSession() async throws {
            server.route(try Self.url(Self.outside), body: Data("old session".utf8))
            configure()
            let online = try #require(try Self.routedOnline(Self.outside))
            let replacement = StubServer()
            let body = Data("new session".utf8)
            replacement.route(try Self.url(Self.outside), body: body)
            configure(sessionConfiguration: replacement.configuration)
            guard case .response(let response, let data) = await Self.send(online) else {
                Issue.record("no response")
                return
            }
            #expect(response.statusCode == 200)
            #expect(data == body)
            #expect(server.requests.isEmpty)
            #expect(replacement.requests.count == 1)
        }

        @Test func aReconfigurationThatTurnsOnlineOffBeforeSendingAsksNoNetwork() async throws {
            server.route(try Self.url(Self.outside), body: Data("online tile".utf8))
            configure()
            let online = try #require(try Self.routedOnline(Self.outside))
            configure(onlineAllowed: false)
            guard case .failure(let error) = await Self.send(online) else {
                Issue.record("not a failure")
                return
            }
            #expect((error as? URLError)?.code == .notConnectedToInternet)
            #expect(server.requests.isEmpty)
        }

        @Test func theGatewaysSessionHasNoCacheAFifteenSecondTimeoutAndNoGateway() throws {
            let given = server.configuration
            given.protocolClasses = [TileGateway.self] + (given.protocolClasses ?? [])
            given.urlCache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
            given.requestCachePolicy = .returnCacheDataElseLoad
            given.timeoutIntervalForRequest = 60
            configure(sessionConfiguration: given)
            let session = try #require(GatewayState.shared.sessionConfigurationForTesting)
            #expect(session.urlCache == nil)
            #expect(session.requestCachePolicy == .reloadIgnoringLocalCacheData)
            #expect(session.timeoutIntervalForRequest == 15)
            let protocols = (session.protocolClasses ?? []).map(ObjectIdentifier.init)
            #expect(!protocols.contains(ObjectIdentifier(TileGateway.self)))
            #expect(session.httpAdditionalHeaders?["X-Maqs-Stub"] as? String == server.id)
            #expect(session.httpAdditionalHeaders?["User-Agent"] as? String == Self.userAgent)
        }

        @Test func theGatewaysOwnRequestsNeverComeBackToIt() async throws {
            let configuration = server.configuration
            configuration.protocolClasses = [TileGateway.self] + (configuration.protocolClasses ?? [])
            let body = Data("online tile".utf8)
            server.route(try Self.url(Self.outside), body: body)
            configure(sessionConfiguration: configuration)
            #expect(try await get(Self.outside).0 == body)
            #expect(server.requests.count == 1)
        }

        @Test func theSessionConfigurationGivenIsCopiedNotChanged() throws {
            let configuration = server.configuration
            let cache = URLCache(memoryCapacity: 1 << 20, diskCapacity: 0)
            configuration.urlCache = cache
            configure(sessionConfiguration: configuration)
            #expect(configuration.httpAdditionalHeaders?["User-Agent"] == nil)
            #expect(configuration.urlCache === cache)
            #expect(configuration.requestCachePolicy == .useProtocolCachePolicy)
        }

        // MARK: Which requests are the gateway's

        @Test(arguments: [
            "https://tiles.gateway.invalid/osm/23/0/0",
            "https://tiles.gateway.invalid/osm/14/16384/5850",
            "https://tiles.gateway.invalid/osm/14/8710/16384",
            "https://tiles.gateway.invalid/osm/14/-1/5850",
            "https://tiles.gateway.invalid/osm/14/8710/-1",
            "https://tiles.gateway.invalid/osm/14/1.5/5850",
            "https://tiles.gateway.invalid/osm/14/a/5850",
            "https://tiles.gateway.invalid/osm/14/8710/5850/extra",
            "https://tiles.gateway.invalid/osm/14/8710/5850?x=1",
            "https://other.invalid/osm/14/8710/5850",
            "http://tiles.gateway.invalid/osm/14/8710/5850",
        ])
        func malformedTileURLsAreNotOurs(_ string: String) throws {
            configure()
            let url = try #require(URL(string: string))
            #expect(!TileGateway.canInit(with: URLRequest(url: url)))
        }

        @Test func aTileOfTheTemplatesIsOursOnceConfigured() throws {
            let request = URLRequest(url: try Self.url(Self.inside))
            #expect(!TileGateway.canInit(with: request))
            configure()
            #expect(TileGateway.canInit(with: request))
        }

        /// Accepted while its URL was a terrain tile, started after the templates lost their terrain: nothing current
        /// can fetch it and no base pack holds terrain, so it fails as not connected and is counted as a stale template.
        @Test func aRetiredTileWhoseLayerHasNoTemplateNowFailsAsNotConnected() throws {
            configure()
            let request = URLRequest(url: try Self.url(Self.tile(.terrain, z: 12, lon: 2.35, lat: 48.85)))
            #expect(TileGateway.canInit(with: request))
            reconfigure(TileTemplates(basemap: "https://\(Self.nextHost)/osm/{z}/{x}/{y}", terrain: nil))
            let client = RecordingClient()
            let gateway = TileGateway(request: request, cachedResponse: nil, client: client)
            gateway.startLoading()
            #expect(client.failureCodes == [.notConnectedToInternet])
            #expect(client.responseCount == 0)
            #expect(server.requests.isEmpty)
            #expect(counters.passedThrough == 1)
        }

        // MARK: Retired templates

        /// The host of the templates the tests below reconfigure to; the old ones stay retired, still claimed.
        private static let nextHost = "tiles.next.invalid"
        private static let nextTemplates = TileTemplates(
            basemap: "https://\(nextHost)/osm/{z}/{x}/{y}", terrain: "https://\(nextHost)/elevation/{z}/{x}/{y}")

        private func reconfigure(_ templates: TileTemplates) {
            GatewayState.shared.configure(GatewayConfiguration(
                templates: templates, onlineAllowed: true, userAgent: Self.userAgent,
                sessionConfiguration: server.configuration))
        }

        private static func nextURL(_ tile: TileRequest) throws -> URL {
            try #require(URL(string: "https://\(nextHost)/osm/\(tile.z)/\(tile.x)/\(tile.y)"))
        }

        /// A style of this process may still name the templates the gateway had before: their tiles stay its own.
        @Test func aTileOfARetiredTemplateIsStillClaimedAndAnsweredLocally() async throws {
            let tile = Data("region tile".utf8)
            configure()
            GatewayState.shared.setTable(Self.region(try writeArchive("region.pmtiles", [(Self.inside, tile)])))
            reconfigure(Self.nextTemplates)
            #expect(TileGateway.canInit(with: URLRequest(url: try Self.url(Self.inside))))
            let (data, response) = try await get(Self.inside)
            #expect(response.statusCode == 200)
            #expect(data == tile)
            #expect(server.requests.isEmpty)
            #expect(counters.local == 1)
        }

        /// Online, a retired template's tile is fetched from the current template, without the old URL's validators.
        @Test func aTileOfARetiredTemplateGoesOnlineThroughTheCurrentTemplate() async throws {
            configure()
            reconfigure(Self.nextTemplates)
            let current = try Self.nextURL(Self.outside)
            let body = Data("current provider".utf8)
            server.route(current, body: body)
            let (data, response) = try await get(Self.outside, headers: ["If-None-Match": "\"old\""])
            #expect(response.statusCode == 200)
            #expect(data == body)
            #expect(response.url == (try Self.url(Self.outside)))
            #expect(server.requests.map(\.url) == [current])
            #expect(server.requests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
            #expect(server.requests.first?.value(forHTTPHeaderField: "User-Agent") == Self.userAgent)
            #expect(counters.online == 1)
        }

        @Test func aTileOfARetiredTemplateAsksNoNetworkWhileOffline() async throws {
            configure()
            reconfigure(Self.nextTemplates)
            GatewayState.shared.setOffline(true)
            #expect(try await failure(Self.outside) == .notConnectedToInternet)
            #expect(server.requests.isEmpty)
        }
    }
}
