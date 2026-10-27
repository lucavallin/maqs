import CoreLocation
import Foundation
import MaqsTestSupport

/// The pipeline's reference answers (`Fixtures/test/data-golden.json`, written by `scripts/update-data-golden.sh`):
/// every fixture road decoded and scored by the pipeline, and six synthetic tracks scored the same way.
struct DataGolden: Decodable {
    let goldenVersion: Int
    let fixture: String
    let segments: [Segment]
    let tracks: [Track]

    struct Segment: Decodable {
        let osmWayId: Int64
        let geometry: String
        /// `[lon, lat]` pairs as the pipeline decoded `geometry`.
        let coordinates: [[Double]]
        let analysis: Analysis
    }

    struct Track: Decodable {
        let name: String
        /// `[lon, lat]` pairs handed to the pipeline's scorer.
        let input: [[Double]]
        let analysis: Analysis
    }

    struct Analysis: Decodable {
        /// The line after the pipeline merged vertices closer than 5 m, as `[lon, lat]`.
        let merged: [[Double]]
        let lengthM: Double
        let score: Double
        let corners: [Corner]
    }

    struct Corner: Decodable {
        let ordinal: Int
        let apex: [Double]
        let minRadiusM: Double
        let direction: String
        let entryM: Double
        let apexM: Double
        let exitM: Double
    }

    static func load() throws -> DataGolden {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(DataGolden.self, from: Data(contentsOf: Fixtures.url("test/data-golden.json")))
    }
}
