import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsData

@Suite struct TrailSearchTests {
    private static func point(_ lon: Double, _ lat: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// A short leg starting at `lon`, `lat`, so each trail has its own bounding box.
    private static func leg(_ lon: Double, _ lat: Double = 46) -> [[CLLocationCoordinate2D]] {
        [[point(lon, lat), point(lon + 0.01, lat + 0.01)]]
    }

    private func fixtureTrails() throws -> Trails {
        try Trails(files: [Fixtures.url("test/test-trails.v1.sqlite")])
    }

    private func synthetic(_ rows: [TrailRow], in directory: TemporaryDirectory, region: String = "synthetic",
                           name: String = "trails.sqlite") throws -> URL {
        let url = directory.url.appending(path: name)
        try LayerFileWriter.trails(rows, to: url, region: region)
        return url
    }

    private func ids(_ results: [TrailSummary]) -> [Int64] {
        results.map(\.featureID)
    }

    // MARK: Fixture

    @Test("a name equal to the text is found in tier 1")
    func fixtureName() async throws {
        let results = try await fixtureTrails().search("2005")
        #expect(ids(results) == [3])
        #expect(results[0].name == "2005")
        #expect(results[0].id == TrailID(source: "osm", sourceID: "relation/14549476"))
        #expect(results[0].region == "test")
    }

    @Test("a ref equal to the text is found")
    func fixtureRef() async throws {
        #expect(ids(try await fixtureTrails().search("2009")) == [6])
    }

    @Test("a number inside CdD27 is found in tier 2 and not CdD28")
    func fixtureNumberInRef() async throws {
        #expect(ids(try await fixtureTrails().search("27")) == [9])
    }

    @Test("a name prefix is found by full-text search")
    func fixtureFullText() async throws {
        let results = try await fixtureTrails().search("cammino dolo")
        #expect(Set(ids(results)) == [2, 9, 10])
        #expect(ids(results) == [2, 9, 10])
    }

    // MARK: Tiers and order

    @Test("tiers come in order and a trail appears once")
    func tierOrder() async throws {
        let directory = try TemporaryDirectory()
        let url = try synthetic([
            TrailRow(id: 1, ref: "9260", legs: Self.leg(12)),
            TrailRow(id: 2, ref: "1926", legs: Self.leg(12)),
            TrailRow(id: 3, name: "Sentiero 926", legs: Self.leg(12)),
            TrailRow(id: 4, ref: "926/1", legs: Self.leg(12)),
            TrailRow(id: 5, ref: "E926", legs: Self.leg(12)),
            TrailRow(id: 6, ref: "926A", legs: Self.leg(12)),
            TrailRow(id: 7, ref: "926", legs: Self.leg(12)),
        ], in: directory)
        let results = try await Trails(files: [url]).search("926")
        #expect(ids(results) == [7, 4, 5, 6, 1, 3])
    }

    @Test("a ref_rei equal to the text is found in tier 1, ignoring case")
    func referenceCase() async throws {
        let directory = try TemporaryDirectory()
        let url = try synthetic([TrailRow(id: 1, refREI: "ab12", legs: Self.leg(12))], in: directory)
        #expect(ids(try await Trails(files: [url]).search("AB12")) == [1])
    }

    @Test("the trail whose box is nearest comes first within a tier and trails without geometry last")
    func nearOrder() async throws {
        let directory = try TemporaryDirectory()
        let url = try synthetic([
            TrailRow(id: 1, ref: "10", legs: Self.leg(12.0)),
            TrailRow(id: 2, ref: "10", legs: Self.leg(12.5)),
            TrailRow(id: 3, ref: "10"),
            TrailRow(id: 4, ref: "10", legs: Self.leg(13.0)),
        ], in: directory)
        let trails = try Trails(files: [url])
        #expect(ids(try await trails.search("10", near: Self.point(12.49, 46.005))) == [2, 1, 4, 3])
        #expect(ids(try await trails.search("10", near: Self.point(13.0, 46.0))) == [4, 2, 1, 3])
        #expect(ids(try await trails.search("10")) == [1, 2, 3, 4])
    }

    @Test("accents are ignored by full-text search")
    func accents() async throws {
        let directory = try TemporaryDirectory()
        let url = try synthetic([TrailRow(id: 1, name: "Giro del Pèlmo", legs: Self.leg(12))], in: directory)
        #expect(ids(try await Trails(files: [url]).search("Pelmo")) == [1])
    }

    @Test("the difficulty filter leaves out ungraded trails and other grades")
    func difficulty() async throws {
        let directory = try TemporaryDirectory()
        let url = try synthetic([
            TrailRow(id: 1, ref: "5", difficulty: 2, legs: Self.leg(12)),
            TrailRow(id: 2, ref: "5", difficulty: 3, legs: Self.leg(12)),
            TrailRow(id: 3, ref: "5", legs: Self.leg(12)),
            TrailRow(id: 4, ref: "5", difficulty: 5, legs: Self.leg(12)),
        ], in: directory)
        let trails = try Trails(files: [url])
        #expect(ids(try await trails.search("5", difficulty: 2...3)) == [1, 2])
        #expect(ids(try await trails.search("5")) == [1, 2, 3, 4])
    }

    @Test("secondaries are left out of search")
    func secondaries() async throws {
        let directory = try TemporaryDirectory()
        let url = try synthetic([
            TrailRow(id: 1, ref: "7", legs: Self.leg(12)),
            TrailRow(id: 2, ref: "7", legs: Self.leg(12), secondaryOf: 1),
        ], in: directory)
        #expect(ids(try await Trails(files: [url]).search("7")) == [1])
    }

    @Test("a relation in two files gives one result, from the first file")
    func twoFiles() async throws {
        let directory = try TemporaryDirectory()
        let first = try synthetic([TrailRow(id: 1, ref: "7", legs: Self.leg(12))], in: directory,
                                  region: "triveneto", name: "a.sqlite")
        let second = try synthetic([TrailRow(id: 9, sourceID: "relation/1", ref: "7", legs: Self.leg(12))],
                                   in: directory, region: "veneto", name: "b.sqlite")
        let results = try await Trails(files: [first, second]).search("7")
        #expect(ids(results) == [1])
        #expect(results.map(\.region) == ["triveneto"])
    }

    @Test("the limit is respected")
    func limit() async throws {
        let directory = try TemporaryDirectory()
        let rows = (1...5).map { TrailRow(id: Int64($0), ref: "3", legs: Self.leg(12)) }
        let trails = try Trails(files: [synthetic(rows, in: directory)])
        #expect(ids(try await trails.search("3", limit: 2)) == [1, 2])
    }

    @Test("an empty or blank text gives nothing")
    func emptyText() async throws {
        let trails = try fixtureTrails()
        for text in ["", "   ", "\n\t "] {
            #expect(try await trails.search(text).isEmpty)
        }
    }

    // MARK: Invalid input

    @Test("a limit outside 1...500 is invalid input")
    func invalidLimit() async throws {
        let trails = try fixtureTrails()
        for limit in [0, 501, -1] {
            await #expect(throws: QueryError.self) { try await trails.search("2005", limit: limit) }
        }
        #expect(try await trails.search("2005", limit: 500).count == 1)
    }

    @Test("a difficulty range outside 1...6 is invalid input")
    func invalidDifficulty() async throws {
        let trails = try fixtureTrails()
        for range in [0...7, 0...3, 2...7] {
            await #expect(throws: QueryError.self) { try await trails.search("2005", difficulty: range) }
        }
    }

    @Test("a position without a fix is invalid input, never an empty answer")
    func invalidNear() async throws {
        let trails = try fixtureTrails()
        let positions = [
            kCLLocationCoordinate2DInvalid,
            Self.point(.nan, 46),
            Self.point(12, .infinity),
            Self.point(181, 46),
        ]
        for position in positions {
            do {
                _ = try await trails.search("2005", near: position)
                Issue.record("\(position) was accepted")
            } catch {
                guard case .invalidInput = error else {
                    Issue.record("\(position): unexpected \(error)")
                    continue
                }
            }
        }
    }

    // MARK: FTS-hostile text

    @Test("full-text syntax in the text never throws", arguments: [
        "\"", "*", "-", "'", "NEAR(", "AND", "—", "a\"b", "x*", "\"*\"", ":", "^", "OR", "(", ")", "name:alta",
        "alta AND", "alta \"", "* alta", "alta —",
    ])
    func hostileText(_ text: String) async throws {
        let directory = try TemporaryDirectory()
        let url = try synthetic([
            TrailRow(id: 1, name: "Alta Via", legs: Self.leg(12)),
            TrailRow(id: 2, name: "x", legs: Self.leg(12)),
        ], in: directory)
        let results = try await Trails(files: [url]).search(text)
        #expect(results.allSatisfy { [1, 2].contains($0.featureID) })
    }

    @Test("text with no words of the data gives nothing")
    func punctuationOnly() async throws {
        let directory = try TemporaryDirectory()
        let url = try synthetic([TrailRow(id: 1, name: "Alta Via", legs: Self.leg(12))], in: directory)
        let trails = try Trails(files: [url])
        for text in ["\"", "*", "-", "'", "NEAR(", "AND", "—", "a\"b"] {
            #expect(try await trails.search(text).isEmpty, "\(text)")
        }
    }

    // MARK: Statements

    @Test("an FTS5 syntax error is reported with SQLITE_ERROR and a failure reset clears it")
    func syntaxErrorCode() throws {
        let files = try LayerFile.openAll([Fixtures.url("test/test-trails.v1.sqlite")], as: .trails)
        let statement = try files[0].connection.prepare("SELECT rowid FROM trails_fts WHERE trails_fts MATCH ?1")
        try statement.bind("\"unterminated" as String?, at: 1)
        #expect(throws: QueryError.self) { try statement.step() }
        #expect(statement.failureCode & 0xFF == 1)
        statement.reset()
        #expect(statement.failureCode == 0)
    }

    @Test("tier 3 gives no match for an expression FTS5 rejects, and still throws for a damaged file")
    func syntaxErrorIsNoMatch() throws {
        let files = try LayerFile.openAll([Fixtures.url("test/test-trails.v1.sqlite")], as: .trails)
        #expect(try TrailSearch.fullText("\"unterminated", in: files[0], index: 0, difficulty: nil).isEmpty)
        #expect(try TrailSearch.fullText("\"cammino\"*", in: files[0], index: 0, difficulty: nil).count == 3)
    }

    @Test("preparing the text of a statement that is mid-read gives another statement")
    func nestedPrepare() throws {
        let files = try LayerFile.openAll([Fixtures.url("test/test-trails.v1.sqlite")], as: .trails)
        let connection = files[0].connection
        let sql = "SELECT id FROM trails ORDER BY id"
        let outer = try connection.prepare(sql)
        var seen: [Int64] = []
        while try outer.step() {
            seen.append(outer.int64(at: 0))
            if seen.count == 1 {
                let inner = try connection.prepare(sql)
                #expect(inner !== outer)
                var innerCount = 0
                while try inner.step() { innerCount += 1 }
                #expect(innerCount == 10)
            }
        }
        #expect(seen == Array(1...10))
        // Once finished, the cached statement is handed out again.
        outer.reset()
        #expect(try connection.prepare(sql) === outer)
    }
}
