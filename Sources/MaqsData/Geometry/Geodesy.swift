import CoreLocation
import Foundation

/// Great-circle geometry on a sphere of the mean Earth radius, the one the pipeline measures with.
enum Geodesy {
    static let radius = 6_371_008.8
    /// The pipeline's local plane (`geometry.py`): metres per degree of latitude, and of longitude on the equator.
    static let metresPerDegreeLatitude = 110_574.0
    static let metresPerDegreeLongitudeAtEquator = 111_320.0

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Haversine distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let latitudeA = radians(a.latitude)
        let latitudeB = radians(b.latitude)
        let deltaLatitude = latitudeB - latitudeA
        let deltaLongitude = radians(b.longitude - a.longitude)
        let h = pow(sin(deltaLatitude / 2), 2) + cos(latitudeA) * cos(latitudeB) * pow(sin(deltaLongitude / 2), 2)
        return 2 * radius * asin(min(1, h.squareRoot()))
    }

    /// Initial bearing in degrees clockwise from north, in [0, 360).
    static func initialBearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let latitudeFrom = radians(from.latitude)
        let latitudeTo = radians(to.latitude)
        let deltaLongitude = radians(to.longitude - from.longitude)
        let y = sin(deltaLongitude) * cos(latitudeTo)
        let x = cos(latitudeFrom) * sin(latitudeTo) - sin(latitudeFrom) * cos(latitudeTo) * cos(deltaLongitude)
        let bearing = degrees(atan2(y, x)).truncatingRemainder(dividingBy: 360)
        return bearing < 0 ? bearing + 360 : bearing
    }

    /// Whether `c` is a real position: finite, latitude in -90...90, longitude in -180...180. The no-fix value
    /// `kCLLocationCoordinate2DInvalid` (-180, -180) fails on its latitude.
    static func isValid(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude.isFinite && c.longitude.isFinite && abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }

    /// The point of `line` closest to `p`, found in the local plane of each vertex pair.
    ///
    /// `distance` is in metres, `along` is the haversine length of the line up to the point, and `heading` is the
    /// bearing of the pair the point lies on, in the line's drawing direction. Nil for an empty line; a one-vertex
    /// line gives that vertex. On a tie the earlier pair wins.
    static func nearestPoint(on line: [CLLocationCoordinate2D], to p: CLLocationCoordinate2D)
        -> (distance: Double, along: Double, heading: Double)? {
        guard let first = line.first else { return nil }
        guard line.count > 1 else { return (distance(first, p), 0, 0) }

        var best: (distance: Double, along: Double, heading: Double)?
        var lengthBefore = 0.0
        for index in 1..<line.count {
            let a = line[index - 1]
            let b = line[index]
            let scaleLongitude = metresPerDegreeLongitudeAtEquator * cos(radians(a.latitude))
            let bx = (b.longitude - a.longitude) * scaleLongitude
            let by = (b.latitude - a.latitude) * metresPerDegreeLatitude
            let px = (p.longitude - a.longitude) * scaleLongitude
            let py = (p.latitude - a.latitude) * metresPerDegreeLatitude
            let squaredLength = bx * bx + by * by
            let t = squaredLength > 0 ? max(0, min(1, (px * bx + py * by) / squaredLength)) : 0
            let dx = px - t * bx
            let dy = py - t * by
            let offset = (dx * dx + dy * dy).squareRoot()
            let pairLength = distance(a, b)
            if offset < (best?.distance ?? .infinity) {
                best = (offset, lengthBefore + t * pairLength, initialBearing(from: a, to: b))
            }
            lengthBefore += pairLength
        }
        return best
    }

    /// The point `along` metres from the start of `line`, clamped to the line (its first vertex below 0, its last
    /// beyond its length). An empty line gives `kCLLocationCoordinate2DInvalid`.
    static func point(on line: [CLLocationCoordinate2D], at along: Double) -> CLLocationCoordinate2D {
        guard let first = line.first else { return kCLLocationCoordinate2DInvalid }
        guard along > 0, line.count > 1 else { return first }
        var lengthBefore = 0.0
        for index in 1..<line.count {
            let a = line[index - 1]
            let b = line[index]
            let pairLength = distance(a, b)
            if along <= lengthBefore + pairLength {
                let fraction = pairLength > 0 ? (along - lengthBefore) / pairLength : 0
                return CLLocationCoordinate2D(
                    latitude: a.latitude + fraction * (b.latitude - a.latitude),
                    longitude: a.longitude + fraction * (b.longitude - a.longitude))
            }
            lengthBefore += pairLength
        }
        return line[line.count - 1]
    }
}
