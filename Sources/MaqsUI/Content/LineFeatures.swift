import Foundation

/// Builds the GeoJSON of the `maqs-lines` source from the app's lines.
enum LineFeatures {
    /// One `LineString` feature per line with `maqs_id`, `maqs_style` (`solid` or `hidden`), `maqs_active` and `maqs_glow`.
    ///
    /// Duplicate ids keep the last line, bad coordinates are dropped, a line with fewer than two points is skipped,
    /// and an unknown `activeID` marks nothing.
    static func geoJSON(_ lines: [MapLine], activeID: String?) -> Data {
        let features: [[String: Any]] = GeoJSONInput.lastWins(lines, id: \.id).compactMap { line in
            let valid = line.coordinates.filter(GeoJSONInput.isValid)
            if valid.count != line.coordinates.count {
                logger.debug("dropped \(line.coordinates.count - valid.count) bad points from a line")
            }
            guard valid.count >= 2 else {
                logger.debug("skipped a line with fewer than two usable points")
                return nil
            }
            return [
                "type": "Feature",
                "geometry": ["type": "LineString", "coordinates": valid.map { [$0.longitude, $0.latitude] }] as [String: Any],
                "properties": [
                    "maqs_id": line.id,
                    "maqs_style": line.style == .solid ? "solid" : "hidden",
                    "maqs_active": line.id == activeID,
                    "maqs_glow": line.glows,
                ] as [String: Any],
            ]
        }
        return GeoJSONInput.featureCollection(features)
    }
}
