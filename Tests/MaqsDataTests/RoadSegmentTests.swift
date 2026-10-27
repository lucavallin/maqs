import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsData

@Suite struct RoadSegmentTests {
    private static let line = [
        CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25),
        CLLocationCoordinate2D(latitude: 46.1, longitude: 12.251),
    ]

    private func reader(_ rows: [SegmentRow], corners: [CornerRow] = [], junctionColumn: Bool = true,
                        in directory: TemporaryDirectory) throws -> Roads {
        let url = directory.url.appending(path: "roads.sqlite")
        try LayerFileWriter.curvature(segments: rows, corners: corners, junctionColumn: junctionColumn, to: url)
        return try Roads(files: [url])
    }

    private func row(_ id: Int64, highway: String = "secondary", oneway: Int = 0, junction: String? = nil) -> SegmentRow {
        SegmentRow(id: id, highway: highway, oneway: oneway, length: 76, startNode: id * 10, endNode: id * 10 + 1,
                   coordinates: Self.line, junction: junction)
    }

    // MARK: Effective one-way

    @Test("the effective one-way follows the column, then roundabouts and motorways",
          arguments: [
              (1, "secondary", nil, OneWay.forward),
              (-1, "secondary", nil, OneWay.backward),
              (0, "secondary", "roundabout", OneWay.forward),
              (0, "secondary", "circular", OneWay.none),
              (0, "motorway", nil, OneWay.forward),
              (0, "motorway_link", nil, OneWay.none),
              (-1, "secondary", "roundabout", OneWay.backward),
              (0, "secondary", nil, OneWay.none),
          ] as [(Int, String, String?, OneWay)])
    func effectiveOneWay(column: Int, highway: String, junction: String?, expected: OneWay) async throws {
        let directory = try TemporaryDirectory()
        let roads = try reader([row(1, highway: highway, oneway: column, junction: junction)], in: directory)
        let segment = try #require(await roads.segment(1))
        #expect(segment.oneway == expected)
        #expect(segment.junction == junction)
    }

    @Test("a file without the junction column infers one-way only for motorways")
    func olderFile() async throws {
        let directory = try TemporaryDirectory()
        let roads = try reader([row(1, junction: "roundabout"), row(2, highway: "motorway"), row(3, oneway: -1)],
                               junctionColumn: false, in: directory)
        let roundabout = try #require(await roads.segment(1))
        #expect(roundabout.junction == nil)
        #expect(roundabout.oneway == .none)
        #expect(try #require(await roads.segment(2)).oneway == .forward)
        #expect(try #require(await roads.segment(3)).oneway == .backward)
    }

    // MARK: By id

    @Test("segment(_:) reads corners in ordinal order and the tags as stored")
    func cornersInOrder() async throws {
        let directory = try TemporaryDirectory()
        let apex = Self.line[0]
        func corner(_ id: Int64, _ ordinal: Int, _ direction: String) -> CornerRow {
            CornerRow(id: id, segmentID: 1, ordinal: ordinal, apex: apex, minRadius: 30 + Double(ordinal), direction: direction,
                      entry: Double(ordinal) * 10, apexDistance: Double(ordinal) * 10 + 5, exit: Double(ordinal) * 10 + 9)
        }
        var segment = row(1)
        segment.name = "Via Roma"
        segment.ref = "SP1"
        segment.surface = "asphalt"
        segment.maxspeed = "50"
        let roads = try reader([segment, row(2)], corners: [
            corner(1, 2, "left"), corner(2, 0, "right"), corner(3, 1, "left"),
            CornerRow(id: 4, segmentID: 2, ordinal: 0, apex: apex, minRadius: 9, direction: "left", entry: 0, apexDistance: 1, exit: 2),
        ], in: directory)
        let found = try #require(await roads.segment(1))
        #expect(found.corners.map(\.ordinal) == [0, 1, 2])
        #expect(found.corners.map(\.turn) == [.right, .left, .left])
        #expect(found.corners[1].minRadius == 31)
        #expect(found.corners[2].exit == 29)
        #expect(found.id == 1)
        #expect(found.name == "Via Roma")
        #expect(found.ref == "SP1")
        #expect(found.highway == "secondary")
        #expect(found.surface == "asphalt")
        #expect(found.maxspeed == "50")
        #expect(found.length == 76)
        #expect(found.startNode == 10)
        #expect(found.endNode == 11)
        #expect(found.geometry.count == 2)
        #expect(abs(found.geometry[1].longitude - 12.251) < 1e-9)
        #expect(try #require(await roads.segment(2)).corners.count == 1)
    }

    @Test("the id is the OSM way id, not the row id")
    func wayID() async throws {
        let directory = try TemporaryDirectory()
        let roads = try reader([SegmentRow(id: 1, osmWayID: 9_000_000_001, startNode: 1, endNode: 2, coordinates: Self.line)],
                               in: directory)
        #expect(try await roads.segment(9_000_000_001)?.id == 9_000_000_001)
        #expect(try await roads.segment(1) == nil)
    }

    @Test("an unknown id is nil")
    func unknownID() async throws {
        let directory = try TemporaryDirectory()
        let roads = try reader([row(1)], in: directory)
        #expect(try await roads.segment(404) == nil)
    }

    @Test("a geometry that is not a polyline is corruptData naming the file")
    func corruptGeometry() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "roads.sqlite")
        try LayerFileWriter.curvature(segments: [
            SegmentRow(id: 1, startNode: 1, endNode: 2, coordinates: Self.line, geometry: "!!"),
        ], to: url)
        let roads = try Roads(files: [url])
        await #expect(throws: QueryError.corruptData(file: "roads.sqlite", detail: "the geometry of segment 1 is not a valid polyline")) {
            try await roads.segment(1)
        }
    }

    @Test("no files gives empty results")
    func noFiles() async throws {
        let roads = try Roads(files: [])
        #expect(try await roads.segment(1) == nil)
        #expect(try await roads.segments(near: Self.line[0]).isEmpty)
    }

    @Test("the same way in two files is read from the first")
    func firstFileWins() async throws {
        let directory = try TemporaryDirectory()
        let first = directory.url.appending(path: "a.sqlite")
        let second = directory.url.appending(path: "b.sqlite")
        var named = row(1)
        named.name = "from b"
        try LayerFileWriter.curvature(segments: [row(1)], to: first, region: "a")
        try LayerFileWriter.curvature(segments: [named], to: second, region: "b")
        let roads = try Roads(files: [second, first])
        #expect(try await roads.segment(1)?.name == "from b")
    }
}
