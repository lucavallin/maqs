import CoreLocation
import Foundation
import Testing
@testable import MaqsData

@Suite struct GeodesyTests {
    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// A 100 m line running east along latitude 46, from longitude 12.
    private var eastLine: [CLLocationCoordinate2D] {
        let metresPerDegree = 111_195.08 * cos(46.0 * .pi / 180)
        return [coordinate(46, 12), coordinate(46, 12 + 100 / metresPerDegree)]
    }

    /// The point `east` metres along `eastLine` and `north` metres off it.
    private func offset(east: Double, north: Double) -> CLLocationCoordinate2D {
        let metresPerDegree = 111_195.08
        return coordinate(
            46 + north / metresPerDegree,
            12 + east / (metresPerDegree * cos(46.0 * .pi / 180)))
    }

    @Test func aDegreeOfLongitudeOnTheEquatorIsAbout111Kilometres() {
        #expect(abs(Geodesy.distance(coordinate(0, 0), coordinate(0, 1)) - 111_195.08) < 0.01)
    }

    @Test func bearingsFollowTheCompass() {
        #expect(Geodesy.initialBearing(from: coordinate(0, 0), to: coordinate(1, 0)) == 0)
        #expect(abs(Geodesy.initialBearing(from: coordinate(0, 0), to: coordinate(0, 1)) - 90) < 1e-9)
        #expect(abs(Geodesy.initialBearing(from: coordinate(0, 0), to: coordinate(-1, 0)) - 180) < 1e-9)
        #expect(abs(Geodesy.initialBearing(from: coordinate(0, 0), to: coordinate(0, -1)) - 270) < 1e-9)
    }

    @Test func aPointOffTheLineProjectsOntoIt() throws {
        let result = try #require(Geodesy.nearestPoint(on: eastLine, to: offset(east: 30, north: 10)))
        #expect(abs(result.distance - 10) < 0.1)
        #expect(abs(result.along - 30) < 0.1)
        #expect(abs(result.heading - 90) < 0.1)
    }

    @Test func pastEitherEndTheNearestPointIsTheEnd() throws {
        let line = eastLine
        let length = Geodesy.distance(line[0], line[1])
        let before = try #require(Geodesy.nearestPoint(on: line, to: offset(east: -20, north: 0)))
        #expect(before.along == 0)
        #expect(abs(before.distance - 20) < 0.1)
        let after = try #require(Geodesy.nearestPoint(on: line, to: offset(east: 130, north: 0)))
        #expect(abs(after.along - length) < 1e-9)
        #expect(abs(after.distance - 30) < 0.1)
    }

    @Test func theNearestPairWinsOnALongerLine() throws {
        let line = [coordinate(46, 12), coordinate(46, 12.001), coordinate(46.001, 12.001)]
        let result = try #require(Geodesy.nearestPoint(on: line, to: coordinate(46.0005, 12.0011)))
        #expect(abs(result.heading) < 0.1)
        let expectedAlong = Geodesy.distance(line[0], line[1]) + Geodesy.distance(line[1], coordinate(46.0005, 12.001))
        #expect(abs(result.along - expectedAlong) < 0.1)
    }

    @Test func emptyAndSingleVertexLines() throws {
        #expect(Geodesy.nearestPoint(on: [], to: coordinate(46, 12)) == nil)
        let single = try #require(Geodesy.nearestPoint(on: [coordinate(46, 12)], to: coordinate(46, 12.001)))
        #expect(abs(single.distance - Geodesy.distance(coordinate(46, 12), coordinate(46, 12.001))) < 1e-9)
        #expect(single.along == 0)
    }

    @Test func pointAtADistanceIsClampedToTheLine() {
        let line = eastLine
        let length = Geodesy.distance(line[0], line[1])
        let middle = Geodesy.point(on: line, at: 50)
        #expect(abs(Geodesy.distance(line[0], middle) - 50) < 0.01)
        #expect(Geodesy.point(on: line, at: -5).longitude == line[0].longitude)
        #expect(Geodesy.point(on: line, at: length + 500).longitude == line[1].longitude)
        #expect(Geodesy.point(on: [line[0]], at: 10).longitude == line[0].longitude)
    }

    @Test func isValidRejectsCoordinatesWithNoFix() {
        #expect(Geodesy.isValid(coordinate(46, 12)))
        #expect(Geodesy.isValid(coordinate(-90, 180)))
        #expect(!Geodesy.isValid(coordinate(.nan, 12)))
        #expect(!Geodesy.isValid(coordinate(46, .infinity)))
        #expect(!Geodesy.isValid(coordinate(-180, -180)))
        #expect(!Geodesy.isValid(kCLLocationCoordinate2DInvalid))
        #expect(!Geodesy.isValid(coordinate(46, 181)))
    }
}
