import Foundation

/// One stretch of a profile: out to `upTo` metres, tiles are read at no finer than `zoom`.
public struct ZoomBand: Sendable, Equatable {
    /// The farthest distance in metres this band covers.
    public let upTo: Double
    /// The zoom limit within the band.
    public let zoom: Int

    /// Creates a band; ``ZoomBands/init(_:)`` validates a list of them.
    public init(upTo: Double, zoom: Int) {
        self.upTo = upTo
        self.zoom = zoom
    }
}

/// Coarser tiles for farther distances, so a long profile costs few tile loads.
public struct ZoomBands: Sendable, Equatable {
    private let bands: [ZoomBand]

    /// Creates bands ordered by increasing `upTo`, the last being `.infinity`, with zooms in 0...22.
    /// - Throws: ``TerrainError/invalidInput(_:)`` when the list is empty, not increasing, does not end at `.infinity` or has a zoom outside 0...22.
    public init(_ bands: [ZoomBand]) throws(TerrainError) {
        guard let last = bands.last else { throw .invalidInput("zoom bands are empty") }
        guard last.upTo == .infinity else { throw .invalidInput("the last zoom band must reach infinity") }
        guard bands.allSatisfy({ (0...22).contains($0.zoom) }) else { throw .invalidInput("a band zoom is outside 0 to 22") }
        guard bands.first.map({ !$0.upTo.isNaN }) == true, zip(bands, bands.dropFirst()).allSatisfy({ $0.upTo < $1.upTo }) else {
            throw .invalidInput("zoom band distances must increase")
        }
        self.bands = bands
    }

    private init(unchecked bands: [ZoomBand]) {
        self.bands = bands
    }

    /// 12 out to 10 km, 11 to 30 km, 10 to 40 km, 9 beyond.
    public static let standard = ZoomBands(unchecked: [
        ZoomBand(upTo: 10_000, zoom: 12), ZoomBand(upTo: 30_000, zoom: 11),
        ZoomBand(upTo: 40_000, zoom: 10), ZoomBand(upTo: .infinity, zoom: 9),
    ])

    /// The zoom of the first band with `distance <= upTo`.
    public func zoom(atDistance distance: Double) -> Int {
        (bands.first { distance <= $0.upTo } ?? bands[bands.count - 1]).zoom
    }
}
