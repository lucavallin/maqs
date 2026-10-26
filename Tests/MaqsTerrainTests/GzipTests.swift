import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsTerrain

@Suite struct GzipTests {
    private let payload = Data(String(repeating: "terrain tile bytes ", count: 200).utf8)

    private func expectCorrupt(_ data: Data, limit: Int = 1 << 20, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try Gzip.inflate(data, limit: limit)
            Issue.record("inflating did not throw", sourceLocation: sourceLocation)
        } catch {
            guard case .corruptCompressedData = error else {
                Issue.record("expected corruptCompressedData, got \(error)", sourceLocation: sourceLocation)
                return
            }
        }
    }

    @Test func crc32OfCheckString() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func inflatesAPlainMember() throws {
        #expect(try Gzip.inflate(GzipMember.make(payload), limit: 1 << 20) == payload)
    }

    @Test func inflatesAnEmptyPayload() throws {
        #expect(try Gzip.inflate(GzipMember.make(Data()), limit: 10).isEmpty)
    }

    @Test func skipsAnExtraField() throws {
        let member = GzipMember.make(payload, extra: Data([1, 2, 3, 4, 5]))
        #expect(try Gzip.inflate(member, limit: 1 << 20) == payload)
    }

    @Test func skipsAName() throws {
        #expect(try Gzip.inflate(GzipMember.make(payload, name: "tile.bin"), limit: 1 << 20) == payload)
    }

    @Test func skipsAComment() throws {
        #expect(try Gzip.inflate(GzipMember.make(payload, comment: "made by a test"), limit: 1 << 20) == payload)
    }

    @Test func acceptsAValidHeaderCRC() throws {
        let member = GzipMember.make(payload, extra: Data([9]), name: "n", comment: "c", headerCRC: true)
        #expect(try Gzip.inflate(member, limit: 1 << 20) == payload)
    }

    @Test func rejectsAWrongHeaderCRC() {
        var member = GzipMember.make(payload, name: "n", headerCRC: true)
        member[12] ^= 0xFF  // 10 fixed bytes, "n" and its terminator, then the CRC
        expectCorrupt(member)
    }

    @Test func ignoresBytesAfterTheTrailer() throws {
        var member = GzipMember.make(payload)
        member.append(Data(repeating: 0xAB, count: 20))
        #expect(try Gzip.inflate(member, limit: 1 << 20) == payload)
    }

    @Test func rejectsABadMagic() {
        var member = GzipMember.make(payload)
        member[0] = 0x00
        expectCorrupt(member)
    }

    @Test func rejectsAMethodOtherThanDeflate() {
        var member = GzipMember.make(payload)
        member[2] = 7
        expectCorrupt(member)
    }

    @Test func rejectsReservedFlagBits() {
        var member = GzipMember.make(payload)
        member[3] |= 0x20
        expectCorrupt(member)
    }

    @Test func rejectsATruncatedHeader() {
        expectCorrupt(GzipMember.make(payload).prefix(6))
        expectCorrupt(GzipMember.make(payload, name: "never ends").prefix(14))
        expectCorrupt(GzipMember.make(payload, extra: Data(repeating: 0, count: 50)).prefix(20))
    }

    @Test func rejectsABadCRC() {
        var member = GzipMember.make(payload)
        member[member.count - 8] ^= 0xFF
        expectCorrupt(member)
    }

    @Test func rejectsAWrongLength() {
        var member = GzipMember.make(payload)
        member[member.count - 1] ^= 0x01
        expectCorrupt(member)
    }

    @Test func rejectsATruncatedBody() {
        expectCorrupt(GzipMember.make(payload).prefix(20))
    }

    @Test func rejectsAMissingTrailer() {
        let member = GzipMember.make(payload)
        expectCorrupt(member.prefix(member.count - 4))
    }

    @Test func stopsAtTheLimit() {
        let bomb = GzipMember.make(Data(count: 1 << 20))
        do {
            _ = try Gzip.inflate(bomb, limit: 1000)
            Issue.record("inflating did not throw")
        } catch {
            #expect(error == .sectionTooLarge)
        }
    }

    @Test func allowsOutputExactlyAtTheLimit() throws {
        #expect(try Gzip.inflate(GzipMember.make(payload), limit: payload.count) == payload)
    }

    @Test func inflatesTheTerrainFixturesRootDirectory() throws {
        let file = try Data(contentsOf: Fixtures.url("test/test-terrain.v1.pmtiles"))
        let header = try PMTilesHeader.parse(file.prefix(127), fileSize: UInt64(file.count))
        let start = Int(header.rootOffset)
        let root = file[start..<start + Int(header.rootLength)]
        let entries = try Directory.decode(Gzip.inflate(root, limit: 16 << 20))
        #expect(entries.count == 14)
    }
}
