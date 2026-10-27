import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsData

/// Timings of the two slowest queries on synthetic files, printed for the record. The spec's targets (a 1 km
/// lookahead under 5 ms, a 100 km full-circle cone over 30,000 places under 100 ms, macOS debug build) are logged,
/// not asserted: a loaded CI machine would make a timing assertion flaky.
@Suite struct QueryMeasurement {
    private typealias Way = RoadNetwork.Way

    /// A road of 100 ways of 100 m heading north with a side road leaving every node: 200 segments.
    private static func network() -> RoadNetwork {
        var ways: [Way] = []
        for index in 0..<100 {
            let y = Double(index) * 100
            let wobble = index % 2 == 0 ? 10.0 : -10.0
            ways.append(Way(Int64(1_000 + index), [(Int64(index), 0, y), (Int64(index + 1), wobble, y + 100)]))
            ways.append(Way(Int64(2_000 + index), [(Int64(index + 1), wobble, y + 100), (Int64(5_000 + index), 80, y + 150)]))
        }
        return RoadNetwork(ways)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test("a lookahead is measured")
    func lookahead() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "roads.sqlite")
        try Self.network().write(to: url, junctions: .derived)
        let roads = try Roads(files: [url])
        let segment = try #require(await roads.segment(1_000))
        let position = RoadPosition(segment: segment, direction: .forward, along: 0)
        var samples: [Double] = []
        var result: Lookahead?
        for _ in 0..<100 {
            let clock = ContinuousClock()
            let start = clock.now
            result = try await roads.cornersAhead(from: position, distance: 1_000)
            samples.append(Self.milliseconds(clock.now - start))
        }
        samples.sort()
        print("lookahead 1 km, 200 segments: median \(samples[50]) ms, p90 \(samples[90]) ms (target < 5 ms)")
        #expect(result?.path.isEmpty == false)
    }

    @Test("a full-circle cone is measured")
    func fullCircleCone() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "places.sqlite")
        let origin = RoadNetwork.origin
        // A deterministic spread over about 100 km: 150 x 200 points, 0.01 degrees apart.
        var rows: [PlaceRow] = []
        for column in 0..<150 {
            for row in 0..<200 {
                let id = Int64(column * 200 + row + 1)
                let coordinate = CLLocationCoordinate2D(
                    latitude: origin.latitude - 0.7 + Double(row) * 0.007,
                    longitude: origin.longitude - 1.0 + Double(column) * 0.0134)
                rows.append(PlaceRow(id: id, name: "P\(id)", coordinate: coordinate, rankScore: Double(id % 100)))
            }
        }
        try LayerFileWriter.places(rows, to: url)
        let places = try Places(files: [url])
        let cone = try BearingCone(origin: origin, bearing: 0, halfAngle: 180, maxDistance: 100_000)
        let clock = ContinuousClock()
        let start = clock.now
        let found = try await places.places(in: cone)
        let elapsed = Self.milliseconds(clock.now - start)
        print("full-circle cone, \(rows.count) places, \(found.count) found: \(elapsed) ms (target < 100 ms)")
        #expect(!found.isEmpty)
    }
}
