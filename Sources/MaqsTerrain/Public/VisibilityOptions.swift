import Foundation

/// How ``Terrain/visibility(of:from:options:)`` decides.
public struct VisibilityOptions: Sendable, Equatable {
    /// Targets farther than this many metres are ``Visibility/outOfRange(distance:)``. Default 100 km.
    public var maxDistance: Double
    /// A ridge hides a target only when it rises above the sight line by more than this many metres. Default 10; it leans the answer toward visible.
    public var margin: Double
    /// The last stretch before the target, in metres, that is not tested for hiding ground, so the target's own slope never hides it. Default 150.
    public var targetClearance: Double
    /// Curvature and refraction.
    public var earth: EarthModel
    /// The zoom limit by distance from the observer.
    public var bands: ZoomBands

    /// Creates options; every parameter has the default the package documents.
    public init(maxDistance: Double = 100_000, margin: Double = 10, targetClearance: Double = 150,
                earth: EarthModel = EarthModel(), bands: ZoomBands = .standard) {
        self.maxDistance = maxDistance
        self.margin = margin
        self.targetClearance = targetClearance
        self.earth = earth
        self.bands = bands
    }
}
