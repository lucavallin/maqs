import CoreLocation

/// A rectangle of the world, in WGS 84 degrees, at most two degrees on a side.
public struct TerrainArea: Sendable, Equatable {
    /// The south-west corner.
    public let southWest: CLLocationCoordinate2D
    /// The north-east corner.
    public let northEast: CLLocationCoordinate2D

    private static let maxSpan = 2.0

    /// Throws ``TerrainError/invalidArea`` when a corner is not finite or out of range, the corners are inverted or equal
    /// on an axis, or the area spans more than two degrees of latitude or longitude.
    public init(southWest: CLLocationCoordinate2D, northEast: CLLocationCoordinate2D) throws(TerrainError) {
        let values = [southWest.latitude, southWest.longitude, northEast.latitude, northEast.longitude]
        guard values.allSatisfy(\.isFinite),
            abs(southWest.latitude) <= 90, abs(northEast.latitude) <= 90,
            abs(southWest.longitude) <= 180, abs(northEast.longitude) <= 180,
            southWest.latitude < northEast.latitude, southWest.longitude < northEast.longitude,
            northEast.latitude - southWest.latitude <= Self.maxSpan,
            northEast.longitude - southWest.longitude <= Self.maxSpan
        else {
            throw .invalidArea
        }
        self.southWest = southWest
        self.northEast = northEast
    }

    public static func == (lhs: TerrainArea, rhs: TerrainArea) -> Bool {
        lhs.southWest.latitude == rhs.southWest.latitude && lhs.southWest.longitude == rhs.southWest.longitude
            && lhs.northEast.latitude == rhs.northEast.latitude && lhs.northEast.longitude == rhs.northEast.longitude
    }
}
