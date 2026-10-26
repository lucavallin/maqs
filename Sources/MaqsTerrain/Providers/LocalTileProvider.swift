import Foundation

/// Elevation tiles from an installed PMTiles archive. Immutable over a `Sendable` archive.
final class LocalTileProvider: TileProvider {
    /// The tile size assumed when the archive's metadata does not say.
    private static let defaultTileSize = 512
    /// The sizes `OnlineTerrainSource` accepts too. Anything else could divide by zero or overflow where tiles are counted
    /// and decoded, so an archive that declares another size is not a terrain source.
    private static let tileSizes: Set<Int> = [256, 512]
    private static let pngTileType: UInt8 = 2
    private static let webpTileType: UInt8 = 4

    private let archive: PMTilesArchive
    let zoomRange: ClosedRange<Int>
    let tileSize: Int
    let isOnline = false

    /// Throws `PMTilesError` for an unreadable or corrupt archive, `TerrainError.notTerrain` for another kind of archive,
    /// including one whose metadata declares a `tile_size` other than 256 or 512.
    init(url: URL) throws {
        let archive = try PMTilesArchive(url: url)
        let tileSize = archive.declaresTileSize ? archive.tileSize : Self.defaultTileSize
        guard archive.header.tileType == Self.pngTileType || archive.header.tileType == Self.webpTileType,
            archive.tileSchema == nil || archive.tileSchema == "dem/terrarium",
            archive.header.minZoom <= archive.header.maxZoom,
            let tileSize, Self.tileSizes.contains(tileSize)
        else {
            throw TerrainError.notTerrain(url)
        }
        self.archive = archive
        self.zoomRange = archive.header.minZoom...archive.header.maxZoom
        self.tileSize = tileSize
    }

    func covers(_ key: TileKey) throws -> Bool {
        try archive.contains(z: key.z, x: key.x, y: key.y)
    }

    func load(_ key: TileKey) async throws -> TileLoad {
        guard let data = try archive.tile(z: key.z, x: key.x, y: key.y) else { return .missing(.noData) }
        return .tile(try TerrariumDecoder.decode(data, expectedSize: tileSize))
    }
}
