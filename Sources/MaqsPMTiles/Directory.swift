import Foundation

/// One directory entry. A `runLength` of 0 marks a pointer to a leaf directory.
package struct DirectoryEntry: Equatable, Sendable {
    package let tileID: UInt64
    package let offset: UInt64
    package let length: UInt64
    package let runLength: UInt64

    package init(tileID: UInt64, offset: UInt64, length: UInt64, runLength: UInt64) {
        self.tileID = tileID
        self.offset = offset
        self.length = length
        self.runLength = runLength
    }
}

/// Decoding and lookup of PMTiles v3 directories (already decompressed). The bytes are untrusted.
enum Directory {
    /// The entries of a decompressed directory; every count, varint and sum is checked.
    static func decode(_ data: Data) throws(PMTilesReadError) -> [DirectoryEntry] {
        var reader = VarintReader(data: data)
        let count = try reader.next()
        // Each entry needs at least four bytes, so a larger count is corrupt and must not drive an allocation.
        guard count <= UInt64(data.count) / 4 else {
            throw .corruptDirectory("entry count exceeds the directory size")
        }
        let n = Int(count)
        var ids = [UInt64]()
        ids.reserveCapacity(n)
        var last: UInt64 = 0
        for _ in 0..<n {
            let (sum, overflow) = last.addingReportingOverflow(try reader.next())
            guard !overflow else { throw .corruptDirectory("tile id overflows") }
            last = sum
            ids.append(sum)
        }
        var runLengths = [UInt64]()
        runLengths.reserveCapacity(n)
        for _ in 0..<n { runLengths.append(try reader.next()) }
        var lengths = [UInt64]()
        lengths.reserveCapacity(n)
        for _ in 0..<n { lengths.append(try reader.next()) }
        var entries = [DirectoryEntry]()
        entries.reserveCapacity(n)
        var previousEnd: UInt64 = 0
        for i in 0..<n {
            let field = try reader.next()
            let offset: UInt64
            if field == 0 {
                // Zero means "directly after the previous entry".
                guard i > 0 else { throw .corruptDirectory("first entry has no offset") }
                offset = previousEnd
            } else {
                offset = field - 1
            }
            let (end, overflow) = offset.addingReportingOverflow(lengths[i])
            guard !overflow else { throw .corruptDirectory("tile offset overflows") }
            previousEnd = end
            entries.append(DirectoryEntry(tileID: ids[i], offset: offset, length: lengths[i], runLength: runLengths[i]))
        }
        return entries
    }

    /// The entry covering `tileID`: the last entry at or before it, if it is a leaf pointer or its run reaches `tileID`.
    /// `entries` must be sorted by tile id, as a directory is.
    static func find(_ entries: [DirectoryEntry], tileID: UInt64) -> DirectoryEntry? {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = low + (high - low) / 2
            if entries[mid].tileID <= tileID { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let entry = entries[low - 1]
        if entry.runLength == 0 { return entry }
        let (end, overflow) = entry.tileID.addingReportingOverflow(entry.runLength)
        return overflow || tileID < end ? entry : nil
    }
}

/// LEB128 varints of at most 10 bytes, as a cursor over untrusted bytes.
private struct VarintReader {
    let data: Data
    var position: Data.Index

    init(data: Data) {
        self.data = data
        self.position = data.startIndex
    }

    mutating func next() throws(PMTilesReadError) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<10 {
            guard position < data.endIndex else { throw .corruptDirectory("truncated varint") }
            let byte = data[position]
            position = data.index(after: position)
            // The tenth byte carries bit 63 only.
            if index == 9, byte > 1 { throw .corruptDirectory("varint overflows 64 bits") }
            result |= UInt64(byte & 0x7F) << UInt64(7 * index)
            if byte < 0x80 { return result }
        }
        throw .corruptDirectory("varint longer than 10 bytes")
    }
}
