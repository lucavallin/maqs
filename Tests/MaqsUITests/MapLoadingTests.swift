#if canImport(MapLibre)
import CoreLocation
import Foundation
import MapLibre
import MaqsTestSupport
import Testing
import UIKit

@testable import MaqsCore
@testable import MaqsUI

extension SharedGatewaySuite {
    /// `MaqsMap` and `MaqsMapView` with real MapLibre views in a window, over the `test` region's fixtures. Every request
    /// the map's gateway sends goes to a stub server; every other request of MapLibre's session lands on the tripwire.
    @MainActor @Suite(.timeLimit(.minutes(1))) struct MapLoadingTests {
        private let server = StubServer()
        private let directory: TemporaryDirectory

        init() throws {
            directory = try TemporaryDirectory()
            GatewayState.shared.resetForTesting()
            NetworkTripwire.reset()
        }

        /// The gateway talks to the stub server; the device reports `connectivity` and nothing else.
        private func seams(_ connectivity: Connectivity = .online) -> MapSeams {
            MapSeams(
                gatewaySession: server.configuration,
                connectivity: { AsyncStream { $0.yield(connectivity) } },
                gatewayReadInterval: .milliseconds(20))
        }

        private var counters: GatewayCounters { GatewayState.shared.counters }

        /// A tile's URL under a `sources.json` template.
        private func tileURL(_ template: String, z: Int, x: Int, y: Int) throws -> URL {
            try #require(URL(string: template.replacingOccurrences(of: "{z}", with: String(z))
                .replacingOccurrences(of: "{x}", with: String(x)).replacingOccurrences(of: "{y}", with: String(y))))
        }

        /// The ids of the `maqs-` sources an installed region added to the loaded style.
        private func regionSources(_ host: MapHost, _ region: String) -> [String] {
            (host.mapView.style?.sources ?? []).map(\.identifier)
                .filter { $0.hasPrefix("maqs-") && $0.hasSuffix("-\(region)") }.sorted()
        }

        @Test func aMapWithoutTheBasemapLayerIsRejected() throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.terrain, .trails], in: directory)
            #expect(throws: MapError.basemapNotConfigured) { _ = try MaqsMap(maqs: maqs) }
        }

        @Test func mapLibresSessionAsksTheGatewayFirstWithTheAppsUserAgent() throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap], in: directory)
            _ = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            let configuration: URLSessionConfiguration = MLNNetworkConfiguration.sharedManager.sessionConfiguration
            let first: AnyClass = try #require(configuration.protocolClasses?.first)
            #expect(ObjectIdentifier(first) == ObjectIdentifier(TileGateway.self))
            #expect(configuration.httpAdditionalHeaders?["User-Agent"] as? String == maqs.configuration.fullUserAgent)
        }

        @Test func insideTheInstalledTestRegionTheMapMakesNoNetworkRequest() async throws {
            let maqs = try await TestRegion.install(
                on: server, layers: [.basemap, .terrain, .trails, .places], in: directory)
            try TestRegion.failEveryRequest(on: server)
            let requestsAfterInstall = server.requests.count
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            map.overlays = MapOverlays(trails: true, places: nil)
            let host = try await MapHost.show(map)
            defer { host.close() }
            host.mapView.setCenter(TestRegion.center, zoomLevel: 13, animated: false)

            try await waitUntil { map.gatewayCounters.local > 0 }
            try await host.waitUntilDrawn()

            #expect(regionSources(host, "test") == ["maqs-places-test", "maqs-trails-test"])
            #expect(host.coordinator.renderedFully)
            #expect(!host.mapView.visibleFeatures(in: host.mapView.bounds).isEmpty)
            #expect(counters.local > 0)
            #expect(counters.online == 0 && counters.passedThrough == 0 && counters.base == 0)
            #expect(server.requests.count == requestsAfterInstall)
            #expect(NetworkTripwire.requests.isEmpty)
            #expect(map.lastError == nil)
        }

        @Test func offlineAtFirstLaunchWithNothingInstalledTheMapLoadsAndAsksForNothing() async throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap, .terrain], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams(.offline))
            let host = try await MapHost.show(map)
            defer { host.close() }

            // MapLibre keeps retrying tiles that fail, so the map never becomes idle here: wait for the gateway instead.
            try await host.waitForStyle { $0.source(withIdentifier: "basemap") != nil }
            try await waitUntil { map.gatewayCounters.failed > 0 }
            #expect(map.lastError == nil)
            #expect(map.connectivity == .offline)
            #expect(server.requests.isEmpty)
            #expect(NetworkTripwire.requests.isEmpty)
            #expect(counters.online == 0 && counters.local == 0)

            try await maqs.registerBundledBasePack(
                id: "triveneto", basemap: try Fixtures.url("test/test-basemap.v1.pmtiles"))
            try await waitUntil { !map.routingTable.basePacks.isEmpty }
            host.mapView.setCenter(TestRegion.center, zoomLevel: 9, animated: false)
            try await waitUntil { map.gatewayCounters.base > 0 }
            #expect(server.requests.isEmpty)
            #expect(NetworkTripwire.requests.isEmpty)
            #expect(map.lastError == nil)
        }

        @Test func installingAPackWhileTheMapShowsChangesItsSources() async throws {
            try Fixtures.serveRelease(on: server)
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap, .trails], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            let host = try await MapHost.show(map)
            defer { host.close() }
            try await host.waitForStyle { $0.source(withIdentifier: "basemap") != nil }
            let view = ObjectIdentifier(host.mapView)
            #expect(regionSources(host, "test").isEmpty)

            _ = try await maqs.refreshCatalog()
            try await maqs.install(TestRegion.id)

            try await host.waitForStyle { $0.source(withIdentifier: "maqs-trails-test") != nil }
            #expect(ObjectIdentifier(host.mapView) == view)
            #expect(map.routingTable.regions.map(\.id) == ["test"])
        }

        @Test func removingAPackDropsItsOverlayAndItsTiles() async throws {
            let maqs = try await TestRegion.install(on: server, layers: [.basemap, .trails, .places], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            map.overlays = MapOverlays(trails: true, places: nil)
            let host = try await MapHost.show(map)
            defer { host.close() }
            host.mapView.setCenter(TestRegion.center, zoomLevel: 13, animated: false)
            try await waitUntil { map.gatewayCounters.local > 0 }
            try await host.waitForStyle { $0.source(withIdentifier: "maqs-trails-test") != nil }
            #expect(regionSources(host, "test") == ["maqs-places-test", "maqs-trails-test"])

            try await maqs.remove(TestRegion.id)

            try await host.waitForStyle { style in
                !style.sources.contains { $0.identifier.hasPrefix("maqs-") && $0.identifier.hasSuffix("-test") }
            }
            #expect(map.routingTable.regions.isEmpty)
            host.mapView.setCenter(TestRegion.center, zoomLevel: 14, animated: false)
            // Each answer changes the counters, so the stub's requests are looked at again after every one: the next
            // z14 tile of the old box goes to the provider, through the stub.
            let template = try #require(await maqs.onlineSources?.basemap.first?.tiles)
            var oldBox: Set<URL> = []
            for x in 8747...8751 {
                for y in 5820...5823 { oldBox.insert(try tileURL(template, z: 14, x: x, y: y)) }
            }
            let server = server
            try await waitUntil {
                _ = map.gatewayCounters
                return server.requests.contains { $0.url.map(oldBox.contains) == true }
            }
            #expect(map.gatewayCounters.online > 0)
        }

        /// Hillshade is one map's choice, the gateway every map's: a second map without hillshade leaves the terrain
        /// tiles of the first one claimed, so they never reach the network unclaimed.
        @Test func aSecondMapWithoutHillshadeLeavesTheTerrainTilesClaimed() async throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap, .terrain], in: directory)
            let shown = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            let host = try await MapHost.show(shown)
            defer { host.close() }
            try await host.waitForStyle { $0.source(withIdentifier: "terrain") != nil }
            let template = try #require(await maqs.onlineSources?.terrain.first?.tiles)
            let terrainTile = URLRequest(url: try tileURL(template, z: 12, x: 2187, y: 1455))
            #expect(TileGateway.canInit(with: terrainTile))

            let second = try MaqsMap(maqs: maqs, configuration: MapConfiguration(showsHillshade: false), seams: seams())
            try await waitUntil { second.styles != nil }

            let light = try #require(second.styles?.light)
            let style = try #require(try JSONSerialization.jsonObject(with: Data(light.utf8)) as? [String: Any])
            #expect((style["sources"] as? [String: Any])?["terrain"] == nil)
            #expect(TileGateway.canInit(with: terrainTile))
        }

        @Test func aRateLimitedTilePausesOnlineTilesAndTheMapSaysSo() async throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            try await waitUntil { map.styles != nil }
            let template = try #require(await maqs.onlineSources?.basemap.first?.tiles)
            let url = try #require(URL(string: template
                .replacingOccurrences(of: "{z}", with: "14").replacingOccurrences(of: "{x}", with: "8749")
                .replacingOccurrences(of: "{y}", with: "5822")))
            server.route(url) { _ in StubResponse(status: 429) }
            #expect(!map.onlineTilesPaused)

            let mapLibre = URLSessionConfiguration.ephemeral
            mapLibre.protocolClasses = [TileGateway.self]
            await #expect(throws: URLError.self) { _ = try await URLSession(configuration: mapLibre).data(from: url) }

            try await waitUntil { map.onlineTilesPaused }
            #expect(GatewayState.shared.isPaused)
        }

        @Test func anInvalidCustomStyleIsReportedAndThePreviousStyleStays() async throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            try await waitUntil { map.styles != nil }
            let styles = map.styles

            map.configuration.style = .custom(light: Data(#"{"version":8,"sources":{},"layers":[]}"#.utf8), dark: nil)

            try await waitUntil { map.lastError != nil }
            #expect(map.lastError == .invalidStyle("the style has no \"basemap\" source"))
            #expect(map.styles == styles)
        }

        /// MapLibre's parser fails only on JSON it cannot read, which the assembler never writes; the coordinator is
        /// handed some directly. MapLibre keeps drawing the old style but drops its `MLNStyle`, so the coordinator loads
        /// the last good style again, and never hands over the failed JSON a second time.
        @Test func aStyleMapLibreCannotParseIsReportedAndTheLoadedStyleComesBack() async throws {
            let maqs = try TestRegion.maqs(on: server, layers: [.basemap], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            let host = try await MapHost.show(map)
            defer { host.close() }
            try await host.waitForStyle { $0.source(withIdentifier: "basemap") != nil }
            let coordinator = host.coordinator
            let loaded = coordinator.loadedStyle
            let loads = coordinator.styleLoads

            coordinator.apply("{", dark: false)

            try await waitUntil { coordinator.styleLoads > loads }
            #expect(map.lastError == .styleFailedToLoad)
            #expect(coordinator.loadedStyle == loaded)
            #expect(host.mapView.style?.source(withIdentifier: "basemap") != nil)
            let reloads = coordinator.styleLoads
            coordinator.apply("{", dark: false)
            #expect(coordinator.styleLoads == reloads)
            #expect(host.mapView.style?.source(withIdentifier: "basemap") != nil)
        }

        /// The app's style can be invalid for a while; the packs are still followed, from the last base style that
        /// built, so a removed pack's overlay never stays in the style pointing at a deleted file.
        @Test func whileTheAppsStyleIsInvalidARemovedPacksOverlayStillGoes() async throws {
            let maqs = try await TestRegion.install(on: server, layers: [.basemap, .trails], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            try await waitUntil { map.styles?.light.contains("maqs-trails-test") == true }
            map.configuration.style = .custom(light: Data(#"{"version":8,"sources":{},"layers":[]}"#.utf8), dark: nil)
            #expect(map.lastError == .invalidStyle("the style has no \"basemap\" source"))

            try await maqs.remove(TestRegion.id)

            try await waitUntil { map.routingTable.regions.isEmpty }
            #expect(map.styles?.light.contains("maqs-trails-test") == false)
            #expect(map.styles?.dark.contains("maqs-trails-test") == false)
            #expect(map.lastError == .invalidStyle("the style has no \"basemap\" source"))
        }

        /// A region's box comes from the catalog, so a new catalog can move it; no pack changes for that.
        @Test func aCatalogChangeUpdatesTheInstalledRegionsBox() async throws {
            let maqs = try await TestRegion.install(on: server, layers: [.basemap], in: directory)
            let map = try MaqsMap(maqs: maqs, configuration: MapConfiguration(), seams: seams())
            try await waitUntil { !map.routingTable.regions.isEmpty }
            #expect(map.routingTable.regions.first?.bbox
                == BoundingBox(minLon: 12.21, minLat: 46.08, maxLon: 12.29, maxLat: 46.13))
            let wider = BoundingBox(minLon: 12.0, minLat: 46.0, maxLon: 12.5, maxLat: 46.3)
            let manifest = try Fixtures.manifestJSON { object in
                var regions = object["regions"] as? [[String: Any]] ?? []
                regions[0]["bbox"] = [wider.minLon, wider.minLat, wider.maxLon, wider.maxLat]
                object["regions"] = regions
            }
            server.route(Fixtures.manifestURL, headers: ["Content-Type": "application/json"], body: manifest)

            _ = try await maqs.refreshCatalog(policy: .always)

            try await waitUntil { map.routingTable.regions.first?.bbox == wider }
        }
    }
}
#endif
