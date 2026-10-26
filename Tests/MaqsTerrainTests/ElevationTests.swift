import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsTerrain

@Suite struct ElevationTests {
    private static let fixture = "test/test-terrain.v1.pmtiles"

    private func terrain(archives: [URL]? = nil) throws -> Terrain {
        try Terrain(configuration: TerrainConfiguration(archives: archives ?? [Fixtures.url(Self.fixture)]))
    }

    private func coordinate(_ point: Golden.Point) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
    }

    @Test func elevationMatchesTheGoldenPoints() async throws {
        let golden = try Golden.load()
        let terrain = try terrain()
        for point in golden.points {
            let sample = try await terrain.elevation(at: coordinate(point))
            switch (point.elevation, sample) {
            case (nil, .missing(.noData)): break
            case (let expected?, .elevation(let value)): #expect(abs(value - expected) < 1e-6)
            default: Issue.record("lon \(point.lon) lat \(point.lat): expected \(String(describing: point.elevation)), got \(sample)")
            }
        }
    }

    @Test func aRouteKeepsItsOrder() async throws {
        let golden = try Golden.load()
        let points = Array(golden.points.prefix(40).reversed())
        let samples = try await terrain().elevations(at: points.map(coordinate))
        #expect(samples.count == points.count)
        for (point, sample) in zip(points, samples) {
            switch (point.elevation, sample) {
            case (nil, .missing(.noData)): break
            case (let expected?, .elevation(let value)): #expect(abs(value - expected) < 1e-6)
            default: Issue.record("lon \(point.lon) lat \(point.lat): unexpected \(sample)")
            }
        }
    }

    @Test func noArchivesMeansNoDataThenSetArchivesBringsValues() async throws {
        let terrain = try terrain(archives: [])
        let place = CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25)
        #expect(try await terrain.elevation(at: place) == .missing(.noData))
        try await terrain.setArchives([Fixtures.url(Self.fixture)])
        guard case .elevation = try await terrain.elevation(at: place) else {
            Issue.record("expected an elevation after setArchives")
            return
        }
    }
}
