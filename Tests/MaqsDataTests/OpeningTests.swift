import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsData

@Suite struct OpeningTests {
    private static let layers: [Layer] = [.trails, .places, .curvature]

    private func fixture(_ layer: Layer) throws -> URL {
        try Fixtures.url("test/test-\(layer.rawValue).v1.sqlite")
    }

    /// Copies the layer's fixture into `directory` as `name`.
    private func copy(_ layer: Layer, to directory: URL, as name: String) throws -> URL {
        let url = directory.appending(path: name)
        try FileManager.default.copyItem(at: fixture(layer), to: url)
        return url
    }

    private func listing(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
    }

    private func count(_ table: String, in file: LayerFile) throws -> Int64 {
        let statement = try file.connection.prepare("SELECT count(*) FROM \(table)")
        defer { statement.reset() }
        #expect(try statement.step())
        return statement.int64(at: 0)
    }

    private static func point(_ lon: Double, _ lat: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// The main-table rows `write` puts in a file of each layer.
    private static func writtenRows(_ layer: Layer) -> Int {
        switch layer {
        case .trails: 2
        case .places: 3
        case .curvature: 2
        }
    }

    /// A small synthetic file of `layer` with ``writtenRows(_:)`` rows in its main table.
    private func write(
        _ layer: Layer, to url: URL, schemaVersion: Int = 1, metadataRows: Int = 1, region: String = "synthetic",
        dropping: String? = nil
    ) throws {
        switch layer {
        case .trails:
            try LayerFileWriter.trails([
                TrailRow(id: 1, ref: "801", name: "Alta Via", length: 160,
                         legs: [[Self.point(12.25, 46.1), Self.point(12.2501, 46.1002)]]),
                TrailRow(id: 2, name: "Sentiero senza geometria", geometryStatus: "incomplete"),
            ], to: url, schemaVersion: schemaVersion, metadataRows: metadataRows, region: region, dropping: dropping)
        case .places:
            try LayerFileWriter.places([
                PlaceRow(id: 1, name: "Col Visentin", ele: 1763, coordinate: Self.point(12.31, 46.07), rankScore: 1000),
                PlaceRow(id: 2, kind: "alpine_hut", name: "Rifugio", coordinate: Self.point(12.29, 46.08)),
                PlaceRow(id: 3, kind: "village", name: "Nevegal", coordinate: Self.point(12.28, 46.1)),
            ], to: url, schemaVersion: schemaVersion, metadataRows: metadataRows, region: region, dropping: dropping)
        case .curvature:
            try LayerFileWriter.curvature(
                segments: [
                    SegmentRow(id: 1, name: "Via Nevegal", length: 400, score: 12, startNode: 10, endNode: 11,
                               coordinates: [Self.point(12.25, 46.1), Self.point(12.254, 46.101)]),
                    SegmentRow(id: 2, ref: "SP31", startNode: 11, endNode: 12,
                               coordinates: [Self.point(12.254, 46.101), Self.point(12.26, 46.1)]),
                ],
                corners: [
                    CornerRow(id: 1, segmentID: 1, ordinal: 0, apex: Self.point(12.252, 46.1005), minRadius: 45,
                              direction: "left", entry: 100, apexDistance: 150, exit: 200),
                ],
                junctions: [JunctionRow(segmentID: 1, node: 20, along: 150)],
                to: url, schemaVersion: schemaVersion, metadataRows: metadataRows, region: region, dropping: dropping)
        }
    }

    /// The file an error names, for the cases that name one.
    private static func fileName(of error: QueryError) -> String? {
        switch error {
        case .cannotOpen(let file), .wrongLayer(let file, _, _), .unsupportedSchemaVersion(let file, _),
             .incompatibleFile(let file, _), .corruptData(let file, _), .unreadable(let file):
            file
        case .duplicateRegion, .invalidInput, .unknownSegment:
            nil
        }
    }

    // MARK: layers and versions

    @Test("each fixture opens as its layer and is rejected as the other two", arguments: layers)
    func fixtureLayers(layer: Layer) throws {
        let url = try fixture(layer)
        let file = try LayerFile.open(url, as: layer)
        #expect(file.fileName == "test-\(layer.rawValue).v1.sqlite")
        #expect(file.connection.fileName == file.fileName)
        #expect(file.region == "test")
        #expect(file.rowCount > 0)
        #expect(file.hasJunctions == (layer == .curvature))
        #expect(file.hasJunctionColumn == (layer == .curvature))
        for other in Self.layers where other != layer {
            #expect(throws: QueryError.wrongLayer(file: file.fileName, expected: other.rawValue, found: layer.rawValue)) {
                _ = try LayerFile.open(url, as: other)
            }
        }
    }

    @Test("schema version 2 is unsupported", arguments: layers)
    func schemaVersionTwo(layer: Layer) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "v2.sqlite")
        try write(layer, to: url, schemaVersion: 2)
        #expect(throws: QueryError.unsupportedSchemaVersion(file: "v2.sqlite", version: 2)) {
            _ = try LayerFile.open(url, as: layer)
        }
    }

    // MARK: tables and columns

    @Test("a missing metadata table is incompatible", arguments: layers)
    func missingMetadata(layer: Layer) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "no-metadata.sqlite")
        try write(layer, to: url, dropping: "metadata")
        #expect(throws: QueryError.incompatibleFile(file: "no-metadata.sqlite", missing: "metadata")) {
            _ = try LayerFile.open(url, as: layer)
        }
    }

    @Test("a missing table is incompatible", arguments: [
        (Layer.trails, "trails"), (.trails, "trails_fts"), (.trails, "trails_rtree"),
        (.places, "places"), (.places, "places_rtree"),
        (.curvature, "segments"), (.curvature, "corners"), (.curvature, "segments_rtree"),
    ])
    func missingTable(layer: Layer, table: String) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "no-table.sqlite")
        try write(layer, to: url, dropping: table)
        #expect(throws: QueryError.incompatibleFile(file: "no-table.sqlite", missing: table)) {
            _ = try LayerFile.open(url, as: layer)
        }
    }

    @Test("a missing column is incompatible", arguments: [
        (Layer.trails, "metadata.region"), (.places, "metadata.layer"), (.curvature, "metadata.schema_version"),
        (.trails, "trails.ref_rei"), (.trails, "trails.secondary_of"), (.places, "places.rank_score"),
        (.curvature, "segments.start_node"), (.curvature, "corners.exit_m"), (.curvature, "junctions.along_m"),
    ])
    func missingColumn(layer: Layer, column: String) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "no-column.sqlite")
        try write(layer, to: url, dropping: column)
        #expect(throws: QueryError.incompatibleFile(file: "no-column.sqlite", missing: column)) {
            _ = try LayerFile.open(url, as: layer)
        }
    }

    @Test("two metadata rows are corrupt, and so is none", arguments: [2, 0])
    func metadataRows(rows: Int) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "rows.sqlite")
        try write(.trails, to: url, metadataRows: rows)
        #expect(throws: QueryError.corruptData(file: "rows.sqlite", detail: "metadata has \(rows) rows, not 1")) {
            _ = try LayerFile.open(url, as: .trails)
        }
    }

    @Test("an extra column is accepted", arguments: layers)
    func extraColumn(layer: Layer) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "extra.sqlite")
        try write(layer, to: url)
        try LayerFileWriter.execute("""
            ALTER TABLE \(layer.mainTable) ADD COLUMN colour TEXT;
            ALTER TABLE metadata ADD COLUMN build_host TEXT;
            CREATE TABLE future (id INTEGER PRIMARY KEY);
            """, in: url)
        let file = try LayerFile.open(url, as: layer)
        #expect(file.region == "synthetic")
        #expect(file.rowCount == Self.writtenRows(layer))
    }

    @Test("a curvature file without junctions or the junction column opens", arguments: [
        (false, false), (false, true), (true, false), (true, true),
    ])
    func optionalJunctions(table: Bool, column: Bool) throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "older-curvature.v1.sqlite")
        try LayerFileWriter.curvature(
            segments: [SegmentRow(id: 7, startNode: 1, endNode: 2, coordinates: [Self.point(12.25, 46.1), Self.point(12.26, 46.1)])],
            junctions: table ? [JunctionRow(segmentID: 7, node: 3, along: 10)] : nil, junctionColumn: column, to: url)
        let file = try LayerFile.open(url, as: .curvature)
        #expect(file.hasJunctions == table)
        #expect(file.hasJunctionColumn == column)
        #expect(file.rowCount == 1)
    }

    // MARK: damaged and missing files

    @Test("random bytes are corrupt")
    func randomBytes() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "noise.sqlite")
        try Data((0..<8192).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) }).write(to: url)
        let error = #expect(throws: QueryError.self) { _ = try LayerFile.open(url, as: .trails) }
        guard case .corruptData(let file, _)? = error else {
            Issue.record("expected corruptData, got \(String(describing: error))")
            return
        }
        #expect(file == "noise.sqlite")
    }

    @Test("a truncated file is corrupt")
    func truncatedFile() throws {
        let directory = try TemporaryDirectory()
        let data = try Data(contentsOf: fixture(.curvature))
        let url = directory.url.appending(path: "cut.sqlite")
        try data.prefix(data.count / 2).write(to: url)
        let error = #expect(throws: QueryError.self) {
            let file = try LayerFile.open(url, as: .curvature)
            _ = try count("corners", in: file)
        }
        guard case .corruptData(let file, _)? = error else {
            Issue.record("expected corruptData, got \(String(describing: error))")
            return
        }
        #expect(file == "cut.sqlite")
    }

    @Test("a missing file cannot be opened")
    func missingFile() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "missing.sqlite")
        #expect(throws: QueryError.cannotOpen(file: "missing.sqlite")) { _ = try LayerFile.open(url, as: .trails) }
        #expect(try listing(directory.url).isEmpty)
    }

    @Test("a URL that is not a local file cannot be opened")
    func remoteURL() throws {
        let url = try #require(URL(string: "https://github.com/lucavallin/maqs/releases/latest/download/test-trails.v1.sqlite"))
        #expect(throws: QueryError.cannotOpen(file: "test-trails.v1.sqlite")) { _ = try LayerFile.open(url, as: .trails) }
    }

    @Test("paths with a space, #, ? and % open")
    func awkwardPaths() throws {
        let directory = try TemporaryDirectory()
        let subdirectory = directory.url.appending(path: "x y", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let url = try copy(.trails, to: subdirectory, as: "a b#c?d%e.sqlite")
        #expect(try listing(subdirectory) == ["a b#c?d%e.sqlite"])
        let file = try LayerFile.open(url, as: .trails)
        #expect(file.fileName == "a b#c?d%e.sqlite")
        #expect(file.region == "test")
        #expect(try count("trails", in: file) == Int64(file.rowCount))
        #expect(try listing(directory.url) == ["x y"])
        #expect(try listing(subdirectory) == ["a b#c?d%e.sqlite"])
    }

    @Test("opening and querying leaves no -wal, -shm or -journal file")
    func noSideFiles() throws {
        let directory = try TemporaryDirectory()
        let names = Set(Self.layers.map { "region-\($0.rawValue).v1.sqlite" })
        do {
            let trails = try LayerFile.open(copy(.trails, to: directory.url, as: "region-trails.v1.sqlite"), as: .trails)
            let places = try LayerFile.open(copy(.places, to: directory.url, as: "region-places.v1.sqlite"), as: .places)
            let roads = try LayerFile.open(copy(.curvature, to: directory.url, as: "region-curvature.v1.sqlite"), as: .curvature)
            let search = try trails.connection.prepare("SELECT rowid FROM trails_fts WHERE trails_fts MATCH ?1")
            try search.bind("dolo*", at: 1)
            while try search.step() {}
            let area = try places.connection.prepare(
                "SELECT id FROM places_rtree WHERE max_lon >= ?1 AND min_lon <= ?2 AND max_lat >= ?3 AND min_lat <= ?4")
            for (index, bound) in [12.0, 12.5, 46.0, 46.2].enumerated() {
                try area.bind(bound, at: Int32(index + 1))
            }
            while try area.step() {}
            #expect(try count("corners", in: roads) > 0)
            #expect(try count("junctions", in: roads) > 0)
            #expect(try listing(directory.url) == names)
        }
        #expect(try listing(directory.url) == names)
    }

    // MARK: several files

    @Test("duplicate regions are rejected")
    func duplicateRegions() throws {
        let directory = try TemporaryDirectory()
        let first = try copy(.places, to: directory.url, as: "one.sqlite")
        let second = try copy(.places, to: directory.url, as: "two.sqlite")
        #expect(throws: QueryError.duplicateRegion("test")) { _ = try LayerFile.openAll([first, second], as: .places) }
    }

    @Test("openAll opens all or none")
    func openAllOrNone() throws {
        let directory = try TemporaryDirectory()
        let first = directory.url.appending(path: "a-trails.v1.sqlite")
        let second = directory.url.appending(path: "b-trails.v1.sqlite")
        let bad = directory.url.appending(path: "c-places.v1.sqlite")
        try write(.trails, to: first, region: "a")
        try write(.trails, to: second, region: "b")
        try write(.places, to: bad, region: "c")
        let files = try LayerFile.openAll([first, second], as: .trails)
        #expect(files.map(\.fileName) == ["a-trails.v1.sqlite", "b-trails.v1.sqlite"])
        #expect(files.map(\.region) == ["a", "b"])
        #expect(throws: QueryError.wrongLayer(file: "c-places.v1.sqlite", expected: "trails", found: "places")) {
            _ = try LayerFile.openAll([first, bad, second], as: .trails)
        }
        #expect(try LayerFile.openAll([], as: .trails).isEmpty)
    }

    // MARK: errors

    @Test("the error names only the file")
    func errorsNameOnlyTheFile() throws {
        let directory = try TemporaryDirectory()
        let nested = directory.url.appending(path: "Application Support/maqs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let versionTwo = nested.appending(path: "v2.sqlite")
        try write(.places, to: versionTwo, schemaVersion: 2)
        let noRTree = nested.appending(path: "no-rtree.sqlite")
        try write(.curvature, to: noRTree, dropping: "segments_rtree")
        let noise = nested.appending(path: "noise.sqlite")
        try Data(repeating: 0x5A, count: 4096).write(to: noise)
        let cases: [(URL, Layer)] = [
            (nested.appending(path: "missing.sqlite"), .trails),
            (try copy(.places, to: nested, as: "places.sqlite"), .trails),
            (versionTwo, .places),
            (noRTree, .curvature),
            (noise, .trails),
        ]
        for (url, layer) in cases {
            let error = #expect(throws: QueryError.self) { _ = try LayerFile.open(url, as: layer) }
            let file = error.flatMap(Self.fileName(of:))
            #expect(file == url.lastPathComponent)
            #expect(file?.contains("/") == false)
            #expect(error?.errorDescription?.contains(directory.url.path(percentEncoded: false)) == false)
        }
    }

    @Test("the SQLite mapping")
    func sqliteMapping() {
        for code: Int32 in [266, 6922, 3, 14] {
            #expect(QueryError.sqlite(code, file: "f.sqlite") == .unreadable(file: "f.sqlite"))
        }
        for code: Int32 in [522, 11, 26] {
            #expect(QueryError.sqlite(code, file: "f.sqlite") == .corruptData(file: "f.sqlite", detail: "SQLite result code \(code)"))
        }
    }

    // MARK: Review Focus 4: a file removed or replaced after opening

    /// How a file goes away under an open reader: `MaqsCore` removes a pack with `FileManager.removeItem` and installs
    /// an update with `rename(2)` over the old file.
    enum Change: String, CaseIterable, Sendable {
        case removed, replaced
    }

    /// Removes the file at `url`, or renames a synthetic curvature file of the same region over it.
    private func apply(_ change: Change, to url: URL, in directory: URL) throws {
        switch change {
        case .removed:
            try FileManager.default.removeItem(at: url)
        case .replaced:
            let replacement = directory.appending(path: "replacement.sqlite")
            try write(.curvature, to: replacement, region: "test")
            #expect(rename(replacement.path(percentEncoded: false), url.path(percentEncoded: false)) == 0)
        }
    }

    private func segmentName(_ id: Int64, in file: LayerFile) throws -> String? {
        let statement = try file.connection.prepare("SELECT name FROM segments WHERE id = ?1")
        defer { statement.reset() }
        try statement.bind(id, at: 1)
        guard try statement.step() else { return nil }
        return statement.text(at: 0)
    }

    // Apple's libsqlite3 invalidates a connection whose file is unlinked or renamed over, from a dispatch worker: a read
    // that misses the page cache afterwards fails with SQLITE_IOERR_VNODE. Whether a read comes before or after that is
    // not deterministic, so each read must give the old file's rows or `unreadable`, and nothing else.
    @Test("a removed or replaced file answers or throws unreadable", arguments: Change.allCases)
    func changedFile(change: Change) throws {
        let directory = try TemporaryDirectory()
        let original = try LayerFile.open(fixture(.curvature), as: .curvature)
        // Opening reads the schema, the metadata and the segments table, so these four miss the page cache.
        var expected: [(table: String, rows: Int64)] = []
        for table in ["corners", "junctions", "corners_rtree", "segments_rtree"] {
            expected.append((table, try count(table, in: original)))
        }
        let url = try copy(.curvature, to: directory.url, as: "region-curvature.v1.sqlite")
        let file = try LayerFile.open(url, as: .curvature)
        try apply(change, to: url, in: directory.url)
        for (table, rows) in expected {
            do {
                #expect(try count(table, in: file) == rows, "\(table)")
            } catch let error as QueryError {
                #expect(error == .unreadable(file: "region-curvature.v1.sqlite"), "\(table)")
            } catch {
                Issue.record("\(table): unexpected \(error)")
            }
        }
    }

    @Test("setFiles with the replacement answers from the new file")
    func reopenedSet() throws {
        let directory = try TemporaryDirectory()
        let url = try copy(.curvature, to: directory.url, as: "test-curvature.v1.sqlite")
        let old = try LayerFile.openAll([url], as: .curvature)
        let oldName = try segmentName(1, in: old[0])
        try apply(.replaced, to: url, in: directory.url)
        // The old set stays open while the new one opens, as a reader's setFiles does.
        let new = try LayerFile.openAll([url], as: .curvature)
        #expect(new.map(\.region) == ["test"])
        #expect(new[0].rowCount == Self.writtenRows(.curvature))
        #expect(try segmentName(1, in: new[0]) == "Via Nevegal")
        #expect(oldName != "Via Nevegal")
        #expect(try count("corners", in: new[0]) == 1)
        withExtendedLifetime(old) {}
    }
}
