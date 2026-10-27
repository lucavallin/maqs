import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsData

@Suite struct TrailTests {
    private static func point(_ lon: Double, _ lat: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func fixtureTrails() throws -> Trails {
        try Trails(files: [Fixtures.url("test/test-trails.v1.sqlite")])
    }

    private func area(_ minLon: Double, _ minLat: Double, _ maxLon: Double, _ maxLat: Double) throws -> QueryArea {
        try QueryArea(minLongitude: minLon, minLatitude: minLat, maxLongitude: maxLon, maxLatitude: maxLat)
    }

    // MARK: Lookup

    @Test("a trail is found by its id and by region and feature id")
    func lookup() async throws {
        let trails = try fixtureTrails()
        let byID = try #require(await trails.trail(TrailID(source: "osm", sourceID: "relation/14563614")))
        let byFeature = try #require(await trails.trail(region: "test", featureID: 6))
        #expect(byID.summary == byFeature.summary)
        #expect(byID.summary.ref == "2009")
        #expect(byID.summary.from == "Case Caviola")
        #expect(byID.summary.to == "Forcella Zopei")
        #expect(byID.summary.difficulty.grade == 2)
        #expect(byID.summary.geometryStatus == .ordered)
        #expect(byID.summary.length > 6000)
        #expect(byID.osmType == "relation")
        #expect(byID.osmID == 14_563_614)
        #expect(byID.secondaryOf == nil)
        #expect(byID.path.count == 1)
        #expect(byID.path[0].count > 1)
        let box = try #require(byID.summary.area)
        #expect(box.minLongitude < box.maxLongitude)
        #expect(byID.path[0].allSatisfy { $0.longitude >= box.minLongitude - 1e-6 && $0.longitude <= box.maxLongitude + 1e-6 })
    }

    @Test("a trail with gaps has several legs")
    func gaps() async throws {
        let trail = try #require(await fixtureTrails().trail(region: "test", featureID: 4))
        #expect(trail.summary.geometryStatus == .gaps)
        #expect(trail.path.count > 1)
    }

    @Test("an incomplete trail says so")
    func incomplete() async throws {
        let trail = try #require(await fixtureTrails().trail(region: "test", featureID: 1))
        #expect(trail.summary.geometryStatus == .incomplete)
    }

    @Test("a trail with an empty geometry has an empty path and no area")
    func emptyPath() async throws {
        let trail = try #require(await fixtureTrails().trail(region: "test", featureID: 2))
        #expect(trail.path.isEmpty)
        #expect(trail.summary.area == nil)
    }

    @Test("unknown ids give nil")
    func unknown() async throws {
        let trails = try fixtureTrails()
        #expect(try await trails.trail(TrailID(source: "osm", sourceID: "relation/1")) == nil)
        #expect(try await trails.trail(TrailID(source: "x", sourceID: "relation/14563614")) == nil)
        #expect(try await trails.trail(region: "test", featureID: 99) == nil)
        #expect(try await trails.trail(region: "elsewhere", featureID: 6) == nil)
    }

    @Test("a secondary record names its primary")
    func secondary() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "trails.sqlite")
        try LayerFileWriter.trails([
            TrailRow(id: 1, ref: "7"),
            TrailRow(id: 2, source: "sat", sourceID: "7-b", osmType: nil, ref: "7", secondaryOf: 1),
        ], to: url)
        let trail = try #require(await Trails(files: [url]).trail(region: "synthetic", featureID: 2))
        #expect(trail.secondaryOf == TrailID(source: "osm", sourceID: "relation/1"))
        #expect(trail.osmType == nil)
        #expect(trail.osmID == nil)
    }

    @Test("a trail in two files is read from the first")
    func firstFileWins() async throws {
        let directory = try TemporaryDirectory()
        let first = directory.url.appending(path: "a.sqlite")
        let second = directory.url.appending(path: "b.sqlite")
        try LayerFileWriter.trails([TrailRow(id: 1, ref: "7")], to: first, region: "triveneto")
        try LayerFileWriter.trails([TrailRow(id: 5, sourceID: "relation/1", ref: "7")], to: second, region: "veneto")
        let trail = try #require(await Trails(files: [first, second]).trail(TrailID(source: "osm", sourceID: "relation/1")))
        #expect(trail.summary.region == "triveneto")
    }

    @Test("a corrupt geometry is corrupt data naming the file")
    func corruptGeometry() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "broken-trails.sqlite")
        try LayerFileWriter.trails([TrailRow(id: 1, ref: "7", geometry: "!!!")], to: url)
        let trails = try Trails(files: [url])
        do {
            _ = try await trails.trail(region: "synthetic", featureID: 1)
            Issue.record("a corrupt geometry was decoded")
        } catch {
            guard case .corruptData(let file, _) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(file == "broken-trails.sqlite")
        }
    }

    // MARK: Area

    @Test("trails in an area are the primaries whose box meets it, longest first")
    func inArea() async throws {
        let trails = try fixtureTrails()
        let results = try await trails.trails(in: area(12.27, 46.08, 12.29, 46.11))
        #expect(!results.isEmpty)
        #expect(results.map(\.length) == results.map(\.length).sorted(by: >))
        #expect(!results.map(\.featureID).contains(2))
        let nowhere = try await trails.trails(in: area(0, 0, 1, 1))
        #expect(nowhere.isEmpty)
    }

    @Test("an area query honours the limit and the difficulty filter")
    func areaLimit() async throws {
        let trails = try fixtureTrails()
        let whole = try area(11, 45, 13, 47)
        let all = try await trails.trails(in: whole)
        #expect(all.count == 9)
        #expect(try await trails.trails(in: whole, limit: 3).map(\.id) == all.prefix(3).map(\.id))
        let graded = try await trails.trails(in: whole, difficulty: 6...6)
        #expect(graded.map(\.featureID) == [1])
    }

    @Test("an area query rejects limits outside 1...2000 and difficulty outside 1...6")
    func areaInvalid() async throws {
        let trails = try fixtureTrails()
        let whole = try area(11, 45, 13, 47)
        for limit in [0, 2001] {
            await #expect(throws: QueryError.self) { try await trails.trails(in: whole, limit: limit) }
        }
        await #expect(throws: QueryError.self) { try await trails.trails(in: whole, difficulty: 0...6) }
        #expect(try await trails.trails(in: whole, limit: 2000).count == 9)
    }

    @Test("secondaries are left out of area queries and a trail in two files counts once")
    func areaSecondariesAndDuplicates() async throws {
        let directory = try TemporaryDirectory()
        let first = directory.url.appending(path: "a.sqlite")
        let second = directory.url.appending(path: "b.sqlite")
        let legs = [[Self.point(12, 46), Self.point(12.01, 46.01)]]
        try LayerFileWriter.trails([
            TrailRow(id: 1, ref: "7", length: 100, legs: legs),
            TrailRow(id: 2, ref: "7", length: 900, legs: legs, secondaryOf: 1),
        ], to: first, region: "triveneto")
        try LayerFileWriter.trails([TrailRow(id: 4, sourceID: "relation/1", ref: "7", length: 100, legs: legs)],
                                   to: second, region: "veneto")
        let results = try await Trails(files: [first, second]).trails(in: area(11, 45, 13, 47))
        #expect(results.map(\.featureID) == [1])
        #expect(results.map(\.region) == ["triveneto"])
    }

    // MARK: QueryArea

    @Test("QueryArea rejects NaN, infinity, inverted bounds and latitudes beyond the poles")
    func areaValidation() {
        let rejected: [(Double, Double, Double, Double)] = [
            (.nan, 0, 1, 1), (0, 0, .infinity, 1), (2, 0, 1, 1), (0, 2, 1, 1), (0, 0, 0, 1), (0, 0, 1, 91),
            (0, -91, 1, 1), (-181, 0, 1, 1), (0, 0, 181, 1),
        ]
        for (minLon, minLat, maxLon, maxLat) in rejected {
            do {
                _ = try QueryArea(minLongitude: minLon, minLatitude: minLat, maxLongitude: maxLon, maxLatitude: maxLat)
                Issue.record("\((minLon, minLat, maxLon, maxLat)) was accepted")
            } catch {
                guard case .invalidInput = error else {
                    Issue.record("unexpected \(error)")
                    continue
                }
            }
        }
        #expect((try? QueryArea(minLongitude: -180, minLatitude: -90, maxLongitude: 180, maxLatitude: 90)) != nil)
    }

    // MARK: Files

    @Test("no files gives empty results and nil")
    func noFiles() async throws {
        let trails = try Trails(files: [])
        #expect(try await trails.search("2005").isEmpty)
        #expect(try await trails.trails(in: area(11, 45, 13, 47)).isEmpty)
        #expect(try await trails.trail(TrailID(source: "osm", sourceID: "relation/1")) == nil)
        #expect(try await trails.trail(region: "test", featureID: 1) == nil)
    }

    @Test("setFiles failure keeps the old files")
    func setFilesFailure() async throws {
        let trails = try fixtureTrails()
        let directory = try TemporaryDirectory()
        await #expect(throws: QueryError.self) {
            try await trails.setFiles([Fixtures.url("test/test-trails.v1.sqlite"), directory.url.appending(path: "missing.sqlite")])
        }
        #expect(try await trails.search("2005").map(\.featureID) == [3])
    }

    @Test("setFiles with other files answers from them")
    func setFiles() async throws {
        let trails = try fixtureTrails()
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "other.sqlite")
        try LayerFileWriter.trails([TrailRow(id: 1, ref: "555")], to: url)
        try await trails.setFiles([url])
        #expect(try await trails.search("2005").isEmpty)
        #expect(try await trails.search("555").map(\.featureID) == [1])
        try await trails.setFiles([])
        #expect(try await trails.search("555").isEmpty)
    }

    @Test("files of another layer are rejected")
    func wrongLayer() throws {
        #expect(throws: QueryError.self) { try Trails(files: [Fixtures.url("test/test-places.v1.sqlite")]) }
    }
}
