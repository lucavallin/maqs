import Foundation
import MaqsTestSupport

/// The pipeline's reference values for the committed terrain fixture (`test/terrain-golden.json`).
struct Golden: Decodable {
    struct TileIDValue: Decodable { let z: Int; let x: Int; let y: Int; let id: UInt64 }
    struct TileDigest: Decodable { let z: Int; let x: Int; let y: Int; let sha256: String }
    struct Point: Decodable { let lon: Double; let lat: Double; let elevation: Double? }

    let goldenVersion: Int
    let archive: String
    let zoom: Int
    let tileIds: [TileIDValue]
    let tiles: [TileDigest]
    let points: [Point]

    static func load() throws -> Golden {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Golden.self, from: Data(contentsOf: Fixtures.url("test/terrain-golden.json")))
    }
}
