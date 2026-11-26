import Foundation

/// The fan of bearings a ``Terrain/panorama(from:bearings:bands:options:)`` looks along, in degrees clockwise from true
/// north: from `centre − halfWidth` to `centre + halfWidth`, every `step`.
public struct PanoramaBearings: Sendable, Equatable {
    /// The middle of the fan.
    public let centre: Double
    /// Half the fan's width, 0 to 180; 0 is one bearing.
    public let halfWidth: Double
    /// Degrees between neighbouring bearings.
    public let step: Double

    /// Creates a fan.
    /// - Throws: ``TerrainError/invalidInput(_:)`` for a non-finite value, a `halfWidth` outside 0...180, or a `step`
    ///   that is not above 0 or, with a `halfWidth` above 0, wider than the fan.
    public init(centre: Double, halfWidth: Double, step: Double) throws(TerrainError) {
        guard centre.isFinite, halfWidth.isFinite, step.isFinite else {
            throw .invalidInput("a panorama's bearings must be finite")
        }
        guard (0...180).contains(halfWidth) else {
            throw .invalidInput("a panorama's half-width is 0 to 180 degrees, not \(halfWidth)")
        }
        guard step > 0, halfWidth == 0 || step <= 2 * halfWidth else {
            throw .invalidInput("a panorama's step is above 0 and no wider than the fan, not \(step)")
        }
        self.centre = centre
        self.halfWidth = halfWidth
        self.step = step
    }

    /// The bearings, left to right, each in 0..<360.
    var all: [Double] {
        let count = halfWidth == 0 ? 1 : Int((2 * halfWidth / step + 1e-9).rounded(.down)) + 1
        return (0..<count).map { index in
            let bearing = (centre - halfWidth + Double(index) * step).truncatingRemainder(dividingBy: 360)
            return bearing < 0 ? bearing + 360 : bearing
        }
    }
}

/// The ground seen highest within one distance band of one bearing.
public struct BandRidge: Sendable, Equatable {
    /// Radians above the eye's horizontal, with the Earth's curvature and refraction: the elevation angle of the
    /// band's highest apparent ground.
    public let angle: Double
    /// Metres from the observer to that ground, along the great circle.
    public let distance: Double
}

/// One bearing of a panorama.
public struct PanoramaColumn: Sendable, Equatable {
    /// Degrees clockwise from true north, in 0..<360.
    public let bearing: Double
    /// One entry per band, nearest first: its highest ground, or `nil` where the band has no ground.
    public let ridges: [BandRidge?]
}

/// The horizon around an observer, band by band: for each bearing of a fan, the highest ground in each distance band.
public struct Panorama: Sendable, Equatable {
    /// The band edges the panorama was asked for, in metres.
    public let bands: [Double]
    /// One column per bearing, left to right.
    public let columns: [PanoramaColumn]
}
