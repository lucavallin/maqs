import Foundation
import Testing
@testable import MaqsPMTiles

@Suite struct DirectoryTests {
    private func varint(_ value: UInt64) -> [UInt8] {
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

    /// Encodes a directory: count, id deltas, run lengths, lengths, then offset fields as written.
    private func encode(ids: [UInt64], runs: [UInt64], lengths: [UInt64], offsetFields: [UInt64]) -> Data {
        var bytes = varint(UInt64(ids.count))
        var last: UInt64 = 0
        for id in ids {
            bytes += varint(id - last)
            last = id
        }
        for value in runs + lengths + offsetFields { bytes += varint(value) }
        return Data(bytes)
    }

    private func entry(_ id: UInt64, _ run: UInt64, offset: UInt64 = 0, length: UInt64 = 1) -> DirectoryEntry {
        DirectoryEntry(tileID: id, offset: offset, length: length, runLength: run)
    }

    /// Asserts that decoding throws some `corruptDirectory`, whatever its message.
    private func expectCorrupt(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try Directory.decode(data)
            Issue.record("decoding did not throw", sourceLocation: sourceLocation)
        } catch {
            guard case .corruptDirectory = error else {
                Issue.record("threw \(error), not corruptDirectory", sourceLocation: sourceLocation)
                return
            }
        }
    }

    @Test func decodesTwoEntriesWithTheOffsetRunRule() throws {
        let data = encode(ids: [5, 9], runs: [1, 3], lengths: [100, 40], offsetFields: [1001, 0])
        let entries = try Directory.decode(data)
        #expect(entries == [
            entry(5, 1, offset: 1000, length: 100),
            entry(9, 3, offset: 1100, length: 40),
        ])
    }

    @Test func aCountLargerThanItsBytesIsCorrupt() {
        var bytes = varint(1000)
        bytes += [UInt8](repeating: 1, count: 10 - bytes.count)
        #expect(bytes.count == 10)
        expectCorrupt(Data(bytes))
    }

    @Test func anElevenByteVarintIsCorrupt() {
        expectCorrupt(Data([UInt8](repeating: 0x80, count: 10) + [0x00]))
    }

    @Test func aTenthByteAboveOneIsCorrupt() {
        expectCorrupt(Data([UInt8](repeating: 0xFF, count: 9) + [0x02]))
    }

    @Test func aTruncatedVarintIsCorrupt() {
        expectCorrupt(Data([0x80]))
        let data = encode(ids: [5], runs: [1], lengths: [100], offsetFields: [1]).dropLast(2)
        expectCorrupt(Data(data))
    }

    @Test func aFirstOffsetFieldOfZeroIsCorrupt() {
        expectCorrupt(encode(ids: [5], runs: [1], lengths: [100], offsetFields: [0]))
    }

    @Test func anIDDeltaThatOverflowsIsCorrupt() {
        var bytes = varint(2) + varint(UInt64.max) + varint(2)
        bytes += [UInt8](repeating: 1, count: 8)
        expectCorrupt(Data(bytes))
    }

    @Test func anOffsetThatOverflowsIsCorrupt() {
        expectCorrupt(encode(ids: [5], runs: [1], lengths: [UInt64.max], offsetFields: [3]))
    }

    @Test func findReturnsALeafPointerForIDsAfterIt() {
        let entries = [entry(0, 2), entry(10, 0), entry(50, 1)]
        #expect(Directory.find(entries, tileID: 10)?.tileID == 10)
        #expect(Directory.find(entries, tileID: 49)?.tileID == 10)
        #expect(Directory.find(entries, tileID: 1)?.tileID == 0)
        #expect(Directory.find(entries, tileID: 50)?.tileID == 50)
    }

    @Test func findReturnsNilPastARun() {
        let entries = [entry(0, 2), entry(10, 1)]
        #expect(Directory.find(entries, tileID: 2) == nil)
        #expect(Directory.find(entries, tileID: 11) == nil)
        #expect(Directory.find([], tileID: 0) == nil)
        #expect(Directory.find([entry(5, 1)], tileID: 4) == nil)
    }
}
