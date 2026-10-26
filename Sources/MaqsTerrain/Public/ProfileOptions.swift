import Foundation

/// How ``Terrain/profile(from:to:options:)`` spaces its samples and models the Earth.
public struct ProfileOptions: Sendable, Equatable {
    /// Metres between samples, at least 1. `nil` uses one 512 px tile pixel at the start latitude, at the zoom of the band the sample lies in.
    public var step: Double?
    /// Curvature and refraction applied to the apparent elevation.
    public var earth: EarthModel
    /// The zoom limit by distance from the start.
    public var bands: ZoomBands

    /// Creates options; every parameter has the default the package documents.
    public init(step: Double? = nil, earth: EarthModel = EarthModel(), bands: ZoomBands = .standard) {
        self.step = step
        self.earth = earth
        self.bands = bands
    }
}
