import CoreLocation
import Testing
@testable import MaqsTerrain

@Suite struct ProfileTests {
    private func point(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func terrain(gap: @escaping @Sendable (TileKey) -> Bool = { _ in false }) -> (Terrain, SyntheticTerrain) {
        let provider = SyntheticTerrain(tileSize: 512, zoomRange: 0...12, elevation: { _, _ in 1000 }, gap: gap)
        return (Terrain(providers: [provider], memoryCacheBytes: 64 << 20), provider)
    }

    private func north(of start: CLLocationCoordinate2D, metres: Double) -> CLLocationCoordinate2D {
        Geodesy.destination(from: start, bearing: 0, distance: metres)
    }

    @Test func startsAtZeroEndsAtTheTotalAndStepsByTheBandPixel() async throws {
        let (terrain, _) = terrain()
        let start = point(46, 12)
        let end = north(of: start, metres: 5_000)
        let points = try await terrain.profile(from: start, to: end).points
        #expect(points.first?.distance == 0)
        #expect(abs((points.last?.distance ?? 0) - Geodesy.distance(start, end)) < 1e-6)
        let step = WebMercator.pixelSize(zoom: 12, tileSize: 512, latitude: 46)
        #expect(abs(points[1].distance - step) < 1e-6)
    }

    @Test func apparentElevationSubtractsTheDrop() async throws {
        let (terrain, _) = terrain()
        let options = ProfileOptions(step: 500)
        let profile = try await terrain.profile(from: point(46, 12), to: north(of: point(46, 12), metres: 12_000), options: options)
        for item in profile.points {
            #expect(item.ground == .elevation(1000))
            let apparent = try #require(item.apparentElevation)
            #expect(abs(apparent - (1000 - options.earth.drop(atDistance: item.distance))) < 1e-9)
        }
    }

    @Test func loadsAtTheCoarserZoomBeyondTenKilometres() async throws {
        let (terrain, provider) = terrain()
        let start = point(46, 12)
        _ = try await terrain.profile(from: start, to: north(of: start, metres: 15_000), options: ProfileOptions(step: 250))
        #expect(Set(provider.loads.map(\.z)) == [12, 11])
    }

    @Test func aGapIsMissingWithoutAnApparentElevation() async throws {
        let (terrain, _) = terrain(gap: { _ in true })
        let start = point(46, 12)
        let profile = try await terrain.profile(from: start, to: north(of: start, metres: 1_000), options: ProfileOptions(step: 100))
        #expect(profile.points.allSatisfy { $0.ground == .missing(.noData) && $0.apparentElevation == nil })
    }

    @Test func aFlatEarthLeavesGroundUnchanged() async throws {
        let (terrain, _) = terrain()
        let start = point(46, 12)
        let profile = try await terrain.profile(from: start, to: north(of: start, metres: 3_000), options: ProfileOptions(step: 100, earth: .none))
        #expect(profile.points.allSatisfy { $0.apparentElevation == 1000 })
    }

    @Test func coincidentEndpointsGiveOnePoint() async throws {
        let (terrain, _) = terrain()
        let profile = try await terrain.profile(from: point(46, 12), to: point(46, 12))
        #expect(profile.points.count == 1)
    }

    @Test func rejectsAShortStep() async {
        let (terrain, _) = terrain()
        await #expect(throws: TerrainError.self) {
            try await terrain.profile(from: point(46, 12), to: point(46.1, 12), options: ProfileOptions(step: 0.5))
        }
    }

    @Test func rejectsNonFiniteEndpoints() async {
        let (terrain, _) = terrain()
        await #expect(throws: TerrainError.self) {
            try await terrain.profile(from: point(.nan, 12), to: point(46.1, 12))
        }
        await #expect(throws: TerrainError.self) {
            try await terrain.profile(from: point(46, 12), to: point(46.1, .infinity))
        }
    }

    @Test func rejectsMoreThanOneHundredThousandPoints() async {
        let (terrain, _) = terrain()
        let start = point(46, 12)
        await #expect(throws: TerrainError.self) {
            try await terrain.profile(from: start, to: north(of: start, metres: 150_000), options: ProfileOptions(step: 1))
        }
    }
}
