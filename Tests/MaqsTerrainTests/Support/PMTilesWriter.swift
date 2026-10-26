import Foundation
@testable import MaqsTerrain

/// Writes small PMTiles v3 archives for tests: gzip directories and metadata, uncompressed tiles.
enum PMTilesWriter {
    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    /// A decompressed directory; every offset is written explicitly (`offset + 1`).
    static func encodeDirectory(_ entries: [DirectoryEntry]) -> Data {
        var bytes = varint(UInt64(entries.count))
        var last: UInt64 = 0
        for entry in entries {
            bytes += varint(entry.tileID - last)
            last = entry.tileID
        }
        for entry in entries { bytes += varint(entry.runLength) }
        for entry in entries { bytes += varint(entry.length) }
        for entry in entries { bytes += varint(entry.offset + 1) }
        return Data(bytes)
    }

    private static func le(_ value: UInt64, bytes: Int) -> [UInt8] {
        (0..<bytes).map { UInt8((value >> UInt64(8 * $0)) & 0xFF) }
    }

    /// Lays out a whole archive from ready-made sections. `internalCompression` and `tileCompression` are PMTiles codes.
    static func assemble(root: Data, leaves: Data = Data(), tileData: Data = Data(), metadata: Data,
                         internalCompression: UInt8 = 2, tileCompression: UInt8 = 1, tileType: UInt8 = 4,
                         minZoom: UInt8 = 0, maxZoom: UInt8 = 0, addressedTiles: UInt64 = 0) -> Data {
        let rootOffset: UInt64 = 127
        let metadataOffset = rootOffset + UInt64(root.count)
        let leafOffset = metadataOffset + UInt64(metadata.count)
        let tileOffset = leafOffset + UInt64(leaves.count)
        var header = Data("PMTiles".utf8)
        header.append(3)
        for value in [rootOffset, UInt64(root.count), metadataOffset, UInt64(metadata.count), leafOffset,
                      UInt64(leaves.count), tileOffset, UInt64(tileData.count), addressedTiles, addressedTiles,
                      addressedTiles] {
            header.append(contentsOf: le(value, bytes: 8))
        }
        header.append(contentsOf: [1, internalCompression, tileCompression, tileType, minZoom, maxZoom])
        for value in [110_000_000, 450_000_000, 120_000_000, 460_000_000] as [Int32] {
            header.append(contentsOf: le(UInt64(UInt32(bitPattern: value)), bytes: 4))
        }
        header.append(minZoom)
        header.append(contentsOf: le(0, bytes: 8))
        precondition(header.count == 127)
        return header + root + metadata + leaves + tileData
    }

    static func write(tiles: [(z: Int, x: Int, y: Int, data: Data)], to url: URL, leafEntries: Int? = nil,
                      tileType: UInt8 = 4, metadata: [String: String] = ["tile_schema": "dem/terrarium"],
                      minZoom: Int? = nil, maxZoom: Int? = nil) throws {
        let sorted = tiles.map { (id: TileID.id(z: $0.z, x: $0.x, y: $0.y)!, data: $0.data) }.sorted { $0.id < $1.id }
        var tileData = Data()
        var entries: [DirectoryEntry] = []
        for tile in sorted {
            entries.append(DirectoryEntry(tileID: tile.id, offset: UInt64(tileData.count), length: UInt64(tile.data.count),
                                          runLength: 1))
            tileData.append(tile.data)
        }
        var rootEntries = entries
        var leaves = Data()
        if let leafEntries {
            rootEntries = []
            for start in stride(from: 0, to: entries.count, by: leafEntries) {
                let chunk = Array(entries[start..<min(start + leafEntries, entries.count)])
                let leaf = GzipMember.make(encodeDirectory(chunk))
                rootEntries.append(DirectoryEntry(tileID: chunk[0].tileID, offset: UInt64(leaves.count),
                                                  length: UInt64(leaf.count), runLength: 0))
                leaves.append(leaf)
            }
        }
        let zooms = tiles.map(\.z)
        let json = try JSONSerialization.data(withJSONObject: metadata)
        let archive = assemble(root: GzipMember.make(encodeDirectory(rootEntries)), leaves: leaves, tileData: tileData,
                               metadata: GzipMember.make(json), tileType: tileType,
                               minZoom: UInt8(minZoom ?? zooms.min() ?? 0), maxZoom: UInt8(maxZoom ?? zooms.max() ?? 0),
                               addressedTiles: UInt64(tiles.count))
        try archive.write(to: url)
    }
}
