import CoreLocation
import Foundation
import Testing
@testable import MaqsData

@Suite struct PolylineTests {
    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func decodeFailure(_ text: String) -> PolylineError? {
        do {
            _ = try Polyline6.decode(Substring(text))
            return nil
        } catch {
            return error
        }
    }

    @Test func decodesTheWorkedExample() throws {
        let one = try Polyline6.decode("_av|vA_xtjV")
        #expect(one.count == 1)
        #expect(abs(one[0].latitude - 46.1) < 1e-12)
        #expect(abs(one[0].longitude - 12.25) < 1e-12)

        let two = try Polyline6.decode("_av|vA_xtjVoKgE")
        #expect(two.count == 2)
        #expect(abs(two[1].latitude - 46.1002) < 1e-12)
        #expect(abs(two[1].longitude - 12.2501) < 1e-12)
    }

    @Test func everyGoldenGeometryDecodesLikeThePipeline() throws {
        let golden = try DataGolden.load()
        #expect(!golden.segments.isEmpty)
        for segment in golden.segments {
            let decoded = try Polyline6.decode(Substring(segment.geometry))
            #expect(decoded.count == segment.coordinates.count, "way \(segment.osmWayId)")
            for (got, expected) in zip(decoded, segment.coordinates) {
                #expect(abs(got.longitude - expected[0]) < 1e-12)
                #expect(abs(got.latitude - expected[1]) < 1e-12)
            }
        }
    }

    @Test func legsSplitOnSemicolons() throws {
        let legs = try Polyline6.decodeLegs("_av|vA_xtjV;_av|vA_xtjVoKgE")
        #expect(legs.map(\.count) == [1, 2])
    }

    @Test func anEmptyGeometryHasNoLegs() throws {
        #expect(try Polyline6.decodeLegs("").isEmpty)
        #expect(try Polyline6.decode("").isEmpty)
    }

    @Test func rejectsACharacterOutsideTheAlphabet() {
        #expect(decodeFailure("_av| vA_xtjV") == .badCharacter)
    }

    @Test func rejectsAValueOfThirteenGroups() {
        #expect(decodeFailure(String(repeating: "_", count: 12) + "?" + "?") == .valueTooLong)
    }

    @Test func rejectsTextEndingMidValue() {
        #expect(decodeFailure("_av|vA_xt") == .truncated)
    }

    @Test func rejectsAnOddNumberOfValues() {
        #expect(decodeFailure("_av|vA") == .oddValueCount)
    }

    @Test func rejectsALatitudeOfNinetyFiveDegrees() {
        #expect(decodeFailure(Polyline6Encoder.encode([coordinate(95, 12)])) == .outOfRange)
    }

    @Test func rejectsALongitudeBeyondTheAntimeridian() {
        #expect(decodeFailure(Polyline6Encoder.encode([coordinate(46, 181)])) == .outOfRange)
    }

    @Test func rejectsTheLargestTwelveGroupValueWithoutOverflowing() {
        // Eleven groups of 0b11110 with the continuation bit, then a closing 0b11111: about 2^59 as a latitude.
        let huge = String(repeating: "}", count: 11) + "^"
        #expect(decodeFailure(huge + "?") == .outOfRange)
    }
}
