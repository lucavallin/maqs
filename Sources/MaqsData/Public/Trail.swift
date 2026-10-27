import CoreLocation

/// A trail with its path and provenance.
public struct Trail: Sendable {
    /// The fields search lists.
    public let summary: TrailSummary
    /// Whether the trail returns to its start, when the source says.
    public let roundtrip: Bool?
    /// When the source last surveyed the trail.
    public let surveyDate: String?
    /// The trail's web page.
    public let website: String?
    /// The licence of the trail's source.
    public let sourceLicence: String?
    /// The date of the source data.
    public let sourceDate: String?
    /// The OSM element type (`relation`, `way`), for OSM trails.
    public let osmType: String?
    /// The OSM element id, for OSM trails.
    public let osmID: Int64?
    /// The primary trail this one is a duplicate of, for a secondary record from a lower-priority source.
    public let secondaryOf: TrailID?
    /// The trail's legs in order, each a line of coordinates; empty when the trail has no geometry. More than one leg
    /// means gaps between them.
    public let path: [[CLLocationCoordinate2D]]
}
