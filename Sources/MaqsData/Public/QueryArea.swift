import Foundation

/// A longitude/latitude box in degrees (WGS 84), for area queries.
public struct QueryArea: Sendable, Equatable {
    /// The western edge, in -180...180.
    public let minLongitude: Double
    /// The southern edge, in -90...90.
    public let minLatitude: Double
    /// The eastern edge, greater than ``minLongitude``.
    public let maxLongitude: Double
    /// The northern edge, greater than ``minLatitude``.
    public let maxLatitude: Double

    /// Creates a box that does not cross the antimeridian.
    ///
    /// - Throws: ``QueryError/invalidInput(_:)`` when a bound is not finite or out of range, or a minimum is not
    ///   below its maximum.
    public init(minLongitude: Double, minLatitude: Double, maxLongitude: Double, maxLatitude: Double) throws(QueryError) {
        let longitudes = -180.0...180.0
        let latitudes = -90.0...90.0
        guard longitudes.contains(minLongitude), longitudes.contains(maxLongitude),
              latitudes.contains(minLatitude), latitudes.contains(maxLatitude) else {
            throw .invalidInput("area bounds must be finite, longitude within -180...180 and latitude within -90...90")
        }
        guard minLongitude < maxLongitude, minLatitude < maxLatitude else {
            throw .invalidInput("area minimum bounds must be below the maximum bounds")
        }
        self.minLongitude = minLongitude
        self.minLatitude = minLatitude
        self.maxLongitude = maxLongitude
        self.maxLatitude = maxLatitude
    }

    /// A box as a file stores it, where a one-point trail has equal minimum and maximum.
    init(stored minLongitude: Double, _ minLatitude: Double, _ maxLongitude: Double, _ maxLatitude: Double) {
        self.minLongitude = minLongitude
        self.minLatitude = minLatitude
        self.maxLongitude = maxLongitude
        self.maxLatitude = maxLatitude
    }
}
