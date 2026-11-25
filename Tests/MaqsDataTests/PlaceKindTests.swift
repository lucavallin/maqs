import Testing

@testable import MaqsData

@Suite struct PlaceKindTests {
    @Test func readsTownsAndCities() {
        #expect(PlaceKind(column: "town") == .town)
        #expect(PlaceKind(column: "city") == .city)
        #expect(PlaceKind.town.column == "town")
        #expect(PlaceKind.city.column == "city")
    }

    @Test func everyKnownKindRoundTripsAndAnUnknownOneStaysOther() {
        let known: [PlaceKind] = [
            .pass, .peak, .volcano, .saddle, .alpineHut, .wildernessHut, .shelter, .city, .town, .village, .hamlet,
            .isolatedDwelling,
        ]
        for kind in known {
            #expect(PlaceKind(column: kind.column) == kind)
        }
        #expect(PlaceKind(column: "suburb") == .other("suburb"))
    }
}
