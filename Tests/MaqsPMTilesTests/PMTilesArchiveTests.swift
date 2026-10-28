import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsPMTiles

@Suite struct PMTilesArchiveTests {
    private static let fixtureNames = [
        "test-basemap.v1.pmtiles", "test-places.v1.pmtiles", "test-terrain.v1.pmtiles", "test-trails.v1.pmtiles",
    ]

    private func terrain() throws -> PMTilesArchive {
        try PMTilesArchive(url: Fixtures.url("test/test-terrain.v1.pmtiles"))
    }

    private let fiveTiles: [(z: Int, x: Int, y: Int, data: Data)] = [
        (2, 0, 0, Data("a".utf8)), (2, 1, 0, Data("bb".utf8)), (2, 2, 1, Data("ccc".utf8)),
        (3, 4, 4, Data("dddd".utf8)), (3, 7, 7, Data("eeeee".utf8)),
    ]

    private func expect(_ error: PMTilesReadError, sourceLocation: SourceLocation = #_sourceLocation, when body: () throws -> Void) {
        do {
            try body()
            Issue.record("did not throw \(error)", sourceLocation: sourceLocation)
        } catch let thrown as PMTilesReadError {
            #expect(thrown == error, sourceLocation: sourceLocation)
        } catch {
            Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
        }
    }

    private func expectCorruptDirectory(sourceLocation: SourceLocation = #_sourceLocation, when body: () throws -> Void) {
        do {
            try body()
            Issue.record("did not throw", sourceLocation: sourceLocation)
        } catch let thrown as PMTilesReadError {
            guard case .corruptDirectory = thrown else {
                Issue.record("expected corruptDirectory, got \(thrown)", sourceLocation: sourceLocation)
                return
            }
        } catch {
            Issue.record("unexpected \(error)", sourceLocation: sourceLocation)
        }
    }

    /// Writes `data`, after `edit`, into a fresh temporary directory; keep the directory alive while the URL is used.
    private func stored(_ data: Data, edit: (inout Data) -> Void = { _ in }) throws -> (url: URL, directory: TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("archive.pmtiles")
        var copy = data
        edit(&copy)
        try copy.write(to: url)
        return (url, directory)
    }

    private func setU64(_ data: inout Data, at offset: Int, to value: UInt64) {
        for i in 0..<8 { data[offset + i] = UInt8((value >> UInt64(8 * i)) & 0xFF) }
    }

    private func writtenArchive(leafEntries: Int? = nil) throws -> Data {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("w.pmtiles")
        try PMTilesWriter.write(tiles: fiveTiles, to: url, leafEntries: leafEntries)
        return try Data(contentsOf: url)
    }

    // MARK: fixtures

    @Test(arguments: fixtureNames) func everyFixtureArchiveOpens(name: String) throws {
        let archive = try PMTilesArchive(url: Fixtures.url("test/\(name)"))
        #expect(archive.header.addressedTiles > 0)
    }

    @Test func theTerrainHeaderIsWhatThePipelineReads() throws {
        let archive = try terrain()
        let header = archive.header
        #expect(header.tileType == 4)
        #expect(header.minZoom == 0)
        #expect(header.maxZoom == 12)
        #expect(header.internalCompression == .gzip)
        #expect(header.tileCompression == .none)
        #expect(header.clustered)
        #expect(header.addressedTiles == 14)
        #expect(header.bounds.west < header.bounds.east)
        #expect(header.bounds.south < header.bounds.north)
        #expect(archive.tileSchema == "dem/terrarium")
        #expect(archive.tileSize == 512)
    }

    @Test func terrainTilesMatchThePipelinesBytes() throws {
        let archive = try terrain()
        let golden = try Golden.load()
        #expect(!golden.tiles.isEmpty)
        for entry in golden.tiles {
            let tile = try #require(try archive.tile(z: entry.z, x: entry.x, y: entry.y))
            #expect(SHA256Hex.hex(of: tile) == entry.sha256, "tile \(entry.z)/\(entry.x)/\(entry.y)")
            #expect(try archive.contains(z: entry.z, x: entry.x, y: entry.y))
        }
    }

    @Test func basemapTilesInflate() throws {
        let archive = try PMTilesArchive(url: Fixtures.url("test/test-basemap.v1.pmtiles"))
        #expect(archive.header.tileCompression == .gzip)
        let tile = try #require(try archive.tile(z: 0, x: 0, y: 0))
        #expect(!tile.isEmpty)
    }

    @Test func anAbsentTileIsNil() throws {
        let archive = try terrain()
        #expect(try archive.tile(z: 12, x: 0, y: 0) == nil)
        #expect(try !archive.contains(z: 12, x: 0, y: 0))
        #expect(try archive.tile(z: 3, x: 99, y: 0) == nil)
    }

    // MARK: leaf directories

    @Test func aTileBehindALeafDirectoryReads() throws {
        let (url, directory) = try stored(try writtenArchive(leafEntries: 2))
        withExtendedLifetime(directory) {}
        let archive = try PMTilesArchive(url: url)
        for tile in fiveTiles {
            #expect(try archive.tile(z: tile.z, x: tile.x, y: tile.y) == tile.data)
        }
        #expect(try archive.tile(z: 3, x: 0, y: 0) == nil)
    }

    @Test func aNestedLeafDirectoryIsRejected() throws {
        let id = try #require(TileID.id(z: 2, x: 0, y: 0))
        let inner = GzipMember.make(PMTilesWriter.encodeDirectory([DirectoryEntry(tileID: id, offset: 0, length: 5, runLength: 0)]))
        let root = GzipMember.make(PMTilesWriter.encodeDirectory([
            DirectoryEntry(tileID: id, offset: 0, length: UInt64(inner.count), runLength: 0)
        ]))
        let archive = PMTilesWriter.assemble(root: root, leaves: inner, metadata: GzipMember.make(Data("{}".utf8)))
        let (url, directory) = try stored(archive)
        withExtendedLifetime(directory) {}
        let opened = try PMTilesArchive(url: url)
        expect(.nestedLeafDirectory) { _ = try opened.tile(z: 2, x: 0, y: 0) }
    }

    // MARK: corruption

    @Test func rejectsAHeaderShorterThan127Bytes() throws {
        let (url, directory) = try stored(try writtenArchive()) { $0 = $0.prefix(100) }
        withExtendedLifetime(directory) {}
        expect(.truncated) { _ = try PMTilesArchive(url: url) }
    }

    @Test func rejectsABadMagic() throws {
        let (url, directory) = try stored(try writtenArchive()) { $0[0] = 0x58 }
        withExtendedLifetime(directory) {}
        expect(.notPMTiles) { _ = try PMTilesArchive(url: url) }
    }

    @Test func rejectsVersionTwo() throws {
        let (url, directory) = try stored(try writtenArchive()) { $0[7] = 2 }
        withExtendedLifetime(directory) {}
        expect(.unsupportedVersion(2)) { _ = try PMTilesArchive(url: url) }
    }

    @Test func rejectsAnUnsupportedInternalCompression() throws {
        let (url, directory) = try stored(try writtenArchive()) { $0[97] = 3 }
        withExtendedLifetime(directory) {}
        expect(.unsupportedCompression(3)) { _ = try PMTilesArchive(url: url) }
    }

    @Test func rejectsAnUnsupportedTileCompression() throws {
        let (url, directory) = try stored(try writtenArchive()) { $0[98] = 4 }
        withExtendedLifetime(directory) {}
        expect(.unsupportedCompression(4)) { _ = try PMTilesArchive(url: url) }
    }

    @Test func rejectsARootDirectoryPastTheEnd() throws {
        let (url, directory) = try stored(try writtenArchive()) { [self] in setU64(&$0, at: 16, to: UInt64($0.count)) }
        withExtendedLifetime(directory) {}
        expect(.truncated) { _ = try PMTilesArchive(url: url) }
    }

    @Test func rejectsASectionWhoseEndOverflows() throws {
        let (url, directory) = try stored(try writtenArchive()) { [self] in
            setU64(&$0, at: 8, to: UInt64.max - 3)
            setU64(&$0, at: 16, to: 100)
        }
        withExtendedLifetime(directory) {}
        expect(.truncated) { _ = try PMTilesArchive(url: url) }
    }

    @Test func rejectsATileEntryPastTheTileData() throws {
        let (url, directory) = try stored(try writtenArchive()) { [self] in setU64(&$0, at: 64, to: 1) }
        withExtendedLifetime(directory) {}
        let archive = try PMTilesArchive(url: url)
        expectCorruptDirectory { _ = try archive.tile(z: 3, x: 7, y: 7) }
    }

    @Test func rejectsALeafPointerPastTheLeafSection() throws {
        let (url, directory) = try stored(try writtenArchive(leafEntries: 2)) { [self] in setU64(&$0, at: 48, to: 1) }
        withExtendedLifetime(directory) {}
        let archive = try PMTilesArchive(url: url)
        expectCorruptDirectory { _ = try archive.tile(z: 2, x: 0, y: 0) }
    }

    @Test func rejectsATileOver64MiB() throws {
        let id = try #require(TileID.id(z: 0, x: 0, y: 0))
        let root = PMTilesWriter.encodeDirectory([DirectoryEntry(tileID: id, offset: 0, length: 70 << 20, runLength: 1)])
        let archive = PMTilesWriter.assemble(root: root, metadata: Data("{}".utf8), internalCompression: 1)
        let (url, directory) = try stored(archive)
        withExtendedLifetime(directory) {}
        let opened = try PMTilesArchive(url: url)
        expect(.sectionTooLarge) { _ = try opened.tile(z: 0, x: 0, y: 0) }
    }

    @Test func rejectsMetadataOver8MiB() throws {
        // The file is padded so the claimed section lies inside it; only its size is under test.
        let (url, directory) = try stored(try writtenArchive()) { [self] in
            $0.append(Data(count: 9 << 20))
            setU64(&$0, at: 32, to: 9 << 20)
        }
        withExtendedLifetime(directory) {}
        expect(.sectionTooLarge) { _ = try PMTilesArchive(url: url) }
    }

    @Test func aMissingFileIsUnreadable() throws {
        let directory = try TemporaryDirectory()
        expect(.unreadableFile) { _ = try PMTilesArchive(url: directory.url.appendingPathComponent("nope.pmtiles")) }
    }

    // MARK: lifetime

    @Test func aRemovedFileStillReads() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("gone.pmtiles")
        try PMTilesWriter.write(tiles: fiveTiles, to: url)
        let archive = try PMTilesArchive(url: url)
        try FileManager.default.removeItem(at: url)
        #expect(try archive.tile(z: 3, x: 4, y: 4) == Data("dddd".utf8))
    }

    @Test func aFileTruncatedAfterOpeningThrowsTruncated() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("cut.pmtiles")
        try PMTilesWriter.write(tiles: fiveTiles, to: url)
        let archive = try PMTilesArchive(url: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 127)
        try handle.close()
        expect(.truncated) { _ = try archive.tile(z: 3, x: 7, y: 7) }
    }
}
