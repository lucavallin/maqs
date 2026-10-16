/// A WGS 84 bounding box, longitude before latitude as in the data files.
public struct BoundingBox: Sendable, Hashable {
    /// The western edge, in degrees longitude.
    public let minLon: Double
    /// The southern edge, in degrees latitude.
    public let minLat: Double
    /// The eastern edge, in degrees longitude.
    public let maxLon: Double
    /// The northern edge, in degrees latitude.
    public let maxLat: Double

    /// A box from its four edges.
    public init(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        self.minLon = minLon; self.minLat = minLat; self.maxLon = maxLon; self.maxLat = maxLat
    }

    /// From a manifest `bbox` array `[minLon, minLat, maxLon, maxLat]`; `nil` unless it has four numbers.
    public init?(_ array: [Double]) {
        guard array.count == 4 else { return nil }
        self.init(minLon: array[0], minLat: array[1], maxLon: array[2], maxLat: array[3])
    }

    /// Whether a point lies inside or on the edge. An inverted box contains nothing.
    public func contains(longitude: Double, latitude: Double) -> Bool {
        longitude >= minLon && longitude <= maxLon && latitude >= minLat && latitude <= maxLat
    }
}
