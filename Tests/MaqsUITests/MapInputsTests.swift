import Foundation
import MaqsTestSupport
import Testing

@testable import MaqsCore
@testable import MaqsUI

@Suite struct MapInputsTests {
    private static let sources = OnlineSources(
        version: 1,
        basemap: [
            TileSource(id: "osm", provider: "P", tiles: "https://tiles.example/osm/{z}/{x}/{y}",
                       tilejson: URL(filePath: "/osm.json"), schema: "shortbread-1.0", format: "mvt", tileSize: nil,
                       minZoom: 0, maxZoom: 14, attribution: ["© OSM"]),
            TileSource(id: "second", provider: "Q", tiles: "https://other.example/{z}/{x}/{y}",
                       tilejson: URL(filePath: "/q.json"), schema: "shortbread-1.0", format: "mvt", tileSize: nil,
                       minZoom: 0, maxZoom: 12, attribution: []),
        ],
        terrain: [
            TileSource(id: "dem", provider: "P", tiles: "https://tiles.example/elevation/{z}/{x}/{y}",
                       tilejson: URL(filePath: "/dem.json"), schema: "terrarium", format: "webp", tileSize: 512,
                       minZoom: 0, maxZoom: 12, attribution: ["© DEM"]),
        ])

    private static let box = BoundingBox(minLon: 12.21, minLat: 46.08, maxLon: 12.29, maxLat: 46.13)
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func file(_ name: String, role: String? = nil) -> InstalledFile {
        InstalledFile(url: URL(filePath: "/packs/\(name)"), role: role, schemaVersion: 1, sha256: nil, bytes: 1,
                      dataDate: Self.date)
    }

    private var region: InstalledPack {
        InstalledPack(id: .region("test"), release: "data-ci", files: [
            .basemap: [file("test-basemap.v1.pmtiles")],
            .terrain: [file("test-terrain.v1.pmtiles")],
            .trails: [file("test-trails.v1.sqlite"), file("test-trails.v1.pmtiles", role: "overlay")],
            .places: [file("test-places.v1.sqlite"), file("test-places.v1.pmtiles", role: "overlay")],
            .curvature: [file("test-curvature.v1.sqlite")],
        ], bundled: false)
    }

    private var base: InstalledPack {
        InstalledPack(id: .base("triveneto"), release: "bundled", files: [.basemap: [file("base.pmtiles")]], bundled: true)
    }

    private func info(_ name: String, minZoom: Int = 0, maxZoom: Int = 14) -> (URL, ArchiveInfo) {
        (URL(filePath: "/packs/\(name)"), ArchiveInfo(minZoom: minZoom, maxZoom: maxZoom, bounds: Self.box))
    }

    private var infos: [URL: ArchiveInfo] {
        Dictionary(uniqueKeysWithValues: [
            info("test-basemap.v1.pmtiles"), info("test-terrain.v1.pmtiles", maxZoom: 12), info("base.pmtiles", maxZoom: 9),
        ])
    }

    private func catalog() throws -> Catalog {
        let manifest = try Manifest.decode(try Fixtures.manifestData(), manifestHost: "github.com")
        return CatalogBuilder.build(manifest: manifest, fetchedAt: Date(timeIntervalSince1970: 0), layers: [.basemap],
                                    installed: [:])
    }

    // MARK: Templates

    @Test func theFirstOnlineSourcesFeedTheStyleAndTheGateway() {
        let templates = MapInputs.templates(sources: Self.sources, layers: [.basemap, .terrain], showsHillshade: true)
        #expect(templates.basemap == TileTemplate(template: "https://tiles.example/osm/{z}/{x}/{y}", minZoom: 0,
                                                  maxZoom: 14, tileSize: nil, attribution: ["© OSM"]))
        #expect(templates.terrain == TileTemplate(template: "https://tiles.example/elevation/{z}/{x}/{y}", minZoom: 0,
                                                  maxZoom: 12, tileSize: 512, attribution: ["© DEM"]))
        #expect(templates.onlineAllowed)
        #expect(templates.gateway == TileTemplates(basemap: "https://tiles.example/osm/{z}/{x}/{y}",
                                                   terrain: "https://tiles.example/elevation/{z}/{x}/{y}"))
    }

    @Test func hillshadeIsAbsentWithoutTheTerrainLayer() {
        let templates = MapInputs.templates(sources: Self.sources, layers: [.basemap, .trails], showsHillshade: true)
        #expect(templates.terrain == nil)
        #expect(templates.gateway.terrain == nil)
    }

    @Test func hillshadeIsAbsentWhenTheAppTurnsItOff() {
        let templates = MapInputs.templates(sources: Self.sources, layers: [.basemap, .terrain], showsHillshade: false)
        #expect(templates.terrain == nil)
    }

    @Test func withOnlineTilesOffTheTemplatesNameTheReservedHost() {
        let templates = MapInputs.templates(sources: nil, layers: [.basemap, .terrain], showsHillshade: true)
        #expect(!templates.onlineAllowed)
        #expect(templates.basemap.template == "https://maqs.invalid/basemap/{z}/{x}/{y}")
        #expect(templates.basemap.attribution.isEmpty)
        #expect(templates.terrain?.template == "https://maqs.invalid/terrain/{z}/{x}/{y}")
        #expect(templates.terrain?.tileSize == 512)
    }

    // MARK: Installed content

    @Test func aRegionsTileArchivesAreReadForTheirHeaders() {
        #expect(MapInputs.tileArchives(of: [region, base]) == [
            URL(filePath: "/packs/test-basemap.v1.pmtiles"), URL(filePath: "/packs/test-terrain.v1.pmtiles"),
            URL(filePath: "/packs/base.pmtiles"),
        ])
    }

    @Test func aRegionAnswersItsBasemapAndTerrainAndAddsItsOverlays() throws {
        let content = MapInputs.content(packs: [region], layers: [.basemap, .terrain, .trails, .places],
                                        catalog: try catalog(), archives: infos)
        let installed = try #require(content.table.regions.first)
        #expect(content.table.regions.count == 1)
        #expect(installed.id == "test")
        #expect(installed.bbox == BoundingBox(minLon: 12.21, minLat: 46.08, maxLon: 12.29, maxLat: 46.13))
        #expect(installed.archives == [
            LocalArchive(pack: .region("test"), layer: .basemap, url: URL(filePath: "/packs/test-basemap.v1.pmtiles"),
                         minZoom: 0, maxZoom: 14, bounds: Self.box, dataDate: Self.date),
            LocalArchive(pack: .region("test"), layer: .terrain, url: URL(filePath: "/packs/test-terrain.v1.pmtiles"),
                         minZoom: 0, maxZoom: 12, bounds: Self.box, dataDate: Self.date),
        ])
        #expect(content.table.basePacks.isEmpty)
        #expect(content.overlays == [
            OverlaySource(region: "test", layer: .trails, fileURL: URL(filePath: "/packs/test-trails.v1.pmtiles")),
            OverlaySource(region: "test", layer: .places, fileURL: URL(filePath: "/packs/test-places.v1.pmtiles")),
        ])
    }

    @Test func overlaysComeOnlyForTheConfiguredLayers() throws {
        let content = MapInputs.content(packs: [region], layers: [.basemap, .places], catalog: try catalog(),
                                        archives: infos)
        #expect(content.overlays.map(\.layer) == [.places])
    }

    @Test func aBasePackSitsBelowOnlineNotAmongTheRegions() throws {
        let content = MapInputs.content(packs: [base], layers: [.basemap], catalog: try catalog(), archives: infos)
        #expect(content.table.regions.isEmpty)
        #expect(content.table.basePacks == [
            LocalArchive(pack: .base("triveneto"), layer: .basemap, url: URL(filePath: "/packs/base.pmtiles"),
                         minZoom: 0, maxZoom: 9, bounds: Self.box, dataDate: Self.date),
        ])
        #expect(content.overlays.isEmpty)
    }

    @Test func anArchiveWhoseHeaderCouldNotBeReadIsLeftOut() throws {
        var unreadable = infos
        unreadable[URL(filePath: "/packs/test-terrain.v1.pmtiles")] = nil
        let content = MapInputs.content(packs: [region], layers: [.basemap, .terrain], catalog: try catalog(),
                                        archives: unreadable)
        // The region still covers its box, so its terrain tiles are empty there rather than fetched online.
        #expect(content.table.regions.first?.archives.map(\.layer) == [.basemap])
    }

    @Test func withoutACatalogTheRegionCoversItsArchives() {
        let wide = BoundingBox(minLon: 12.0, minLat: 46.0, maxLon: 12.3, maxLat: 46.2)
        var archives = infos
        archives[URL(filePath: "/packs/test-terrain.v1.pmtiles")] = ArchiveInfo(minZoom: 0, maxZoom: 12, bounds: wide)
        let content = MapInputs.content(packs: [region], layers: [.basemap, .terrain], catalog: nil, archives: archives)
        #expect(content.table.regions.first?.bbox == BoundingBox(minLon: 12.0, minLat: 46.0, maxLon: 12.3, maxLat: 46.2))
    }
}
