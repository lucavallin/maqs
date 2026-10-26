/// Which provider a tile came from, so equal tile keys of different providers never collide.
struct SourceTile: Hashable, Sendable {
    let provider: Int
    let key: TileKey
}

/// Decoded tiles bounded by their memory, least recently used out first. Owned by one actor, so not `Sendable`.
final class TileCache {
    private struct Entry {
        let tile: ElevationTile
        var stamp: UInt64
    }

    private let byteLimit: Int
    private var entries: [SourceTile: Entry] = [:]
    private var clock: UInt64 = 0
    private(set) var byteCount = 0

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    func tile(for key: SourceTile) -> ElevationTile? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.stamp = clock
        entries[key] = entry
        return entry.tile
    }

    /// Keeps the tile, evicting least recently used ones until the cache is within its limit; a tile larger than the limit is not kept.
    func insert(_ tile: ElevationTile, for key: SourceTile) {
        if let old = entries.removeValue(forKey: key) { byteCount -= old.tile.byteCount }
        guard tile.byteCount <= byteLimit else { return }
        clock += 1
        entries[key] = Entry(tile: tile, stamp: clock)
        byteCount += tile.byteCount
        // The cache holds a few dozen tiles, so a scan per eviction is cheaper than a linked list to maintain.
        while byteCount > byteLimit, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp }) {
            entries[oldest.key] = nil
            byteCount -= oldest.value.tile.byteCount
        }
    }
}
