import CoreLocation

/// The result of ``Curvature/analyze(_:)``: a line measured the way the pipeline measures roads.
public struct CurvatureAnalysis: Sendable, Equatable {
    /// The line after vertices closer than 5 m to their kept neighbour were merged away. The length, the score and the
    /// corner distances all refer to these vertices.
    public let merged: [CLLocationCoordinate2D]
    /// The length of ``merged`` in metres.
    public let length: Double
    /// The curvature score, in metres of weighted length. 0 for fewer than three merged vertices.
    public let score: Double
    /// The corners in drawing order.
    public let corners: [Corner]

    /// Creates an analysis from its parts.
    public init(merged: [CLLocationCoordinate2D], length: Double, score: Double, corners: [Corner]) {
        self.merged = merged
        self.length = length
        self.score = score
        self.corners = corners
    }

    /// Two analyses are equal when every field is equal, coordinates by latitude and longitude.
    public static func == (lhs: CurvatureAnalysis, rhs: CurvatureAnalysis) -> Bool {
        lhs.length == rhs.length && lhs.score == rhs.score && lhs.corners == rhs.corners
            && lhs.merged.count == rhs.merged.count
            && zip(lhs.merged, rhs.merged).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
    }
}
