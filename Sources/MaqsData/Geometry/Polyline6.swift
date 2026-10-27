import CoreLocation
import Foundation

/// Why an encoded polyline could not be decoded. Callers know the file and map it to ``QueryError/corruptData(file:detail:)``.
enum PolylineError: Error, Equatable {
    /// A character outside 63...126, the encoded-polyline alphabet.
    case badCharacter
    /// A value of more than 12 five-bit groups, which would overflow a 64-bit integer.
    case valueTooLong
    /// The text ends in the middle of a value.
    case truncated
    /// The values do not pair up into latitude and longitude.
    case oddValueCount
    /// A decoded latitude or longitude outside its valid range.
    case outOfRange
}

/// Precision-6 encoded polylines (`docs/data-format.md`, Geometry encoding): latitude first, each value the difference
/// to the previous one. The decoder reads untrusted bytes, so it bounds every value and checks every sum.
enum Polyline6 {
    private static let maximumGroups = 12
    private static let scale = 1_000_000.0
    private static let maximumLatitude: Int64 = 90_000_000
    private static let maximumLongitude: Int64 = 180_000_000

    /// Decodes one polyline; an empty text is an empty path.
    static func decode(_ text: Substring) throws(PolylineError) -> [CLLocationCoordinate2D] {
        let bytes = text.utf8
        var coordinates: [CLLocationCoordinate2D] = []
        var index = bytes.startIndex
        var latitude: Int64 = 0
        var longitude: Int64 = 0

        while index < bytes.endIndex {
            let latitudeStep = try value(in: bytes, at: &index)
            guard index < bytes.endIndex else { throw .oddValueCount }
            let longitudeStep = try value(in: bytes, at: &index)

            let (newLatitude, latitudeOverflow) = latitude.addingReportingOverflow(latitudeStep)
            let (newLongitude, longitudeOverflow) = longitude.addingReportingOverflow(longitudeStep)
            guard !latitudeOverflow, !longitudeOverflow,
                  newLatitude.magnitude <= maximumLatitude.magnitude,
                  newLongitude.magnitude <= maximumLongitude.magnitude
            else { throw .outOfRange }
            latitude = newLatitude
            longitude = newLongitude
            coordinates.append(CLLocationCoordinate2D(latitude: Double(latitude) / scale, longitude: Double(longitude) / scale))
        }
        return coordinates
    }

    /// Decodes a trail's legs, joined by `;` (`|` is part of the polyline alphabet); an empty text has no legs.
    static func decodeLegs(_ text: String) throws(PolylineError) -> [[CLLocationCoordinate2D]] {
        guard !text.isEmpty else { return [] }
        var legs: [[CLLocationCoordinate2D]] = []
        for leg in text.split(separator: ";", omittingEmptySubsequences: false) {
            legs.append(try decode(leg))
        }
        return legs
    }

    /// One zigzag-encoded signed value; leaves `index` after its last group.
    private static func value(in bytes: Substring.UTF8View, at index: inout Substring.UTF8View.Index) throws(PolylineError) -> Int64 {
        var result: Int64 = 0
        var groups = 0
        while true {
            guard index < bytes.endIndex else { throw .truncated }
            let character = bytes[index]
            guard (63...126).contains(character) else { throw .badCharacter }
            bytes.formIndex(after: &index)
            guard groups < maximumGroups else { throw .valueTooLong }
            let group = Int64(character - 63)
            result |= (group & 0x1F) << Int64(5 * groups)
            groups += 1
            if group < 0x20 { break }
        }
        return result & 1 == 1 ? ~(result >> 1) : result >> 1
    }
}
