import Foundation
import Testing

@testable import MaqsUI

@Suite struct TileTemplatesTests {
    private let versatiles = TileTemplates(
        basemap: "https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}",
        terrain: "https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}")
    private let withLandcover = TileTemplates(
        basemap: "https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}",
        terrain: "https://tiles.versatiles.org/tiles/elevation/{z}/{x}/{y}",
        landcover: "https://tiles.versatiles.org/tiles/landcover-vector/{z}/{x}/{y}")
    private let reserved = TileTemplates(
        basemap: "https://maqs.invalid/basemap/{z}/{x}/{y}",
        terrain: "https://maqs.invalid/terrain/{z}/{x}/{y}")

    private func request(_ templates: TileTemplates, _ string: String) -> TileRequest? {
        URL(string: string).flatMap { templates.request(for: $0) }
    }

    @Test func parsesTheVersaTilesTemplates() {
        #expect(request(versatiles, "https://tiles.versatiles.org/tiles/osm/14/8710/5850")
            == TileRequest(layer: .basemap, z: 14, x: 8710, y: 5850))
        #expect(request(versatiles, "https://tiles.versatiles.org/tiles/elevation/12/2177/1462")
            == TileRequest(layer: .terrain, z: 12, x: 2177, y: 1462))
    }

    @Test func parsesTheLandcoverTemplateAndMakesItsURL() throws {
        let tile = TileRequest(layer: .landcover, z: 10, x: 546, y: 363)
        #expect(request(withLandcover, "https://tiles.versatiles.org/tiles/landcover-vector/10/546/363") == tile)
        #expect(withLandcover.url(for: tile)?.absoluteString
            == "https://tiles.versatiles.org/tiles/landcover-vector/10/546/363")
        #expect(request(versatiles, "https://tiles.versatiles.org/tiles/landcover-vector/10/546/363") == nil)
        #expect(versatiles.url(for: tile) == nil)
    }

    /// A reserved template names a tile the gateway serves from an installed pack; it never becomes a request.
    @Test func aReservedTemplateNeverMakesAnOnlineURL() {
        let landcover = TileTemplates(basemap: "https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}", terrain: nil,
                                      landcover: "https://maqs.invalid/landcover/{z}/{x}/{y}")
        #expect(request(landcover, "https://maqs.invalid/landcover/3/4/2") == TileRequest(layer: .landcover, z: 3, x: 4, y: 2))
        #expect(landcover.url(for: TileRequest(layer: .landcover, z: 3, x: 4, y: 2)) == nil)
        #expect(reserved.url(for: TileRequest(layer: .basemap, z: 3, x: 4, y: 2)) == nil)
    }

    @Test func parsesTheReservedTemplates() {
        #expect(request(reserved, "https://maqs.invalid/basemap/14/8710/5850")
            == TileRequest(layer: .basemap, z: 14, x: 8710, y: 5850))
        #expect(request(reserved, "https://maqs.invalid/terrain/0/0/0")
            == TileRequest(layer: .terrain, z: 0, x: 0, y: 0))
    }

    @Test func parsesATemplateWithTheCoordinatesInAnotherOrder() {
        let templates = TileTemplates(basemap: "https://example.test/t/{x}-{y}/{z}.pbf", terrain: nil)
        #expect(request(templates, "https://example.test/t/8710-5850/14.pbf")
            == TileRequest(layer: .basemap, z: 14, x: 8710, y: 5850))
    }

    @Test func aMissingTerrainTemplateMatchesNothingForTerrain() {
        let templates = TileTemplates(basemap: versatiles.basemap, terrain: nil)
        #expect(request(templates, "https://tiles.versatiles.org/tiles/elevation/12/2177/1462") == nil)
    }

    @Test(arguments: [
        "https://tiles.versatiles.org/tiles/osm/23/0/0",
        "https://tiles.versatiles.org/tiles/osm/14/16384/5850",
        "https://tiles.versatiles.org/tiles/osm/14/8710/16384",
        "https://tiles.versatiles.org/tiles/osm/1/2/0",
        "https://tiles.versatiles.org/tiles/osm/14/-1/5850",
        "https://tiles.versatiles.org/tiles/osm/14/8710/-1",
        "https://tiles.versatiles.org/tiles/osm/14/1.5/5850",
        "https://tiles.versatiles.org/tiles/osm/14/a/5850",
        "https://tiles.versatiles.org/tiles/osm/14/+5/5850",
        "https://tiles.versatiles.org/tiles/osm/14/%38710/5850",
        "https://tiles.versatiles.org/tiles/osm/14/99999999999999999999/5850",
        "https://tiles.versatiles.org/tiles/osm/14/8710/5850/extra",
        "https://tiles.versatiles.org/tiles/osm/14/8710",
        "https://tiles.versatiles.org/tiles/osm/14/8710/5850/",
        "https://tiles.versatiles.org/tiles/osm/14/8710/5850?x=1",
        "https://tiles.versatiles.org/tiles/osm/14/8710/5850#top",
        "https://other.example/tiles/osm/14/8710/5850",
        "http://tiles.versatiles.org/tiles/osm/14/8710/5850",
        "https://tiles.versatiles.org:8443/tiles/osm/14/8710/5850",
        "https://tiles.versatiles.org/tiles/other/14/8710/5850",
        "file:///tiles/osm/14/8710/5850",
    ])
    func rejectsAnythingElse(_ string: String) {
        #expect(request(versatiles, string) == nil)
    }

    @Test func acceptsTheLargestTileOfZoomTwentyTwo() {
        #expect(request(versatiles, "https://tiles.versatiles.org/tiles/osm/22/4194303/4194303")
            == TileRequest(layer: .basemap, z: 22, x: 4194303, y: 4194303))
    }
}
