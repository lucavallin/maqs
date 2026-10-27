import CoreLocation

/// A peak, pass, hut, shelter or settlement from a places file.
public struct Place: Sendable, Equatable, Identifiable {
    /// The place's stable key.
    public let id: PlaceID
    /// The region of the file that holds the place.
    public let region: String
    /// The row id in that region's file, for ``Places/place(region:featureID:)``.
    public let featureID: Int64
    /// What the place is.
    public let kind: PlaceKind
    /// The `name` tag.
    public let name: String?
    /// The `name:it`, `name:de`, `name:fur` and `name:sl` tags, keyed `it`, `de`, `fur` and `sl`; only tags the
    /// place has.
    public let localizedNames: [String: String]
    /// The elevation in metres from the `ele` tag, when it has one.
    public let elevation: Double?
    /// The `wikidata` tag as written.
    public let wikidata: String?
    /// Where the place is.
    public let coordinate: CLLocationCoordinate2D
    /// The label priority; higher is more notable.
    public let rankScore: Double

    /// Compares every field; `CLLocationCoordinate2D` is not `Equatable`, so its two numbers are compared here.
    public static func == (a: Place, b: Place) -> Bool {
        a.id == b.id && a.region == b.region && a.featureID == b.featureID && a.kind == b.kind && a.name == b.name
            && a.localizedNames == b.localizedNames && a.elevation == b.elevation && a.wikidata == b.wikidata
            && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
            && a.rankScore == b.rankScore
    }
}
