import CoreLocation

/// The pipeline's `encode_polyline` (`pipeline/src/maqs/geometry.py`): precision 6, latitude first, each value the
/// difference to the previous point, rounded half to even like Python's `round`. Test-only: the package never encodes.
enum Polyline6Encoder {
    /// One leg as an encoded polyline.
    static func encode(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var text = ""
        var lastLatitude: Int64 = 0
        var lastLongitude: Int64 = 0
        for coordinate in coordinates {
            let latitude = Int64((coordinate.latitude * 1_000_000).rounded(.toNearestOrEven))
            let longitude = Int64((coordinate.longitude * 1_000_000).rounded(.toNearestOrEven))
            text += value(latitude - lastLatitude)
            text += value(longitude - lastLongitude)
            lastLatitude = latitude
            lastLongitude = longitude
        }
        return text
    }

    /// Several legs, one polyline each, joined by `;` as the trails layer stores them.
    static func encode(legs: [[CLLocationCoordinate2D]]) -> String {
        legs.map { encode($0) }.joined(separator: ";")
    }

    private static func value(_ value: Int64) -> String {
        var remaining = value < 0 ? ~(value << 1) : value << 1
        var text = ""
        while remaining >= 0x20 {
            text.append(Character(Unicode.Scalar(UInt8((0x20 | (remaining & 0x1F)) + 63))))
            remaining >>= 5
        }
        text.append(Character(Unicode.Scalar(UInt8(remaining + 63))))
        return text
    }
}
