/// The outcome of loading one tile. Online failures are values; local read errors are thrown instead.
enum TileLoad: Sendable {
    case tile(ElevationTile)
    case missing(MissingReason)
}

/// A source of elevation tiles: an installed archive or an online service.
/// The synchronous requirements are plain reads of immutable state, so an actor can satisfy them with `nonisolated` members.
protocol TileProvider: Sendable {
    /// Zoom levels the provider can serve.
    var zoomRange: ClosedRange<Int> { get }
    /// The pixel size of its tiles; positions are computed with it.
    var tileSize: Int { get }
    var isOnline: Bool { get }
    /// Whether the provider has this tile. Local: a directory lookup; online: the zoom is in range.
    func covers(_ key: TileKey) throws -> Bool
    func load(_ key: TileKey) async throws -> TileLoad
}
