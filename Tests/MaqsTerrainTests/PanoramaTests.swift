import CoreLocation
import Testing
@testable import MaqsTerrain

@Suite struct PanoramaTests {
    private static let origin = CLLocationCoordinate2D(latitude: 46, longitude: 12)
    private static let ground = 500.0
    /// Three ridges around the origin, at 5, 15 and 25 km, each a band of its own below.
    private static let ridges: [(centre: Double, height: Double)] = [(5_000, 300), (15_000, 900), (25_000, 1_400)]
    private static let bands = [0.0, 10_000, 20_000, 30_000]

    private static func elevation(_ lon: Double, _ lat: Double) -> Double {
        let distance = Geodesy.distance(origin, CLLocationCoordinate2D(latitude: lat, longitude: lon))
        return ridges.reduce(ground) { sum, ridge in
            sum + ridge.height * exp(-pow((distance - ridge.centre) / 800, 2))
        }
    }

    private func terrain(gap: @escaping @Sendable (TileKey) -> Bool = { _ in false }) -> Terrain {
        let provider = SyntheticTerrain(tileSize: 512, zoomRange: 0...12, elevation: Self.elevation, gap: gap)
        return Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
    }

    private func bearings(_ centre: Double, _ halfWidth: Double, _ step: Double) throws -> PanoramaBearings {
        try PanoramaBearings(centre: centre, halfWidth: halfWidth, step: step)
    }

    @Test func eachBandsRidgeIsItsHighestAngle() async throws {
        let options = ProfileOptions(step: 50)
        let panorama = try await terrain().panorama(
            from: Observer(coordinate: Self.origin), bearings: bearings(12, 0, 1), bands: Self.bands, options: options)
        let column = try #require(panorama.columns.first)
        #expect(panorama.columns.count == 1)
        #expect(column.ridges.count == 3)
        let eye = Self.ground + 1.7
        for (band, ridge) in Self.ridges.enumerated() {
            let found = try #require(column.ridges[band])
            #expect(abs(found.distance - ridge.centre) < 400)
            let expected = atan2(Self.ground + ridge.height - options.earth.drop(atDistance: ridge.centre) - eye, ridge.centre)
            #expect(abs(found.angle - expected) < 0.002)
        }
    }

    @Test func aBandWithNoGroundIsNil() async throws {
        let bands = [0.0, 10_000, 50_000, 60_000]
        let panorama = try await terrain(gap: { $0.z == 9 }).panorama(
            from: Observer(coordinate: Self.origin), bearings: bearings(0, 0, 1), bands: bands, options: ProfileOptions(step: 200))
        let ridges = try #require(panorama.columns.first?.ridges)
        #expect(ridges[0] != nil)
        #expect(ridges[1] != nil)
        #expect(ridges[2] == nil)
    }

    @Test func noGroundAtTheObserverGivesNoRidges() async throws {
        let panorama = try await terrain(gap: { _ in true }).panorama(
            from: Observer(coordinate: Self.origin), bearings: bearings(0, 2, 1), bands: Self.bands, options: ProfileOptions(step: 500))
        #expect(panorama.columns.count == 5)
        #expect(panorama.columns.allSatisfy { $0.ridges == [nil, nil, nil] })
    }

    @Test func theSkylineAgreesWithTheProfile() async throws {
        let terrain = terrain()
        let options = ProfileOptions(step: 100)
        let reach = try #require(Self.bands.last)
        let panorama = try await terrain.panorama(
            from: Observer(coordinate: Self.origin), bearings: bearings(30, 0, 1), bands: Self.bands, options: options)
        let skyline = try #require(panorama.columns.first?.ridges.compactMap { $0 }.map(\.angle).max())
        let end = Geodesy.destination(from: Self.origin, bearing: 30, distance: reach)
        let points = try await terrain.profile(from: Self.origin, to: end, options: options).points
        let eye = try #require(points.first?.apparentElevation) + 1.7
        let highest = try #require(points.dropFirst().compactMap { point in
            point.apparentElevation.map { atan2($0 - eye, point.distance) }
        }.max())
        #expect(abs(skyline - highest) < 1e-6)
    }

    @Test func columnsWrapPastNorth() async throws {
        let panorama = try await terrain().panorama(
            from: Observer(coordinate: Self.origin), bearings: bearings(2, 17, 1), bands: [0, 1_000], options: ProfileOptions(step: 500))
        #expect(panorama.columns.count == 35)
        #expect(abs((panorama.columns.first?.bearing ?? 0) - 345) < 1e-9)
        #expect(abs((panorama.columns.last?.bearing ?? 0) - 19) < 1e-9)
        #expect(panorama.columns.allSatisfy { (0..<360).contains($0.bearing) })
    }

    @Test func invalidBearingsAndBandsThrow() async throws {
        #expect(throws: TerrainError.self) { try PanoramaBearings(centre: .nan, halfWidth: 10, step: 1) }
        #expect(throws: TerrainError.self) { try PanoramaBearings(centre: 0, halfWidth: 181, step: 1) }
        #expect(throws: TerrainError.self) { try PanoramaBearings(centre: 0, halfWidth: 10, step: 0) }
        #expect(throws: TerrainError.self) { try PanoramaBearings(centre: 0, halfWidth: 10, step: 21) }
        let terrain = terrain()
        let observer = Observer(coordinate: Self.origin)
        for bands in [[1_000.0], [0, 2_000, 1_000], [-1, 100], [0, .infinity]] {
            await #expect(throws: TerrainError.self) {
                try await terrain.panorama(from: observer, bearings: try bearings(0, 0, 1), bands: bands)
            }
        }
    }

    @Test func aCancelledPanoramaThrowsCancellation() async throws {
        let terrain = terrain()
        let task = Task {
            try await terrain.panorama(
                from: Observer(coordinate: Self.origin), bearings: try bearings(0, 10, 1), bands: Self.bands,
                options: ProfileOptions(step: 50))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
