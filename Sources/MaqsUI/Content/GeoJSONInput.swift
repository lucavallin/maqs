import CoreLocation
import Foundation

/// Shared input hygiene for the line and marker builders.
enum GeoJSONInput {
    /// Whether a coordinate can be drawn: finite, latitude within ±90 and longitude within ±180.
    static func isValid(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && abs(coordinate.latitude) <= 90 && abs(coordinate.longitude) <= 180
    }

    /// Keeps the last element for each id, in the order of the last occurrences.
    static func lastWins<T>(_ items: [T], id: (T) -> String) -> [T] {
        var lastIndex: [String: Int] = [:]
        for (index, item) in items.enumerated() { lastIndex[id(item)] = index }
        return items.enumerated().filter { lastIndex[id($0.element)] == $0.offset }.map(\.element)
    }

    static func featureCollection(_ features: [[String: Any]]) -> Data {
        let object: [String: Any] = ["type": "FeatureCollection", "features": features]
        // Only strings, numbers and booleans go in, so serialisation cannot fail.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}
