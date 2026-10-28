import CoreLocation
import Foundation
import Testing

@testable import MaqsUI

@Suite struct MarkerFeaturesTests {
    private func features(_ data: Data) throws -> [[String: Any]] {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["features"] as? [[String: Any]])
    }

    private func properties(_ feature: [String: Any]) -> [String: Any] { feature["properties"] as? [String: Any] ?? [:] }

    private func key(_ id: String, lat: Double = 46.1, lon: Double = 12.2, label: String? = nil, hidden: Bool = false) -> MarkerKey {
        MarkerKey(id: id, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), imageName: "img-\(id)", label: label, isHidden: hidden)
    }

    @Test func encodesPointsWithLongitudeFirstSelectionAndHiddenFlags() throws {
        let list = try features(MarkerFeatures.geoJSON([key("a", label: "Hut"), key("b", hidden: true)], selectedID: "a"))
        #expect(list.count == 2)
        let geometry = try #require(list[0]["geometry"] as? [String: Any])
        #expect(geometry["type"] as? String == "Point")
        #expect(geometry["coordinates"] as? [Double] == [12.2, 46.1])
        let first = properties(list[0])
        #expect(first["maqs_id"] as? String == "a")
        #expect(first["maqs_image"] as? String == "img-a")
        #expect(first["maqs_label"] as? String == "Hut")
        #expect(first["maqs_hidden"] as? Bool == false)
        #expect(first["maqs_selected"] as? Bool == true)
        let second = properties(list[1])
        #expect(second["maqs_hidden"] as? Bool == true)
        #expect(second["maqs_selected"] as? Bool == false)
    }

    @Test func omitsTheLabelKeyWithoutALabel() throws {
        let list = try features(MarkerFeatures.geoJSON([key("a")], selectedID: nil))
        #expect(properties(list[0])["maqs_label"] == nil)
    }

    @Test func duplicateIdsKeepTheLast() throws {
        let list = try features(MarkerFeatures.geoJSON([key("a", lat: 1, lon: 2), key("a", lat: 3, lon: 4)], selectedID: nil))
        #expect(list.count == 1)
        #expect((list[0]["geometry"] as? [String: Any])?["coordinates"] as? [Double] == [4, 3])
    }

    @Test func skipsMarkersWithBadCoordinates() throws {
        let list = try features(MarkerFeatures.geoJSON([
            key("nan", lat: .nan), key("lat", lat: -90.5), key("lon", lon: 200), key("ok"),
        ], selectedID: nil))
        #expect(list.map { properties($0)["maqs_id"] as? String } == ["ok"])
    }

    @Test func unknownSelectedIdMarksNothing() throws {
        let list = try features(MarkerFeatures.geoJSON([key("a")], selectedID: "zzz"))
        #expect(properties(list[0])["maqs_selected"] as? Bool == false)
    }
}
