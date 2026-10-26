import CoreLocation
import Testing
@testable import MaqsTerrain

@Suite struct GeodesyTests {
    private func point(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    @Test func aDegreeOfLongitudeOnTheEquatorIsAboutOneHundredElevenKilometres() {
        #expect(abs(Geodesy.distance(point(0, 0), point(0, 1)) - 111_195.08) < 0.01)
    }

    @Test func bearingsFollowTheCompass() {
        #expect(abs(Geodesy.initialBearing(from: point(0, 0), to: point(1, 0))) < 1e-9)
        #expect(abs(Geodesy.initialBearing(from: point(0, 0), to: point(0, 1)) - 90) < 1e-9)
        #expect(abs(Geodesy.initialBearing(from: point(0, 0), to: point(-1, 0)) - 180) < 1e-9)
        #expect(abs(Geodesy.initialBearing(from: point(0, 0), to: point(0, -1)) - 270) < 1e-9)
    }

    @Test func destinationMovesAlongTheBearing() {
        let end = Geodesy.destination(from: point(0, 0), bearing: 90, distance: Geodesy.radius * .pi / 180)
        #expect(abs(end.latitude) < 1e-9)
        #expect(abs(end.longitude - 1) < 1e-9)
    }

    @Test func destinationWrapsAcrossTheAntimeridian() {
        let end = Geodesy.destination(from: point(0, 179.5), bearing: 90, distance: Geodesy.distance(point(0, 0), point(0, 1)))
        #expect(abs(end.latitude) < 1e-9)
        #expect(abs(end.longitude - (-179.5)) < 1e-9)
    }

    @Test func theMidpointOfTwoPointsOnTheEquatorIsHalfway() {
        let middle = Geodesy.intermediate(from: point(0, 0), to: point(0, 10), fraction: 0.5)
        #expect(abs(middle.latitude) < 1e-9)
        #expect(abs(middle.longitude - 5) < 1e-9)
    }

    @Test func intermediateKeepsTheEndsAndHandlesCoincidentPoints() {
        let start = Geodesy.intermediate(from: point(46, 12), to: point(47, 13), fraction: 0)
        let end = Geodesy.intermediate(from: point(46, 12), to: point(47, 13), fraction: 1)
        #expect(abs(start.latitude - 46) < 1e-9 && abs(start.longitude - 12) < 1e-9)
        #expect(abs(end.latitude - 47) < 1e-9 && abs(end.longitude - 13) < 1e-9)
        let same = Geodesy.intermediate(from: point(46, 12), to: point(46, 12), fraction: 0.5)
        #expect(abs(same.latitude - 46) < 1e-9 && abs(same.longitude - 12) < 1e-9)
    }
}
