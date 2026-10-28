import CoreLocation
import Foundation

/// What the GeoJSON of a marker needs, without the UIKit content type.
struct MarkerKey: Equatable {
    var id: String
    var coordinate: CLLocationCoordinate2D
    var imageName: String
    var label: String?
    var isHidden: Bool

    static func == (lhs: MarkerKey, rhs: MarkerKey) -> Bool {
        lhs.id == rhs.id && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude && lhs.imageName == rhs.imageName
            && lhs.label == rhs.label && lhs.isHidden == rhs.isHidden
    }
}

/// Builds the GeoJSON of the `maqs-markers` source.
enum MarkerFeatures {
    /// One `Point` feature per marker with `maqs_id`, `maqs_image`, `maqs_label` (omitted without a label),
    /// `maqs_hidden` and `maqs_selected`.
    ///
    /// `imageName` is the name of the variant to draw, selected or not; the caller picks it. Duplicate ids keep the
    /// last marker, a marker with a bad coordinate is skipped, and an unknown `selectedID` marks nothing.
    static func geoJSON(_ markers: [MarkerKey], selectedID: String?) -> Data {
        let features: [[String: Any]] = GeoJSONInput.lastWins(markers, id: \.id).compactMap { marker in
            guard GeoJSONInput.isValid(marker.coordinate) else {
                logger.debug("skipped a marker with a bad coordinate")
                return nil
            }
            var properties: [String: Any] = [
                "maqs_id": marker.id,
                "maqs_image": marker.imageName,
                "maqs_hidden": marker.isHidden,
                "maqs_selected": marker.id == selectedID,
            ]
            if let label = marker.label { properties["maqs_label"] = label }
            return [
                "type": "Feature",
                "geometry": ["type": "Point", "coordinates": [marker.coordinate.longitude, marker.coordinate.latitude]] as [String: Any],
                "properties": properties,
            ]
        }
        return GeoJSONInput.featureCollection(features)
    }
}
