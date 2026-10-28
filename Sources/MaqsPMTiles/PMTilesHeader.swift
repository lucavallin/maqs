import Foundation

/// The compressions this reader decodes; PMTiles codes 1 and 2.
package enum PMTilesCompression: UInt8, Sendable {
    case none = 1
    case gzip = 2
}

/// The fixed 127-byte PMTiles v3 header. Every section is checked to lie inside the file.
package struct PMTilesHeader: Sendable, Equatable {
    static let size = 127
    private static let magic = Array("PMTiles".utf8)

    var rootOffset, rootLength, metadataOffset, metadataLength, leafOffset, leafLength, tileDataOffset, tileDataLength: UInt64
    var addressedTiles: UInt64
    var clustered: Bool
    package var internalCompression, tileCompression: PMTilesCompression
    package var tileType: UInt8
    package var minZoom, maxZoom: Int
    package var bounds: (west: Double, south: Double, east: Double, north: Double)

    package static func == (lhs: PMTilesHeader, rhs: PMTilesHeader) -> Bool {
        lhs.rootOffset == rhs.rootOffset && lhs.rootLength == rhs.rootLength
            && lhs.metadataOffset == rhs.metadataOffset && lhs.metadataLength == rhs.metadataLength
            && lhs.leafOffset == rhs.leafOffset && lhs.leafLength == rhs.leafLength
            && lhs.tileDataOffset == rhs.tileDataOffset && lhs.tileDataLength == rhs.tileDataLength
            && lhs.addressedTiles == rhs.addressedTiles && lhs.clustered == rhs.clustered
            && lhs.internalCompression == rhs.internalCompression && lhs.tileCompression == rhs.tileCompression
            && lhs.tileType == rhs.tileType && lhs.minZoom == rhs.minZoom && lhs.maxZoom == rhs.maxZoom
            && lhs.bounds == rhs.bounds
    }

    /// Parses the first bytes of a file of `fileSize` bytes.
    static func parse(_ bytes: Data, fileSize: UInt64) throws(PMTilesReadError) -> PMTilesHeader {
        let bytes = bytes.startIndex == 0 ? bytes : Data(bytes)
        // A file that cannot even start with the magic is not an archive; one that starts right is just cut short.
        guard bytes.prefix(magic.count).elementsEqual(magic.prefix(bytes.count)) else { throw .notPMTiles }
        guard bytes.count >= size else { throw .truncated }
        guard bytes[7] == 3 else { throw .unsupportedVersion(bytes[7]) }
        guard let internalCompression = PMTilesCompression(rawValue: bytes[97]) else {
            throw .unsupportedCompression(bytes[97])
        }
        guard let tileCompression = PMTilesCompression(rawValue: bytes[98]) else {
            throw .unsupportedCompression(bytes[98])
        }
        func u64(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << UInt64(8 * $1) }
        }
        func e7(_ offset: Int) -> Double {
            let raw = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
            return Double(Int32(bitPattern: raw)) / 1e7
        }
        let header = PMTilesHeader(
            rootOffset: u64(8), rootLength: u64(16), metadataOffset: u64(24), metadataLength: u64(32),
            leafOffset: u64(40), leafLength: u64(48), tileDataOffset: u64(56), tileDataLength: u64(64),
            addressedTiles: u64(72), clustered: bytes[96] == 1,
            internalCompression: internalCompression, tileCompression: tileCompression,
            tileType: bytes[99], minZoom: Int(bytes[100]), maxZoom: Int(bytes[101]),
            bounds: (west: e7(102), south: e7(106), east: e7(110), north: e7(114))
        )
        for (offset, length) in [(header.rootOffset, header.rootLength), (header.metadataOffset, header.metadataLength),
                                 (header.leafOffset, header.leafLength), (header.tileDataOffset, header.tileDataLength)] {
            let (end, overflow) = offset.addingReportingOverflow(length)
            guard !overflow, end <= fileSize else { throw .truncated }
        }
        return header
    }
}
