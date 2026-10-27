import CoreLocation

/// A stretch of road with its curvature score and corners, as the curvature layer stores it.
public struct RoadSegment: Sendable, Identifiable {
    /// The OSM way id. It survives a new data release; row ids do not.
    public typealias ID = Int64

    /// The OSM way id.
    public let id: ID
    /// The road's name, as tagged.
    public let name: String?
    /// The road's number, as tagged.
    public let ref: String?
    /// The `highway` class, as tagged (`secondary`, `unclassified`, …).
    public let highway: String
    /// The `surface` tag, as tagged.
    public let surface: String?
    /// The `junction` tag, as tagged; nil when the way has none and in files built before the column existed.
    public let junction: String?
    /// The `maxspeed` tag, as tagged.
    public let maxspeed: String?
    /// The effective one-way: the file's `oneway` value when it is set, otherwise ``OneWay/forward`` for
    /// `junction=roundabout` and `highway=motorway`, which OSM implies are one-way in the drawing direction.
    /// `junction=circular` and `motorway_link` follow their own tag only. A file without the `junction` column
    /// infers only for motorways.
    public let oneway: OneWay
    /// Metres along the geometry.
    public let length: Double
    /// The curvature score.
    public let score: Double
    /// The OSM node id of the first vertex.
    public let startNode: Int64
    /// The OSM node id of the last vertex.
    public let endNode: Int64
    /// The path in drawing direction.
    public let geometry: [CLLocationCoordinate2D]
    /// The segment's corners in drawing direction, by ordinal.
    public let corners: [Corner]
}
