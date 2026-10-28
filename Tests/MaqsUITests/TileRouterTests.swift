import Foundation
import MaqsCore
import Testing

@testable import MaqsUI

@Suite struct TileRouterTests {
    // Nevegal is at about 12.20 E, 46.07 N.
    private static let nevegal = (lon: 12.20, lat: 46.07)
    private static let box = BoundingBox(minLon: 12.0, minLat: 45.9, maxLon: 12.4, maxLat: 46.2)

    private func tile(_ layer: TileLayer = .basemap, z: Int, lon: Double, lat: Double) -> TileRequest {
        let n = Double(1 << z)
        let x = Int((lon + 180) / 360 * n)
        let latRad = lat * .pi / 180
        let y = Int((1 - log(tan(latRad) + 1 / cos(latRad)) / .pi) / 2 * n)
        return TileRequest(layer: layer, z: z, x: x, y: y)
    }

    private func archive(
        _ pack: PackID, _ layer: TileLayer = .basemap, name: String, zooms: ClosedRange<Int> = 0...14,
        bounds: BoundingBox = box, date: Date? = nil
    ) -> LocalArchive {
        LocalArchive(
            pack: pack, layer: layer, url: URL(fileURLWithPath: "/packs/\(name).pmtiles"),
            minZoom: zooms.lowerBound, maxZoom: zooms.upperBound, bounds: bounds, dataDate: date)
    }

    private func region(_ id: String, bbox: BoundingBox = box, _ archives: [LocalArchive]) -> InstalledRegion {
        InstalledRegion(id: id, bbox: bbox, archives: archives)
    }

    private func url(_ route: Route) -> String? {
        if case .local(let url) = route { return url.lastPathComponent }
        return nil
    }

    private let inside = (lon: 12.20, lat: 46.07)

    @Test func insideOneRegionRoutesToItsArchive() {
        let table = RoutingTable(
            regions: [region("veneto", [archive(.region("veneto"), name: "veneto-basemap")])], basePacks: [])
        let route = TileRouter.route(tile(z: 14, lon: inside.lon, lat: inside.lat), in: table)
        #expect(url(route) == "veneto-basemap.pmtiles")
    }

    @Test func outsideEveryRegionIsOnline() {
        let table = RoutingTable(
            regions: [region("veneto", [archive(.region("veneto"), name: "veneto-basemap")])], basePacks: [])
        #expect(TileRouter.route(tile(z: 14, lon: 2.35, lat: 48.85), in: table) == .online)
        #expect(TileRouter.route(tile(z: 14, lon: inside.lon, lat: inside.lat), in: RoutingTable(regions: [], basePacks: [])) == .online)
    }

    @Test func overlappingRegionsPreferTheHigherMaxZoom() {
        let table = RoutingTable(
            regions: [
                region("triveneto", [archive(.region("triveneto"), name: "low", zooms: 0...12)]),
                region("veneto", [archive(.region("veneto"), name: "high", zooms: 0...14)]),
            ], basePacks: [])
        #expect(url(TileRouter.route(tile(z: 10, lon: inside.lon, lat: inside.lat), in: table)) == "high.pmtiles")
    }

    @Test func equalMaxZoomPrefersTheNewerDataDate() {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let table = RoutingTable(
            regions: [
                region("aaa", [archive(.region("aaa"), name: "old", date: old)]),
                region("zzz", [archive(.region("zzz"), name: "new", date: new)]),
            ], basePacks: [])
        #expect(url(TileRouter.route(tile(z: 10, lon: inside.lon, lat: inside.lat), in: table)) == "new.pmtiles")
    }

    @Test func aDatedArchiveBeatsAnUndatedOne() {
        let table = RoutingTable(
            regions: [
                region("aaa", [archive(.region("aaa"), name: "undated")]),
                region("zzz", [archive(.region("zzz"), name: "dated", date: Date(timeIntervalSince1970: 1))]),
            ], basePacks: [])
        #expect(url(TileRouter.route(tile(z: 10, lon: inside.lon, lat: inside.lat), in: table)) == "dated.pmtiles")
    }

    @Test func otherwiseTheSmallerRegionIdWins() {
        let table = RoutingTable(
            regions: [
                region("veneto", [archive(.region("veneto"), name: "veneto")]),
                region("triveneto", [archive(.region("triveneto"), name: "triveneto")]),
            ], basePacks: [])
        #expect(url(TileRouter.route(tile(z: 10, lon: inside.lon, lat: inside.lat), in: table)) == "triveneto.pmtiles")
    }

    @Test func insideARegionWithoutTerrainTheTerrainTileIsEmpty() {
        let table = RoutingTable(
            regions: [region("veneto", [archive(.region("veneto"), name: "veneto-basemap")])], basePacks: [])
        let route = TileRouter.route(tile(.terrain, z: 10, lon: inside.lon, lat: inside.lat), in: table)
        #expect(route == .empty)
    }

    @Test func aZoomAboveTheArchiveRangeInsideItsRegionIsEmpty() {
        let table = RoutingTable(
            regions: [region("veneto", [archive(.region("veneto"), name: "v", zooms: 0...12)])], basePacks: [])
        #expect(TileRouter.route(tile(z: 13, lon: inside.lon, lat: inside.lat), in: table) == .empty)
    }

    @Test func aZoomBelowTheArchiveRangeInsideItsRegionIsEmpty() {
        let table = RoutingTable(
            regions: [region("veneto", [archive(.region("veneto"), name: "v", zooms: 5...12)])], basePacks: [])
        #expect(TileRouter.route(tile(z: 3, lon: inside.lon, lat: inside.lat), in: table) == .empty)
    }

    @Test func aTileTouchingTheRegionEdgeCountsAsCovered() {
        // The tile at z 1 with x 1, y 0 spans lon 0...180 and lat 0...85.05.
        let touching = BoundingBox(minLon: -10, minLat: 10, maxLon: 0, maxLat: 20)
        let table = RoutingTable(
            regions: [region("edge", bbox: touching, [archive(.region("edge"), name: "edge", bounds: touching)])],
            basePacks: [])
        // x 1 starts at lon 0, exactly the region's east edge.
        let route = TileRouter.route(TileRequest(layer: .basemap, z: 1, x: 1, y: 0), in: table)
        #expect(url(route) == "edge.pmtiles")
    }

    @Test func aRegionWithoutTheLayerCoversByItsBbox() {
        let table = RoutingTable(
            regions: [region("veneto", [archive(.region("veneto"), name: "v")])], basePacks: [])
        // Terrain tile inside the bbox: the region is the authority, nothing local answers.
        #expect(TileRouter.route(tile(.terrain, z: 8, lon: 12.2, lat: 46.0), in: table) == .empty)
        // A terrain tile well outside is online.
        #expect(TileRouter.route(tile(.terrain, z: 8, lon: 30, lat: 10), in: table) == .online)
    }

    @Test func anArchiveCoversByItsOwnBoundsNotTheRegionBbox() {
        let narrow = BoundingBox(minLon: 12.0, minLat: 45.9, maxLon: 12.1, maxLat: 46.2)
        let table = RoutingTable(
            regions: [region("veneto", [archive(.region("veneto"), name: "v", bounds: narrow)])], basePacks: [])
        #expect(TileRouter.route(tile(z: 14, lon: 12.35, lat: 46.0), in: table) == .online)
    }

    @Test func theFallbackPicksABasePackWithinItsZoomRange() {
        let base = archive(.base("triveneto"), name: "base", zooms: 0...6)
        let table = RoutingTable(regions: [], basePacks: [base])
        let low = tile(z: 6, lon: inside.lon, lat: inside.lat)
        #expect(TileRouter.fallback(low, in: table) == .local(base.url))
        #expect(TileRouter.fallback(tile(z: 7, lon: inside.lon, lat: inside.lat), in: table) == .unavailable)
    }

    @Test func theFallbackIsUnavailableOutsideTheBasePackBoundsOrForAnotherLayer() {
        let base = archive(.base("triveneto"), name: "base", zooms: 0...6)
        let table = RoutingTable(regions: [], basePacks: [base])
        #expect(TileRouter.fallback(tile(z: 5, lon: 2.35, lat: 48.85), in: table) == .unavailable)
        #expect(TileRouter.fallback(tile(.terrain, z: 5, lon: inside.lon, lat: inside.lat), in: table) == .unavailable)
    }

    @Test func theFallbackPrefersTheHigherMaxZoomThenTheNewerBasePack() {
        let a = archive(.base("a"), name: "a", zooms: 0...5)
        let b = archive(.base("b"), name: "b", zooms: 0...7)
        let table = RoutingTable(regions: [], basePacks: [a, b])
        #expect(TileRouter.fallback(tile(z: 5, lon: inside.lon, lat: inside.lat), in: table) == .local(b.url))
    }

    @Test func anInvertedZoomRangeNeverMatchesAndNeverTraps() {
        let inverted = archive(.region("veneto"), name: "bad", zooms: 0...14)
        var broken = inverted
        broken.minZoom = 12
        broken.maxZoom = 3
        let request = tile(z: 8, lon: inside.lon, lat: inside.lat)
        let regions = RoutingTable(regions: [region("veneto", [broken])], basePacks: [])
        #expect(TileRouter.route(request, in: regions) == .empty)
        let base = RoutingTable(regions: [], basePacks: [broken])
        #expect(TileRouter.fallback(request, in: base) == .unavailable)
    }
}
