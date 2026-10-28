import CoreLocation
import Foundation
import Testing

@testable import MaqsUI

@Suite struct LineFeaturesTests {
    private func features(_ data: Data) throws -> [[String: Any]] {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["type"] as? String == "FeatureCollection")
        return try #require(object["features"] as? [[String: Any]])
    }

    private func properties(_ feature: [String: Any]) -> [String: Any] { feature["properties"] as? [String: Any] ?? [:] }

    private func coordinates(_ feature: [String: Any]) -> [[Double]] {
        ((feature["geometry"] as? [String: Any])?["coordinates"] as? [[Double]]) ?? []
    }

    private static let a = [CLLocationCoordinate2D(latitude: 46.1, longitude: 12.2), CLLocationCoordinate2D(latitude: 46.2, longitude: 12.3)]

    @Test func encodesLinesWithLongitudeFirstAndAllProperties() throws {
        let lines = [
            MapLine(id: "route", coordinates: Self.a, style: .solid, glows: true),
            MapLine(id: "alt", coordinates: Self.a, style: .hidden),
        ]
        let list = try features(LineFeatures.geoJSON(lines, activeID: "route"))
        #expect(list.count == 2)
        #expect((list[0]["geometry"] as? [String: Any])?["type"] as? String == "LineString")
        #expect(coordinates(list[0]) == [[12.2, 46.1], [12.3, 46.2]])
        let first = properties(list[0])
        #expect(first["maqs_id"] as? String == "route")
        #expect(first["maqs_style"] as? String == "solid")
        #expect(first["maqs_active"] as? Bool == true)
        #expect(first["maqs_glow"] as? Bool == true)
        let second = properties(list[1])
        #expect(second["maqs_id"] as? String == "alt")
        #expect(second["maqs_style"] as? String == "hidden")
        #expect(second["maqs_active"] as? Bool == false)
        #expect(second["maqs_glow"] as? Bool == false)
    }

    @Test func duplicateIdsKeepTheLast() throws {
        let other = [CLLocationCoordinate2D(latitude: 1, longitude: 2), CLLocationCoordinate2D(latitude: 3, longitude: 4)]
        let list = try features(LineFeatures.geoJSON([MapLine(id: "x", coordinates: Self.a), MapLine(id: "x", coordinates: other)], activeID: nil))
        #expect(list.count == 1)
        #expect(coordinates(list[0]) == [[2, 1], [4, 3]])
    }

    @Test func dropsBadPointsAndSkipsLinesLeftWithFewerThanTwo() throws {
        let bad = [
            CLLocationCoordinate2D(latitude: .nan, longitude: 12), CLLocationCoordinate2D(latitude: 91, longitude: 12),
            CLLocationCoordinate2D(latitude: 10, longitude: 181), CLLocationCoordinate2D(latitude: 10, longitude: .infinity),
        ]
        let list = try features(LineFeatures.geoJSON([
            MapLine(id: "mixed", coordinates: bad + Self.a),
            MapLine(id: "one-left", coordinates: bad + [Self.a[0]]),
            MapLine(id: "empty", coordinates: []),
        ], activeID: nil))
        #expect(list.map { properties($0)["maqs_id"] as? String } == ["mixed"])
        #expect(coordinates(list[0]) == [[12.2, 46.1], [12.3, 46.2]])
    }

    @Test func unknownActiveIdMarksNothing() throws {
        let list = try features(LineFeatures.geoJSON([MapLine(id: "a", coordinates: Self.a)], activeID: "missing"))
        #expect(properties(list[0])["maqs_active"] as? Bool == false)
    }

    @Test func noLinesGiveAnEmptyCollection() throws {
        #expect(try features(LineFeatures.geoJSON([], activeID: nil)).isEmpty)
    }
}
