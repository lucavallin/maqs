import Foundation
import MaqsCore

/// One PMTiles file the gateway can read.
struct LocalArchive: Sendable, Equatable {
    var pack: PackID
    var layer: TileLayer
    var url: URL
    var minZoom: Int
    var maxZoom: Int
    var bounds: BoundingBox
    var dataDate: Date?
}

/// An installed region: its box and the archives of its pack.
struct InstalledRegion: Sendable, Equatable {
    var id: String
    var bbox: BoundingBox
    var archives: [LocalArchive]
}

/// What is installed: regions (the authority inside their boxes) and base packs (below online).
struct RoutingTable: Sendable, Equatable {
    var regions: [InstalledRegion]
    var basePacks: [LocalArchive]
}

/// Where a tile request is answered.
enum Route: Sendable, Equatable {
    /// From this archive.
    case local(URL)
    /// An installed region covers the tile but has nothing for it: answer with no tile, never online.
    case empty
    /// Outside every installed region.
    case online
}

/// The answer when online cannot be asked or has failed.
enum Fallback: Sendable, Equatable {
    case local(URL)
    case unavailable
}

/// Decides where a tile comes from. Inside an installed region the region is the authority, even for a layer it lacks;
/// base packs sit below online and answer only through ``fallback(_:in:)``; outside every region it is online.
enum TileRouter {
    static func route(_ request: TileRequest, in table: RoutingTable) -> Route {
        let covering = table.regions.filter { covers($0, request) }
        guard !covering.isEmpty else { return .online }
        let candidates = covering.flatMap(\.archives).filter { holds($0, request) }
        guard let best = candidates.min(by: ranksBefore) else { return .empty }
        return .local(best.url)
    }

    static func fallback(_ request: TileRequest, in table: RoutingTable) -> Fallback {
        guard let best = table.basePacks.filter({ holds($0, request) }).min(by: ranksBefore) else { return .unavailable }
        return .local(best.url)
    }

    /// A region covers a tile by the bounds of its archives of that layer, or by its own box when it has none.
    private static func covers(_ region: InstalledRegion, _ request: TileRequest) -> Bool {
        let box = tileBox(request)
        let ofLayer = region.archives.filter { $0.layer == request.layer }
        if ofLayer.isEmpty { return intersects(box, region.bbox) }
        return ofLayer.contains { intersects(box, $0.bounds) }
    }

    private static func holds(_ archive: LocalArchive, _ request: TileRequest) -> Bool {
        archive.layer == request.layer && archive.minZoom <= request.z && request.z <= archive.maxZoom
            && intersects(tileBox(request), archive.bounds)
    }

    /// Highest `maxZoom`, then newest `dataDate` (none is oldest), then the pack id.
    private static func ranksBefore(_ a: LocalArchive, _ b: LocalArchive) -> Bool {
        if a.maxZoom != b.maxZoom { return a.maxZoom > b.maxZoom }
        if a.dataDate != b.dataDate { return (a.dataDate ?? .distantPast) > (b.dataDate ?? .distantPast) }
        return identifier(a.pack) < identifier(b.pack)
    }

    private static func identifier(_ pack: PackID) -> String {
        switch pack {
        case .region(let id), .base(let id): id
        }
    }

    /// The tile's Web Mercator extent in degrees.
    private static func tileBox(_ request: TileRequest) -> BoundingBox {
        let n = Double(1 << request.z)
        func longitude(_ x: Int) -> Double { Double(x) / n * 360 - 180 }
        func latitude(_ y: Int) -> Double { atan(sinh(Double.pi * (1 - 2 * Double(y) / n))) * 180 / .pi }
        return BoundingBox(
            minLon: longitude(request.x), minLat: latitude(request.y + 1),
            maxLon: longitude(request.x + 1), maxLat: latitude(request.y))
    }

    /// Touching edges count as intersecting.
    private static func intersects(_ a: BoundingBox, _ b: BoundingBox) -> Bool {
        a.minLon <= b.maxLon && b.minLon <= a.maxLon && a.minLat <= b.maxLat && b.minLat <= a.maxLat
    }
}
