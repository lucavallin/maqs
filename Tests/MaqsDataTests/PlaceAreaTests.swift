import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsData

@Suite struct PlaceAreaTests {
    private static func point(_ lon: Double, _ lat: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func fixturePlaces() throws -> Places {
        try Places(files: [Fixtures.url("test/test-places.v1.sqlite")])
    }

    private func wholeFixture() throws -> QueryArea {
        try QueryArea(minLongitude: 12.0, minLatitude: 46.0, maxLongitude: 12.5, maxLatitude: 46.2)
    }

    // MARK: Fixture

    @Test("the fixture's places come highest rank_score first, ties by feature id")
    func fixtureOrder() async throws {
        let found = try await fixturePlaces().places(in: wholeFixture(), limit: 5_000)
        #expect(found.count == 22)
        #expect(found.map(\.rankScore) == found.map(\.rankScore).sorted(by: >))
        #expect(found.first?.featureID == 22)
        #expect(found.prefix(4).map(\.featureID) == [22, 1, 2, 3])
    }

    @Test("kinds keeps only those kinds")
    func fixtureKinds() async throws {
        let found = try await fixturePlaces().places(in: wholeFixture(), kinds: [.peak])
        #expect(found.map(\.featureID) == [22, 19, 15])
        let settlements = try await fixturePlaces().places(in: wholeFixture(), kinds: [.village])
        #expect(Set(settlements.map(\.featureID)) == [1, 2, 6, 11])
        #expect(try await fixturePlaces().places(in: wholeFixture(), kinds: []).isEmpty)
    }

    @Test("a small area holds only the places inside it")
    func fixtureSmallArea() async throws {
        let area = try QueryArea(minLongitude: 12.27, minLatitude: 46.08, maxLongitude: 12.29, maxLatitude: 46.13)
        let found = try await fixturePlaces().places(in: area)
        #expect(Set(found.map(\.featureID)) == [12, 17, 19, 20, 22])
    }

    @Test("an area that meets nothing gives an empty list")
    func fixtureEmptyArea() async throws {
        let area = try QueryArea(minLongitude: 0, minLatitude: 0, maxLongitude: 1, maxLatitude: 1)
        #expect(try await fixturePlaces().places(in: area).isEmpty)
    }

    @Test("limit keeps the highest ranked places")
    func fixtureLimit() async throws {
        let found = try await fixturePlaces().places(in: wholeFixture(), limit: 2)
        #expect(found.map(\.featureID) == [22, 1])
    }

    @Test("a limit outside 1 to 5000 is invalidInput", arguments: [0, -1, 5_001])
    func limitRange(limit: Int) async throws {
        let places = try fixturePlaces()
        let area = try wholeFixture()
        await #expect(throws: QueryError.invalidInput("limit must be within 1...5000")) {
            try await places.places(in: area, limit: limit)
        }
    }

    @Test("the limits 1 and 5000 are accepted")
    func limitBounds() async throws {
        let places = try fixturePlaces()
        let area = try wholeFixture()
        #expect(try await places.places(in: area, limit: 1).count == 1)
        #expect(try await places.places(in: area, limit: 5_000).count == 22)
    }

    // MARK: Lookup

    @Test("a place is found by id and by region and feature id, with every field")
    func fixtureLookup() async throws {
        let places = try fixturePlaces()
        let byID = try await places.place(PlaceID(osmType: "node", osmID: 12_168_904_789))
        let byRow = try await places.place(region: "test", featureID: 19)
        #expect(byID == byRow)
        let panada = try #require(byID)
        #expect(panada.name == "Col Panada")
        #expect(panada.kind == .peak)
        #expect(panada.elevation == 921)
        #expect(panada.region == "test")
        #expect(panada.featureID == 19)
        #expect(panada.rankScore == 921)
        #expect(panada.coordinate.longitude == 12.27967)
        #expect(panada.coordinate.latitude == 46.1231389)
    }

    @Test("an unknown id, row or region is nil")
    func unknownIsNil() async throws {
        let places = try fixturePlaces()
        #expect(try await places.place(PlaceID(osmType: "node", osmID: 999_999)) == nil)
        #expect(try await places.place(PlaceID(osmType: "way", osmID: 12_168_904_789)) == nil)
        #expect(try await places.place(region: "test", featureID: 999_999) == nil)
        #expect(try await places.place(region: "veneto", featureID: 19) == nil)
        #expect(try await Places(files: []).place(PlaceID(osmType: "node", osmID: 1)) == nil)
    }

    // MARK: Synthetic

    @Test("localizedNames holds only the tags the place has")
    func localizedNames() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "places.sqlite")
        try LayerFileWriter.places([
            PlaceRow(id: 1, kind: "pass", name: "Passo", nameIT: "Passo", nameDE: "Joch", nameSL: "Prelaz", ele: 2_000,
                     wikidata: "Q1", coordinate: Self.point(12, 46), rankScore: 3),
            PlaceRow(id: 2, kind: "hamlet", coordinate: Self.point(12.001, 46.001)),
        ], to: url)
        let places = try Places(files: [url])
        let pass = try #require(try await places.place(region: "synthetic", featureID: 1))
        #expect(pass.localizedNames == ["it": "Passo", "de": "Joch", "sl": "Prelaz"])
        #expect(pass.wikidata == "Q1")
        #expect(pass.kind == .pass)
        let bare = try #require(try await places.place(region: "synthetic", featureID: 2))
        #expect(bare.localizedNames.isEmpty)
        #expect(bare.name == nil)
        #expect(bare.elevation == nil)
        #expect(bare.wikidata == nil)
    }

    @Test("a place in two files comes back once, from the first, in an area and by id")
    func duplicateAcrossFiles() async throws {
        let directory = try TemporaryDirectory()
        let first = directory.url.appending(path: "a.sqlite")
        let second = directory.url.appending(path: "b.sqlite")
        try LayerFileWriter.places([PlaceRow(id: 1, osmID: 50, name: "A", coordinate: Self.point(12, 46), rankScore: 1)],
                                   to: first, region: "alpha")
        try LayerFileWriter.places([
            PlaceRow(id: 4, osmID: 50, name: "B", coordinate: Self.point(12, 46), rankScore: 1),
            PlaceRow(id: 5, osmID: 51, name: "C", coordinate: Self.point(12.001, 46), rankScore: 9),
        ], to: second, region: "beta")
        let places = try Places(files: [first, second])
        let area = try QueryArea(minLongitude: 11.9, minLatitude: 45.9, maxLongitude: 12.1, maxLatitude: 46.1)
        let found = try await places.places(in: area)
        #expect(found.map(\.name) == ["C", "A"])
        #expect(try await places.place(PlaceID(osmType: "node", osmID: 50))?.region == "alpha")
        #expect(try await places.place(region: "beta", featureID: 4)?.name == "B")
    }

    @Test("setFiles swaps the files all or none")
    func setFilesAllOrNone() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "a.sqlite")
        try LayerFileWriter.places([PlaceRow(id: 1, name: "A", coordinate: Self.point(12, 46))], to: url)
        let places = try Places(files: [])
        try await places.setFiles([url])
        #expect(try await places.place(region: "synthetic", featureID: 1)?.name == "A")
        let missing = directory.url.appending(path: "missing.sqlite")
        await #expect(throws: QueryError.cannotOpen(file: "missing.sqlite")) { try await places.setFiles([url, missing]) }
        #expect(try await places.place(region: "synthetic", featureID: 1)?.name == "A")
    }

    @Test("a trails file is refused as a places file")
    func wrongLayer() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "t.sqlite")
        try LayerFileWriter.trails([], to: url)
        #expect(throws: QueryError.wrongLayer(file: "t.sqlite", expected: "places", found: "trails")) {
            try Places(files: [url])
        }
    }
}
