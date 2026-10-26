@testable import MaqsTerrain

/// Lets a test hold a provider's loads until it opens the gate.
actor LoadGate {
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

/// A local `SyntheticTerrain` whose loads wait at a `LoadGate`.
final class GatedTerrain: TileProvider {
    private let inner: SyntheticTerrain
    private let gate: LoadGate

    init(gate: LoadGate, tileSize: Int = 512, elevation: @escaping @Sendable (Double, Double) -> Double = { _, _ in 0 }) {
        self.gate = gate
        self.inner = SyntheticTerrain(tileSize: tileSize, zoomRange: 0...12, elevation: elevation)
    }

    var zoomRange: ClosedRange<Int> { inner.zoomRange }
    var tileSize: Int { inner.tileSize }
    var isOnline: Bool { false }
    func covers(_ key: TileKey) throws -> Bool { try inner.covers(key) }
    func load(_ key: TileKey) async throws -> TileLoad {
        await gate.pass()
        return try await inner.load(key)
    }
}
