import Foundation

/// Builds the GeoJSON of the `maqs-lines` source from the app's lines.
enum LineFeatures {
    /// One feature per line with `maqs_id`, `maqs_style` (`solid` or `hidden`), `maqs_active` and `maqs_glow`: a
    /// `LineString` for one usable run, a `MultiLineString` for several.
    ///
    /// Duplicate ids keep the last line, bad coordinates are dropped, a run with fewer than two points is dropped, a
    /// line with no run left is skipped, and an unknown `activeID` marks nothing.
    static func geoJSON(_ lines: [MapLine], activeID: String?) -> Data {
        let features: [[String: Any]] = GeoJSONInput.lastWins(lines, id: \.id).compactMap { line in
            let runs = line.segments.compactMap { run -> [[Double]]? in
                let valid = run.filter(GeoJSONInput.isValid)
                if valid.count != run.count {
                    logger.debug("dropped \(run.count - valid.count) bad points from a line")
                }
                return valid.count >= 2 ? valid.map { [$0.longitude, $0.latitude] } : nil
            }
            guard let first = runs.first else {
                logger.debug("skipped a line with fewer than two usable points")
                return nil
            }
            let geometry: [String: Any] = runs.count == 1
                ? ["type": "LineString", "coordinates": first]
                : ["type": "MultiLineString", "coordinates": runs]
            return [
                "type": "Feature",
                "geometry": geometry,
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
