/// A place found in a ``BearingCone``, with where it lies from the cone's origin.
public struct PlaceInCone: Sendable, Equatable {
    /// The place.
    public let place: Place
    /// The great-circle distance from the origin in metres.
    public let distance: Double
    /// The initial bearing from the origin to the place, in degrees clockwise from north, in 0..<360.
    public let bearing: Double
    /// The bearing relative to the cone's, in degrees from -180 to 180; negative to the left.
    public let offset: Double
}
