import CoreLocation
import Foundation

/// Great-circle geometry on a sphere of the mean Earth radius, whatever ``EarthModel`` a caller picks: the model only shapes curvature drop.
enum Geodesy {
    static let radius = 6_371_008.8

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Longitude folded into [-180, 180).
    private static func wrapped(_ longitude: Double) -> Double {
        var value = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value - 180
    }

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

    /// The point reached by travelling `distance` metres from `from` along `bearing` degrees; longitude in [-180, 180).
    static func destination(from: CLLocationCoordinate2D, bearing: Double, distance: Double) -> CLLocationCoordinate2D {
        let angular = distance / radius
        let heading = radians(bearing)
        let latitude = radians(from.latitude)
        let sinLatitude = sin(latitude) * cos(angular) + cos(latitude) * sin(angular) * cos(heading)
        let newLatitude = asin(max(-1, min(1, sinLatitude)))
        let newLongitude = radians(from.longitude)
            + atan2(sin(heading) * sin(angular) * cos(latitude), cos(angular) - sin(latitude) * sin(newLatitude))
        return CLLocationCoordinate2D(latitude: degrees(newLatitude), longitude: wrapped(degrees(newLongitude)))
    }

    /// The point `fraction` (0...1) of the way along the great circle from `from` to `to`.
    static func intermediate(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, fraction: Double) -> CLLocationCoordinate2D {
        let angular = distance(from, to) / radius
        guard angular > 1e-12 else { return from }
        let latitudeFrom = radians(from.latitude)
        let latitudeTo = radians(to.latitude)
        let longitudeFrom = radians(from.longitude)
        let longitudeTo = radians(to.longitude)
        let weightFrom = sin((1 - fraction) * angular) / sin(angular)
        let weightTo = sin(fraction * angular) / sin(angular)
        let x = weightFrom * cos(latitudeFrom) * cos(longitudeFrom) + weightTo * cos(latitudeTo) * cos(longitudeTo)
        let y = weightFrom * cos(latitudeFrom) * sin(longitudeFrom) + weightTo * cos(latitudeTo) * sin(longitudeTo)
        let z = weightFrom * sin(latitudeFrom) + weightTo * sin(latitudeTo)
        return CLLocationCoordinate2D(latitude: degrees(atan2(z, (x * x + y * y).squareRoot())), longitude: wrapped(degrees(atan2(y, x))))
    }
}
