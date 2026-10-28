import MaqsPMTiles
import Testing
@testable import MaqsTerrain

@Suite struct PMTilesErrorTests {
    @Test func eachReadErrorMapsToThePublicCaseOfTheSameName() {
        let pairs: [(PMTilesReadError, PMTilesError)] = [
            (.notPMTiles, .notPMTiles),
            (.unsupportedVersion(4), .unsupportedVersion(4)),
            (.unsupportedCompression(3), .unsupportedCompression(3)),
            (.truncated, .truncated),
            (.corruptDirectory("count"), .corruptDirectory("count")),
            (.corruptCompressedData("crc"), .corruptCompressedData("crc")),
            (.sectionTooLarge, .sectionTooLarge),
            (.nestedLeafDirectory, .nestedLeafDirectory),
            (.unreadableFile, .unreadableFile),
        ]
        for (readError, expected) in pairs {
            #expect(PMTilesError(readError) == expected)
        }
    }
}
