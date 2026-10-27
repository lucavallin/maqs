import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsData

@Suite struct NearbySegmentTests {
    private static let origin = CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25)

    private func fixtureRoads() throws -> Roads {
        try Roads(files: [Fixtures.url("test/test-curvature.v1.sqlite")])
    }

    /// Parallel east-west ways about 11 m apart, way `id` at latitude `46.1 + (id - 1) × 0.0001`.
    private static func rows(_ ids: ClosedRange<Int64>) -> [SegmentRow] {
        ids.map { id in
            let latitude = origin.latitude + Double(id - 1) * 0.0001
            let line = [CLLocationCoordinate2D(latitude: latitude, longitude: 12.25),
                        CLLocationCoordinate2D(latitude: latitude, longitude: 12.251)]
            return SegmentRow(id: id, length: 76, startNode: id * 10, endNode: id * 10 + 1, coordinates: line)
        }
    }

    // MARK: Fixture

    @Test("the midpoint of every fixture road finds that road, at the right place along it and heading")
    func midpoints() async throws {
        let roads = try fixtureRoads()
        let golden = try DataGolden.load()
        #expect(golden.segments.count == 136)
        var firstCount = 0
        for entry in golden.segments {
            let line = entry.coordinates.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
            var total = 0.0
            for index in 1..<line.count { total += Geodesy.distance(line[index - 1], line[index]) }
            let midpoint = Geodesy.point(on: line, at: total / 2)
            let results = try await roads.segments(near: midpoint, within: 50, limit: 100)
            let hit = try #require(results.first { $0.segment.id == entry.osmWayId }, "way \(entry.osmWayId)")
            #expect(hit.distance < 0.5, "way \(entry.osmWayId)")
            #expect(abs(hit.along - total / 2) < 0.5, "way \(entry.osmWayId)")
            var before = 0.0
            var bearing = 0.0
            for index in 1..<line.count {
                bearing = Geodesy.initialBearing(from: line[index - 1], to: line[index])
                before += Geodesy.distance(line[index - 1], line[index])
                if before >= total / 2 { break }
            }
            var off = abs(hit.heading - bearing).truncatingRemainder(dividingBy: 360)
            if off > 180 { off = 360 - off }
            #expect(off < 1, "way \(entry.osmWayId)")
            #expect(results.map(\.distance) == results.map(\.distance).sorted())
            if results.first?.segment.id == entry.osmWayId { firstCount += 1 }
        }
        // A road that another passes within the same half metre may come second; almost none do.
        #expect(firstCount > 100)
    }

    @Test("a result carries the whole segment")
    func fullSegment() async throws {
        let roads = try fixtureRoads()
        let golden = try DataGolden.load()
        let entry = try #require(golden.segments.first { !$0.analysis.corners.isEmpty })
        let line = entry.coordinates.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
        let results = try await roads.segments(near: line[0], within: 5)
        let segment = try #require(results.first { $0.segment.id == entry.osmWayId }).segment
        #expect(segment.corners.count == entry.analysis.corners.count)
        #expect(segment.geometry.count == line.count)
    }

    @Test("within and limit are respected")
    func withinAndLimit() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "roads.sqlite")
        try LayerFileWriter.curvature(segments: Self.rows(1...5), to: url)
        let roads = try Roads(files: [url])
        let position = CLLocationCoordinate2D(latitude: 46.1, longitude: 12.2505)
        // Ways 1 to 5 sit 0, 11.1, 22.2, 33.4 and 44.5 m north of the position.
        let near = try await roads.segments(near: position, within: 25)
        #expect(near.map(\.segment.id) == [1, 2, 3])
        #expect(near.map(\.distance) == near.map(\.distance).sorted())
        #expect(abs(near[1].distance - 11.1) < 0.1)
        #expect(abs(near[0].along - 38.5) < 0.5)
        #expect(abs(near[0].heading - 90) < 0.1)
        #expect(try await roads.segments(near: position, within: 25, limit: 2).map(\.segment.id) == [1, 2])
        #expect(try await roads.segments(near: position, within: 1).map(\.segment.id) == [1])
        #expect(try await roads.segments(near: CLLocationCoordinate2D(latitude: 46.2, longitude: 12.2505)).isEmpty)
    }

    @Test("within and limit out of range are invalidInput",
          arguments: [(0.0, 20, "within"), (501.0, 20, "within"), (.nan, 20, "within"), (50.0, 0, "limit"), (50.0, 101, "limit")]
              as [(Double, Int, String)])
    func badBounds(within: Double, limit: Int, name: String) async throws {
        let roads = try fixtureRoads()
        let expected = name == "within" ? "within must be within 1...500 metres" : "limit must be within 1...100"
        await #expect(throws: QueryError.invalidInput(expected)) {
            try await roads.segments(near: Self.origin, within: within, limit: limit)
        }
    }

    @Test("the edges of the ranges are accepted")
    func edges() async throws {
        let roads = try fixtureRoads()
        _ = try await roads.segments(near: Self.origin, within: 1, limit: 1)
        _ = try await roads.segments(near: Self.origin, within: 500, limit: 100)
    }

    // MARK: Review focus 1

    @Test("a position with no fix, NaN or infinity is invalidInput before any SQL runs",
          arguments: [
              kCLLocationCoordinate2DInvalid,
              CLLocationCoordinate2D(latitude: .nan, longitude: 12),
              CLLocationCoordinate2D(latitude: 46, longitude: .infinity),
              CLLocationCoordinate2D(latitude: 91, longitude: 12),
          ])
    func invalidPosition(position: CLLocationCoordinate2D) async throws {
        let roads = try fixtureRoads()
        await #expect(throws: QueryError.invalidInput("position must be a real coordinate")) {
            try await roads.segments(near: position)
        }
    }

    // MARK: Review focus 2

    @Test("the same file installed under two region names gives each way once")
    func sameFileTwice() async throws {
        let directory = try TemporaryDirectory()
        let first = directory.url.appending(path: "a.sqlite")
        let second = directory.url.appending(path: "b.sqlite")
        try LayerFileWriter.curvature(segments: Self.rows(1...3), to: first, region: "a")
        try LayerFileWriter.curvature(segments: Self.rows(1...3), to: second, region: "b")
        let roads = try Roads(files: [first, second])
        let results = try await roads.segments(near: Self.origin, within: 50)
        #expect(results.map(\.segment.id) == [1, 2, 3])
    }

    @Test("a duplicate does not eat into the limit")
    func dedupeBeforeLimit() async throws {
        let directory = try TemporaryDirectory()
        let first = directory.url.appending(path: "a.sqlite")
        let second = directory.url.appending(path: "b.sqlite")
        try LayerFileWriter.curvature(segments: Self.rows(1...3), to: first, region: "a")
        try LayerFileWriter.curvature(segments: Self.rows(1...5), to: second, region: "b")
        let roads = try Roads(files: [first, second])
        let results = try await roads.segments(near: Self.origin, within: 100, limit: 5)
        #expect(results.map(\.segment.id) == [1, 2, 3, 4, 5])
    }

    @Test("the search box widens in longitude with latitude")
    func wideBoxAtHighLatitude() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "roads.sqlite")
        // A north-south way at 70 degrees north, 400 m east of the position.
        let longitude = 12.25 + 400 / (111_320 * cos(70.0 * .pi / 180))
        let line = [CLLocationCoordinate2D(latitude: 69.99, longitude: longitude),
                    CLLocationCoordinate2D(latitude: 70.01, longitude: longitude)]
        try LayerFileWriter.curvature(segments: [SegmentRow(id: 1, length: 2_000, startNode: 1, endNode: 2, coordinates: line)], to: url)
        let roads = try Roads(files: [url])
        let results = try await roads.segments(near: CLLocationCoordinate2D(latitude: 70, longitude: 12.25), within: 500)
        #expect(results.map(\.segment.id) == [1])
        #expect(abs((results.first?.distance ?? 0) - 400) < 5)
    }
}
