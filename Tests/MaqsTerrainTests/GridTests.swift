import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsTerrain

@Suite struct GridTests {
    private static let fixture = "test/test-terrain.v1.pmtiles"

    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// About 90 m across, so the grid's zoom reaches the archive's finest level, the one point sampling uses.
    @Test func aSmallGridEqualsPointSamples() async throws {
        let terrain = try Terrain(configuration: TerrainConfiguration(archives: [Fixtures.url(Self.fixture)]))
        let area = try TerrainArea(southWest: coordinate(46.1, 12.25), northEast: coordinate(46.1008, 12.2508))
        let grid = try await terrain.grid(area, columns: 4, rows: 4)
        #expect(grid.columns == 4 && grid.rows == 4 && grid.samples.count == 16)
        for row in 0..<4 {
            for column in 0..<4 {
                let longitude = 12.25 + (Double(column) + 0.5) / 4 * 0.0008
                let latitude = 46.1008 - (Double(row) + 0.5) / 4 * 0.0008
                let expected = try await terrain.elevation(at: coordinate(latitude, longitude))
                #expect(grid[column, row] == expected)
            }
        }
    }

    @Test func aLargeAreaSamplesAtACoarseZoom() async throws {
        let provider = SyntheticTerrain(tileSize: 512, zoomRange: 0...12) { _, _ in 100 }
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
        let area = try TerrainArea(southWest: coordinate(45, 11), northEast: coordinate(47, 13))
        let grid = try await terrain.grid(area, columns: 10, rows: 10)
        #expect(grid.samples.allSatisfy { $0 == .elevation(100) })
        #expect(!provider.loads.isEmpty)
        #expect(provider.loads.allSatisfy { $0.z == 3 })
    }

    @Test func anAreaRejectsNaNInvertedCornersAndALargeSpan() {
        let invalid: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = [
            (coordinate(.nan, 11), coordinate(46, 12)),
            (coordinate(46, 12), coordinate(45, 13)),
            (coordinate(45, 13), coordinate(46, 12)),
            (coordinate(45, 11), coordinate(47.5, 12)),
            (coordinate(45, 11), coordinate(46, 13.5)),
        ]
        for (southWest, northEast) in invalid {
            #expect(throws: TerrainError.invalidArea) { _ = try TerrainArea(southWest: southWest, northEast: northEast) }
        }
    }

    @Test(arguments: [(0, 4), (4, 0), (1025, 4), (4, 1025)])
    func aGridOutsideOneToAThousandAndTwentyFourIsInvalidInput(columns: Int, rows: Int) async throws {
        let provider = SyntheticTerrain(tileSize: 512, zoomRange: 0...12) { _, _ in 1 }
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
        let area = try TerrainArea(southWest: coordinate(46, 12), northEast: coordinate(46.1, 12.1))
        await #expect {
            _ = try await terrain.grid(area, columns: columns, rows: rows)
        } throws: { error in
            guard case .invalidInput = error as? TerrainError else { return false }
            return true
        }
        #expect(provider.loads.isEmpty)
    }
}
