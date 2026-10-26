import CoreLocation
import Testing
@testable import MaqsTerrain

@Suite struct VisibilityTests {
    private let observer = Observer(coordinate: CLLocationCoordinate2D(latitude: 46, longitude: 12), height: .absolute(1000))
    private let flat = VisibilityOptions(earth: .none)

    private func terrain(
        elevation: @escaping @Sendable (Double, Double) -> Double = { _, _ in 0 },
        gap: @escaping @Sendable (TileKey) -> Bool = { _ in false }
    ) -> Terrain {
        let provider = SyntheticTerrain(tileSize: 512, zoomRange: 0...12, elevation: elevation, gap: gap)
        return Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
    }

    private func east(_ metres: Double, elevation: Double? = nil) -> SightTarget {
        SightTarget(coordinate: Geodesy.destination(from: observer.coordinate, bearing: 90, distance: metres), elevation: elevation)
    }

    /// A tile whose longitude span overlaps `range`, at any zoom.
    private static func overlaps(_ key: TileKey, _ range: ClosedRange<Double>) -> Bool {
        let count = Double(1 << key.z)
        let west = Double(key.x) / count * 360 - 180
        let eastEdge = Double(key.x + 1) / count * 360 - 180
        return west <= range.upperBound && eastEdge >= range.lowerBound
    }

    private static func ridge(_ height: Double, _ range: ClosedRange<Double>) -> @Sendable (Double, Double) -> Double {
        { lon, _ in range.contains(lon) ? height : 0 }
    }

    @Test func flatGroundShowsATarget() async throws {
        let target = east(20_000, elevation: 1000)
        let result = try await terrain().visibility(of: [target], from: observer, options: flat)
        guard case .visible(let distance, let bearing, let angle) = result[0] else { Issue.record("\(result[0])"); return }
        #expect(abs(distance - 20_000) < 1e-3)
        #expect(abs(bearing - 90) < 1e-6)
        #expect(abs(angle) < 1e-9)
    }

    @Test func aRidgeHidesIt() async throws {
        let terrain = terrain(elevation: Self.ridge(1500, 12.06...12.07))
        let result = try await terrain.visibility(of: [east(20_000, elevation: 1000)], from: observer, options: flat)
        guard case .hidden(let distance, _, let blockedDistance, let clearance) = result[0] else { Issue.record("\(result[0])"); return }
        #expect(abs(distance - 20_000) < 1e-3)
        #expect((4_000...6_000).contains(blockedDistance))
        #expect(abs(clearance - 500) < 1)
    }

    @Test func aRidgeWithinTheMarginDoesNot() async throws {
        let terrain = terrain(elevation: Self.ridge(1008, 12.06...12.07))
        let result = try await terrain.visibility(of: [east(20_000, elevation: 1000)], from: observer, options: flat)
        guard case .visible = result[0] else { Issue.record("\(result[0])"); return }
    }

    @Test func theTargetsOwnSlopeIsIgnored() async throws {
        let target = east(20_000, elevation: 1000)
        let slopeStart = target.coordinate.longitude - 0.0018
        let terrain = terrain(elevation: { lon, _ in lon > slopeStart ? 1050 : 0 })
        let ignored = try await terrain.visibility(of: [target], from: observer, options: flat)
        guard case .visible = ignored[0] else { Issue.record("\(ignored[0])"); return }
        let strict = VisibilityOptions(targetClearance: 0, earth: .none)
        let tested = try await terrain.visibility(of: [target], from: observer, options: strict)
        guard case .hidden = tested[0] else { Issue.record("\(tested[0])"); return }
    }

    @Test func theTrueSummitMakesAPeakVisible() async throws {
        let terrain = terrain(elevation: { lon, _ in (12.06...12.07).contains(lon) ? 1100 : 1000 })
        let ground = east(10_000)
        let withoutHeight = try await terrain.visibility(of: [ground], from: observer, options: flat)
        guard case .hidden = withoutHeight[0] else { Issue.record("\(withoutHeight[0])"); return }
        let withHeight = try await terrain.visibility(of: [east(10_000, elevation: 1600)], from: observer, options: flat)
        guard case .visible = withHeight[0] else { Issue.record("\(withHeight[0])"); return }
    }

    @Test func aGapIsUnknown() async throws {
        let terrain = terrain(gap: { Self.overlaps($0, 12.15...12.16) })
        let result = try await terrain.visibility(of: [east(20_000, elevation: 1000)], from: observer, options: flat)
        guard case .unknown(let at, let reason, _) = result[0] else { Issue.record("\(result[0])"); return }
        #expect(at == .path)
        #expect(reason == .noData)
    }

    @Test func aKnownRidgeBeatsAGap() async throws {
        let terrain = terrain(elevation: Self.ridge(1500, 12.06...12.07), gap: { Self.overlaps($0, 12.15...12.16) })
        let result = try await terrain.visibility(of: [east(20_000, elevation: 1000)], from: observer, options: flat)
        guard case .hidden = result[0] else { Issue.record("\(result[0])"); return }
    }

    @Test func beyondTheRangeIsOutOfRange() async throws {
        let result = try await terrain().visibility(of: [east(150_000, elevation: 1000)], from: observer, options: flat)
        guard case .outOfRange(let distance) = result[0] else { Issue.record("\(result[0])"); return }
        #expect(abs(distance - 150_000) < 1e-2)
    }

    @Test func anUnknownObserverIsUnknown() async throws {
        let terrain = terrain(gap: { Self.overlaps($0, 11.99...12.01) })
        let grounded = Observer(coordinate: observer.coordinate)
        let result = try await terrain.visibility(of: [east(20_000, elevation: 1000)], from: grounded, options: flat)
        guard case .unknown(let at, let reason, let distance) = result[0] else { Issue.record("\(result[0])"); return }
        #expect(at == .observer)
        #expect(reason == .noData)
        #expect(abs(distance - 20_000) < 1e-3)
    }

    @Test func anUnknownTargetIsUnknown() async throws {
        let target = east(20_000)
        let terrain = terrain(gap: { Self.overlaps($0, 12.25...12.27) })
        let result = try await terrain.visibility(of: [target], from: observer, options: flat)
        guard case .unknown(let at, let reason, _) = result[0] else { Issue.record("\(result[0])"); return }
        #expect(at == .target)
        #expect(reason == .noData)
        let known = try await terrain.visibility(of: [east(20_000, elevation: 1000)], from: observer, options: flat)
        guard case .unknown(let pathAt, _, _) = known[0] else { Issue.record("\(known[0])"); return }
        #expect(pathAt == .path)
    }

    @Test func curvatureHidesADistantLowTarget() async throws {
        let low = Observer(coordinate: observer.coordinate, height: .absolute(2))
        let target = east(50_000, elevation: 100)
        let curved = try await terrain().visibility(of: [target], from: low, options: VisibilityOptions(margin: 0))
        guard case .hidden = curved[0] else { Issue.record("\(curved[0])"); return }
        let straight = try await terrain().visibility(of: [target], from: low, options: VisibilityOptions(margin: 0, earth: .none))
        guard case .visible = straight[0] else { Issue.record("\(straight[0])"); return }
    }

    @Test func resultsKeepInputOrder() async throws {
        let terrain = terrain(elevation: Self.ridge(1500, 12.06...12.07))
        let north = SightTarget(coordinate: Geodesy.destination(from: observer.coordinate, bearing: 0, distance: 8_000), elevation: 1000)
        let south = SightTarget(coordinate: Geodesy.destination(from: observer.coordinate, bearing: 180, distance: 12_000), elevation: 1000)
        let result = try await terrain.visibility(of: [north, south, east(20_000, elevation: 1000)], from: observer, options: flat)
        #expect(result.count == 3)
        guard case .visible(let first, _, _) = result[0], case .visible(let second, _, _) = result[1], case .hidden = result[2] else {
            Issue.record("\(result)")
            return
        }
        #expect(abs(first - 8_000) < 1e-3)
        #expect(abs(second - 12_000) < 1e-3)
    }

    @Test func aTargetAtTheObserverIsVisibleWithFiniteValues() async throws {
        for height in [ObserverHeight.absolute(1000), .aboveGround(1.7)] {
            let here = Observer(coordinate: observer.coordinate, height: height)
            let result = try await terrain().visibility(of: [SightTarget(coordinate: observer.coordinate)], from: here, options: flat)
            guard case .visible(let distance, let bearing, let angle) = result[0] else { Issue.record("\(result[0])"); return }
            #expect(distance.isFinite && bearing == 0 && angle == 0)
        }
    }

    @Test func aNaNTargetIsUnknown() async throws {
        let nowhere = SightTarget(coordinate: CLLocationCoordinate2D(latitude: .nan, longitude: 12))
        let result = try await terrain().visibility(of: [nowhere], from: observer, options: flat)
        guard case .unknown(let at, let reason, let distance) = result[0] else { Issue.record("\(result[0])"); return }
        #expect(at == .target && reason == .noData && distance == 0)
    }

    @Test func aNaNObserverIsInvalidInput() async throws {
        let lost = Observer(coordinate: CLLocationCoordinate2D(latitude: .nan, longitude: 12), height: .absolute(1000))
        await #expect(throws: TerrainError.self) {
            try await terrain().visibility(of: [east(1_000, elevation: 1000)], from: lost, options: flat)
        }
    }

    @Test func moreThanFiveThousandTargetsAreInvalidInput() async throws {
        let targets = Array(repeating: east(1_000, elevation: 1000), count: 5_001)
        await #expect(throws: TerrainError.self) {
            try await terrain().visibility(of: targets, from: observer, options: flat)
        }
    }

    // MARK: Several chunks

    private func ring(_ bearings: [Double], distance: Double, elevation: Double? = 1200) -> [SightTarget] {
        bearings.enumerated().map { offset, bearing in
            SightTarget(coordinate: Geodesy.destination(from: observer.coordinate, bearing: bearing, distance: distance + Double(offset) * 10), elevation: elevation)
        }
    }

    @Test func aLookSplitIntoChunksAnswersLikeOneChunk() async throws {
        let bumpy: @Sendable (Double, Double) -> Double = { lon, lat in 1000 + 500 * sin(lon * 300) * cos(lat * 300) }
        let targets = ring((0..<40).map { 50 + Double($0) * 1.5 }, distance: 9_000) + ring((0..<40).map { 200 + Double($0) * 3 }, distance: 25_000)
        let whole = SyntheticTerrain(tileSize: 512, zoomRange: 0...12, elevation: bumpy)
        let split = SyntheticTerrain(tileSize: 512, zoomRange: 0...12, elevation: bumpy)
        let expected = try await Terrain(providers: [whole], memoryCacheBytes: 64 << 20).visibility(of: targets, from: observer, options: flat)
        let actual = try await Terrain(providers: [split], memoryCacheBytes: 2 << 20).visibility(of: targets, from: observer, options: flat)
        #expect(actual.map { "\($0)" } == expected.map { "\($0)" })
        #expect(expected.count == targets.count)
        #expect(split.loads.count > whole.loads.count)
    }

    @Test func theOnlineCapHoldsAcrossChunks() async throws {
        let provider = SyntheticTerrain(tileSize: 512, zoomRange: 0...12, isOnline: true, elevation: { _, _ in 0 })
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 3 << 20)
        let everywhere = VisibilityOptions(earth: .none, bands: try ZoomBands([ZoomBand(upTo: .infinity, zoom: 12)]))
        let targets = ring((0..<48).map { Double($0) * 7.5 }, distance: 50_000, elevation: 1000)
        let results = try await terrain.visibility(of: targets, from: observer, options: everywhere)
        #expect(provider.loads.count == 128)
        let capped = results.filter {
            if case .unknown(.path, .requestCap, _) = $0 { return true }
            return false
        }
        #expect(!capped.isEmpty)
    }

    @Test func replacingArchivesDuringALookDoesNotTrap() async throws {
        let gate = Gate()
        let provider = GatedTerrain(gate: gate)
        let terrain = Terrain(providers: [provider], memoryCacheBytes: 64 << 20)
        let targets = ring((0..<70).map { 80 + Double($0) * 0.2 }, distance: 20_000, elevation: 1000)
        let observer = observer
        let options = flat
        let look = Task { try await terrain.visibility(of: targets, from: observer, options: options) }
        await gate.waitUntilBlocked()
        try await terrain.setArchives([])
        await gate.open()
        let results = try await look.value
        #expect(results.count == targets.count)
    }
}

/// Lets a test hold a provider's first load until it opens the gate.
private actor Gate {
    private var isOpen = false
    private var blocked = false
    private var loaders: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        guard !isOpen else { return }
        blocked = true
        watchers.forEach { $0.resume() }
        watchers = []
        await withCheckedContinuation { loaders.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    func open() {
        isOpen = true
        loaders.forEach { $0.resume() }
        loaders = []
    }
}

private final class GatedTerrain: TileProvider {
    private let inner = SyntheticTerrain(tileSize: 512, zoomRange: 0...12, elevation: { _, _ in 0 })
    private let gate: Gate
    init(gate: Gate) { self.gate = gate }
    var zoomRange: ClosedRange<Int> { inner.zoomRange }
    var tileSize: Int { inner.tileSize }
    var isOnline: Bool { false }
    func covers(_ key: TileKey) throws -> Bool { try inner.covers(key) }
    func load(_ key: TileKey) async throws -> TileLoad {
        await gate.pass()
        return try await inner.load(key)
    }
}
