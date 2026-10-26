import Foundation

/// How far the Earth's surface falls away from a straight sight line, with atmospheric refraction folded in.
public struct EarthModel: Sendable, Equatable {
    /// Earth radius in metres; `.infinity` means a flat Earth.
    public var radius: Double
    /// The refraction coefficient `k`; light bends over the curve, so the apparent drop is scaled by `1 - k`.
    public var refraction: Double

    /// The mean Earth radius and the usual terrestrial refraction coefficient of 0.13.
    public init(radius: Double = 6_371_008.8, refraction: Double = 0.13) {
        self.radius = radius
        self.refraction = refraction
    }

    /// No curvature and no refraction.
    public static let none = EarthModel(radius: .infinity, refraction: 0)

    /// The apparent drop in metres of the surface at `distance` metres: `d² / (2R) × (1 − k)`, and 0 for a flat Earth.
    public func drop(atDistance distance: Double) -> Double {
        guard radius.isFinite else { return 0 }
        return distance * distance / (2 * radius) * (1 - refraction)
    }
}
