/// A kind of point of interest the basemap can show, named by the Shortbread `pois` attribute that holds it.
///
/// For example `PointOfInterest(key: "amenity", value: "fuel")` is a fuel station,
/// `PointOfInterest(key: "tourism", value: "alpine_hut")` an alpine hut.
public struct PointOfInterest: Hashable, Sendable {
    /// The OSM key the basemap groups its point-of-interest layers by, for example `amenity`.
    public let key: String
    /// The value of that key, for example `fuel`.
    public let value: String

    /// Creates a point of interest from an OSM key and value.
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
