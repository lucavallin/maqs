import Foundation
import MaqsCore

/// The zoom range and bounds of a tile archive, read once from its header.
struct ArchiveInfo: Sendable, Equatable {
    var minZoom: Int
    var maxZoom: Int
    var bounds: BoundingBox
}

/// The tile templates the style names and the gateway matches.
struct MapTemplates: Sendable, Equatable {
    var basemap: TileTemplate
    /// The style's terrain source; `nil`: no hillshade.
    var terrain: TileTemplate?
    /// What the gateway claims. It serves every map of the process, so it depends only on what the whole `Maqs` says:
    /// terrain whenever `.terrain` is configured, whatever one map's hillshade switch says.
    var gateway: TileTemplates
    /// Whether the gateway may ask the network: online tiles are on and `sources.json` names a basemap.
    var onlineAllowed: Bool
}

/// What the installed packs give the map: the gateway's routing table and the overlay sources of the style.
struct InstalledContent: Sendable, Equatable {
    var table: RoutingTable
    var overlays: [OverlaySource]

    static let none = InstalledContent(table: RoutingTable(regions: [], basePacks: []), overlays: [])
}

/// Turns the online sources and the installed packs into what the style and the gateway need. Pure, so it is tested on
/// every platform.
enum MapInputs {
    /// With no online source the style still names a tile URL; these are on a reserved host (RFC 2606) that the gateway
    /// never sends to the network, because the network is then not allowed.
    static let reservedBasemap = "https://maqs.invalid/basemap/{z}/{x}/{y}"
    static let reservedTerrain = "https://maqs.invalid/terrain/{z}/{x}/{y}"

    /// The templates for the configured layers: the first `sources.json` entry of each layer, or the reserved host when
    /// there is none (`onlineTiles` false). The gateway gets terrain whenever the app configured `.terrain`; the style
    /// only when it also wants hillshade.
    static func templates(sources: OnlineSources?, layers: Set<Layer>, showsHillshade: Bool) -> MapTemplates {
        let basemap = sources?.basemap.first.map(template)
            ?? TileTemplate(template: reservedBasemap, minZoom: 0, maxZoom: 14, tileSize: nil, attribution: [])
        var terrain: TileTemplate?
        if layers.contains(.terrain) {
            terrain = sources?.terrain.first.map(template)
                ?? TileTemplate(template: reservedTerrain, minZoom: 0, maxZoom: 12, tileSize: 512, attribution: [])
        }
        return MapTemplates(
            basemap: basemap, terrain: showsHillshade ? terrain : nil,
            gateway: TileTemplates(basemap: basemap.template, terrain: terrain?.template),
            onlineAllowed: sources?.basemap.first != nil)
    }

    /// The basemap and terrain files of `packs`, whose headers ``content(packs:layers:catalog:archives:)`` needs.
    static func tileArchives(of packs: [InstalledPack]) -> [URL] {
        packs.flatMap { pack in tileFiles(of: pack).map(\.file.url) }
    }

    /// The routing table and overlays of `packs`. Regions answer for their basemap and terrain files and cover their
    /// catalog box (the union of their archives' bounds when the catalog does not list them); base packs answer only
    /// below online. An archive missing from `archives` (its header could not be read) is left out, so its region
    /// answers that layer empty. Overlays come only for the configured `trails` and `places` layers.
    static func content(packs: [InstalledPack], layers: Set<Layer>, catalog: Catalog?,
                        archives: [URL: ArchiveInfo]) -> InstalledContent {
        var regions: [InstalledRegion] = []
        var basePacks: [LocalArchive] = []
        var overlays: [OverlaySource] = []
        for pack in packs {
            let local = tileFiles(of: pack).compactMap { layer, file -> LocalArchive? in
                guard let info = archives[file.url] else { return nil }
                return LocalArchive(pack: pack.id, layer: layer, url: file.url, minZoom: info.minZoom,
                                    maxZoom: info.maxZoom, bounds: info.bounds, dataDate: file.dataDate)
            }
            switch pack.id {
            case .base:
                basePacks += local.filter { $0.layer == .basemap }
            case .region(let id):
                guard let bbox = catalog?.pack(pack.id)?.bbox ?? union(local.map(\.bounds)) else {
                    logger.error("map region \(id, privacy: .public) has no box and no readable archive: not drawn")
                    continue
                }
                regions.append(InstalledRegion(id: id, bbox: bbox, archives: local))
                for (layer, overlay) in [(Layer.trails, OverlayLayer.trails), (.places, .places)]
                where layers.contains(layer) {
                    if let file = pack.files[layer]?.first(where: { $0.role == "overlay" }) {
                        overlays.append(OverlaySource(region: id, layer: overlay, fileURL: file.url))
                    }
                }
            }
        }
        return InstalledContent(table: RoutingTable(regions: regions, basePacks: basePacks), overlays: overlays)
    }

    private static func template(_ source: TileSource) -> TileTemplate {
        TileTemplate(template: source.tiles, minZoom: source.minZoom, maxZoom: source.maxZoom, tileSize: source.tileSize,
                     attribution: source.attribution)
    }

    /// The main basemap and terrain files of a pack, basemap first.
    private static func tileFiles(of pack: InstalledPack) -> [(layer: TileLayer, file: InstalledFile)] {
        [(Layer.basemap, TileLayer.basemap), (.terrain, .terrain)].compactMap { layer, tileLayer in
            pack.files[layer]?.first { $0.role == nil }.map { (tileLayer, $0) }
        }
    }

    private static func union(_ boxes: [BoundingBox]) -> BoundingBox? {
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { box, next in
            BoundingBox(minLon: min(box.minLon, next.minLon), minLat: min(box.minLat, next.minLat),
                        maxLon: max(box.maxLon, next.maxLon), maxLat: max(box.maxLat, next.maxLat))
        }
    }
}
