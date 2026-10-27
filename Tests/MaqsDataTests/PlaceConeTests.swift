import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsData

@Suite struct PlaceConeTests {
    private static let origin = CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25)

    /// The point `distance` metres from `start` along the great circle that leaves it at `bearing` degrees.
    private static func destination(from start: CLLocationCoordinate2D, bearing: Double, distance: Double)
        -> CLLocationCoordinate2D {
        let angular = distance / Geodesy.radius
        let theta = bearing * .pi / 180
        let latitude = start.latitude * .pi / 180
        let longitude = start.longitude * .pi / 180
        let newLatitude = asin(sin(latitude) * cos(angular) + cos(latitude) * sin(angular) * cos(theta))
        let newLongitude = longitude
            + atan2(sin(theta) * sin(angular) * cos(latitude), cos(angular) - sin(latitude) * sin(newLatitude))
        // Wrapped into -180...180, as a file stores it.
        let wrapped = (newLongitude * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
        return CLLocationCoordinate2D(latitude: newLatitude * 180 / .pi, longitude: wrapped)
    }

    private static func place(_ id: Int64, bearing: Double, distance: Double, kind: String = "peak", rank: Double = 0,
                              from start: CLLocationCoordinate2D = origin) -> PlaceRow {
        PlaceRow(id: id, kind: kind, name: "P\(id)", coordinate: destination(from: start, bearing: bearing, distance: distance),
                 rankScore: rank)
    }

    private func reader(_ rows: [PlaceRow], in directory: TemporaryDirectory) throws -> Places {
        let url = directory.url.appending(path: "places.sqlite")
        try LayerFileWriter.places(rows, to: url)
        return try Places(files: [url])
    }

    private func cone(_ bearing: Double, halfAngle: Double = 5, maxDistance: Double = 100_000,
                      from start: CLLocationCoordinate2D = origin) throws -> BearingCone {
        try BearingCone(origin: start, bearing: bearing, halfAngle: halfAngle, maxDistance: maxDistance)
    }

    // MARK: Cone edges

    @Test("a place 4.9 degrees off is inside and one 5.1 degrees off is outside")
    func angleEdges() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            Self.place(1, bearing: 94.9, distance: 10_000), Self.place(2, bearing: 95.1, distance: 10_000),
            Self.place(3, bearing: 85.1, distance: 10_000), Self.place(4, bearing: 84.9, distance: 10_000),
        ], in: directory)
        let found = try await places.places(in: cone(90))
        #expect(Set(found.map(\.place.featureID)) == [1, 3])
    }

    @Test("a place exactly halfAngle off is inside, on either side")
    func angleInclusive() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([Self.place(1, bearing: 95, distance: 10_000), Self.place(2, bearing: 85, distance: 10_000)],
                                in: directory)
        let found = try await places.places(in: cone(90))
        #expect(Set(found.map(\.place.featureID)) == [1, 2])
    }

    @Test("a place exactly at maxDistance is inside and one 1 m beyond is outside")
    func distanceEdges() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            Self.place(1, bearing: 90, distance: 20_000), Self.place(2, bearing: 90, distance: 20_001),
            Self.place(3, bearing: 90, distance: 19_999),
        ], in: directory)
        let found = try await places.places(in: cone(90, maxDistance: 20_000))
        #expect(found.map(\.place.featureID) == [3, 1])
    }

    @Test("a cone that points at 358 degrees finds a place at 2 degrees")
    func wrapAround() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            Self.place(1, bearing: 2, distance: 10_000), Self.place(2, bearing: 358, distance: 12_000),
            Self.place(3, bearing: 8, distance: 10_000),
        ], in: directory)
        let found = try await places.places(in: cone(358))
        #expect(found.map(\.place.featureID) == [1, 2])
        #expect(abs(found[0].offset - 4) < 1e-6)
        #expect(abs(found[1].offset) < 1e-6)
        #expect(abs(found[0].bearing - 2) < 1e-6)
    }

    @Test("a bearing outside 0 to 360 is normalised")
    func bearingNormalised() throws {
        #expect(try cone(-90).bearing == 270)
        #expect(try cone(450).bearing == 90)
        #expect(try cone(360).bearing == 0)
        #expect(try cone(-1e-20).bearing == 0)
    }

    @Test("a halfAngle of 180 finds every place within reach, behind the origin too")
    func fullCircle() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            Self.place(1, bearing: 0, distance: 3_000), Self.place(2, bearing: 120, distance: 5_000),
            Self.place(3, bearing: 240, distance: 7_000), Self.place(4, bearing: 300, distance: 100_001),
        ], in: directory)
        let found = try await places.places(in: cone(0, halfAngle: 180))
        #expect(found.map(\.place.featureID) == [1, 2, 3])
    }

    @Test("a place under 1 m from the origin is left out")
    func tooClose() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            Self.place(1, bearing: 90, distance: 0.5), Self.place(2, bearing: 90, distance: 1.5),
        ], in: directory)
        let found = try await places.places(in: cone(90, halfAngle: 180))
        #expect(found.map(\.place.featureID) == [2])
    }

    @Test("the offset is negative to the left and positive to the right")
    func offsetSign() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            Self.place(1, bearing: 87, distance: 10_000), Self.place(2, bearing: 93, distance: 11_000),
        ], in: directory)
        let found = try await places.places(in: cone(90))
        #expect(abs(found[0].offset + 3) < 1e-6)
        #expect(abs(found[1].offset - 3) < 1e-6)
        let first = found[0]
        #expect(abs(first.distance - 10_000) < 1e-3)
    }

    // MARK: Limit, kinds, duplicates

    @Test("limit keeps the highest rank_score, then sorts nearest first")
    func limitKeepsRank() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            Self.place(1, bearing: 90, distance: 5_000, rank: 1), Self.place(2, bearing: 90, distance: 9_000, rank: 50),
            Self.place(3, bearing: 90, distance: 7_000, rank: 30), Self.place(4, bearing: 90, distance: 3_000, rank: 2),
        ], in: directory)
        let found = try await places.places(in: cone(90), limit: 2)
        #expect(found.map(\.place.featureID) == [3, 2])
    }

    @Test("a rank tie at the limit is broken by the lower feature id")
    func limitTie() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            Self.place(7, bearing: 90, distance: 3_000, rank: 5), Self.place(3, bearing: 90, distance: 9_000, rank: 5),
            Self.place(5, bearing: 90, distance: 6_000, rank: 5),
        ], in: directory)
        let found = try await places.places(in: cone(90), limit: 2)
        #expect(found.map(\.place.featureID) == [5, 3])
    }

    @Test("kinds keeps only those kinds")
    func kindsFilter() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([
            Self.place(1, bearing: 90, distance: 1_000, kind: "peak"), Self.place(2, bearing: 90, distance: 2_000, kind: "pass"),
            Self.place(3, bearing: 90, distance: 3_000, kind: "alpine_hut"),
        ], in: directory)
        let found = try await places.places(in: cone(90), kinds: [.pass, .alpineHut])
        #expect(found.map(\.place.featureID) == [2, 3])
        #expect(try await places.places(in: cone(90), kinds: []).isEmpty)
    }

    @Test("an unknown kind reads as other")
    func unknownKind() async throws {
        let directory = try TemporaryDirectory()
        let places = try reader([Self.place(1, bearing: 90, distance: 1_000, kind: "refuge")], in: directory)
        let found = try await places.places(in: cone(90))
        #expect(found.map(\.place.kind) == [.other("refuge")])
        #expect(try await places.places(in: cone(90), kinds: [.other("refuge")]).count == 1)
    }

    @Test("a place in two files comes back once, from the first")
    func duplicateAcrossFiles() async throws {
        let directory = try TemporaryDirectory()
        let first = directory.url.appending(path: "a.sqlite")
        let second = directory.url.appending(path: "b.sqlite")
        try LayerFileWriter.places([Self.place(1, bearing: 90, distance: 4_000)], to: first, region: "alpha")
        try LayerFileWriter.places(
            [Self.place(9, bearing: 90, distance: 8_000), PlaceRow(
                id: 2, osmID: 1, coordinate: Self.destination(from: Self.origin, bearing: 90, distance: 4_000))],
            to: second, region: "beta")
        let places = try Places(files: [first, second])
        let found = try await places.places(in: cone(90))
        #expect(found.map(\.place.region) == ["alpha", "beta"])
        #expect(found.map(\.place.id) == [PlaceID(osmType: "node", osmID: 1), PlaceID(osmType: "node", osmID: 9)])
    }

    @Test("with no files every query answers empty")
    func noFiles() async throws {
        let places = try Places(files: [])
        #expect(try await places.places(in: cone(90)).isEmpty)
    }

    // MARK: Cone construction

    @Test("a cone from one point to another has their bearing and distance")
    func fromTo() throws {
        let target = Self.destination(from: Self.origin, bearing: 41, distance: 12_345)
        let cone = try BearingCone(from: Self.origin, to: target)
        #expect(abs(cone.bearing - 41) < 1e-6)
        #expect(abs(cone.maxDistance - 12_345) < 1e-3)
        #expect(cone.halfAngle == 5)
        #expect(cone.origin.latitude == Self.origin.latitude)
    }

    @Test("a cone between points under 1 m apart, or over 500 km apart, is rejected")
    func fromToRange() {
        let near = Self.destination(from: Self.origin, bearing: 10, distance: 0.9)
        #expect(throws: QueryError.self) { try BearingCone(from: Self.origin, to: near) }
        let far = Self.destination(from: Self.origin, bearing: 10, distance: 500_100)
        #expect(throws: QueryError.self) { try BearingCone(from: Self.origin, to: far) }
    }

    @Test("a cone with a halfAngle or maxDistance out of range is rejected",
          arguments: [(0.0, 100_000.0), (181, 100_000), (5, 0), (5, 500_001), (.nan, 100_000), (5, .infinity)])
    func rangeRejected(halfAngle: Double, maxDistance: Double) {
        #expect(throws: QueryError.self) {
            try BearingCone(origin: Self.origin, bearing: 0, halfAngle: halfAngle, maxDistance: maxDistance)
        }
    }

    @Test("a cone at the range limits is accepted")
    func rangeAccepted() throws {
        _ = try BearingCone(origin: Self.origin, bearing: 0, halfAngle: 180, maxDistance: 500_000)
        _ = try BearingCone(origin: Self.origin, bearing: 0, halfAngle: 0.001, maxDistance: 0.001)
    }

    @Test("an origin with no fix, NaN or infinity is invalidInput", arguments: [
        (-180.0, -180.0), (.nan, 12), (46, .nan), (.infinity, 12), (91, 12), (46, 181),
    ])
    func originRejected(latitude: Double, longitude: Double) {
        let bad = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        #expect(throws: QueryError.self) { try BearingCone(origin: bad, bearing: 0) }
        #expect(throws: QueryError.self) { try BearingCone(from: bad, to: Self.origin) }
        #expect(throws: QueryError.self) { try BearingCone(from: Self.origin, to: bad) }
    }

    @Test("a bearing that is NaN or infinite is rejected")
    func bearingRejected() {
        #expect(throws: QueryError.self) { try BearingCone(origin: Self.origin, bearing: .nan) }
        #expect(throws: QueryError.self) { try BearingCone(origin: Self.origin, bearing: .infinity) }
    }

    @Test("a limit under 1 is rejected before any file is read")
    func limitRejected() async throws {
        let places = try Places(files: [])
        let aCone = try cone(90)
        await #expect(throws: QueryError.invalidInput("limit must be at least 1")) {
            try await places.places(in: aCone, limit: 0)
        }
        await #expect(throws: QueryError.invalidInput("limit must be at least 1")) {
            try await places.places(in: aCone, limit: -3)
        }
    }

    // MARK: Fixture

    @Test("the fixture's peaks come back nearest first with Geodesy distances")
    func fixturePeaks() async throws {
        let places = try Places(files: [Fixtures.url("test/test-places.v1.sqlite")])
        let start = CLLocationCoordinate2D(latitude: 46.10, longitude: 12.25)
        let found = try await places.places(in: cone(0, halfAngle: 180, from: start), kinds: [.peak])
        #expect(found.map(\.place.featureID) == [22, 19, 15])
        for result in found {
            #expect(result.distance == Geodesy.distance(start, result.place.coordinate))
            #expect(result.bearing == Geodesy.initialBearing(from: start, to: result.place.coordinate))
            #expect(result.place.kind == .peak)
            #expect(result.place.region == "test")
        }
        #expect(found.map(\.place.elevation) == [1190, 921, 425])
    }

    // MARK: Edges of the globe

    @Test("a cone near the pole returns without error and finds a place across it")
    func nearPole() async throws {
        let directory = try TemporaryDirectory()
        let start = CLLocationCoordinate2D(latitude: 89.9, longitude: 10)
        let places = try reader([
            Self.place(1, bearing: 0, distance: 30_000, from: start), Self.place(2, bearing: 90, distance: 5_000, from: start),
        ], in: directory)
        let found = try await places.places(in: cone(0, halfAngle: 180, maxDistance: 50_000, from: start))
        #expect(found.map(\.place.featureID) == [2, 1])
    }

    @Test("a cone at longitude 179.95 finds a place on the other side of the antimeridian")
    func nearAntimeridian() async throws {
        let directory = try TemporaryDirectory()
        let start = CLLocationCoordinate2D(latitude: 10, longitude: 179.95)
        let across = Self.place(1, bearing: 90, distance: 20_000, from: start)
        #expect(across.coordinate.longitude < 0)
        let places = try reader([across], in: directory)
        let found = try await places.places(in: cone(90, maxDistance: 30_000, from: start))
        #expect(found.map(\.place.featureID) == [1])
    }

    @Test("a cone south of the pole latitude clamps its box and still finds places")
    func atTheEdge() async throws {
        let directory = try TemporaryDirectory()
        let start = CLLocationCoordinate2D(latitude: -89.99, longitude: 0)
        let places = try reader([Self.place(1, bearing: 180, distance: 500, from: start)], in: directory)
        let found = try await places.places(in: cone(180, halfAngle: 180, maxDistance: 1_000, from: start))
        #expect(found.count == 1)
    }

    @Test("the box holds the cone at mid latitudes in every direction")
    func boxHoldsCone() async throws {
        let directory = try TemporaryDirectory()
        let start = CLLocationCoordinate2D(latitude: 60, longitude: 5)
        let rows = stride(from: 0.0, to: 360, by: 15).enumerated().map { index, bearing in
            Self.place(Int64(index + 1), bearing: bearing, distance: 499_000, from: start)
        }
        let places = try reader(rows, in: directory)
        let found = try await places.places(in: cone(0, halfAngle: 180, maxDistance: 500_000, from: start))
        #expect(found.count == rows.count)
    }
}
