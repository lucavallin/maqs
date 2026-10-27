import CoreLocation
import Testing
@testable import MaqsData

@Suite struct CurvatureTests {
    private func line(_ pairs: [[Double]]) -> [CLLocationCoordinate2D] {
        pairs.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
    }

    private func expectMatches(_ analysis: CurvatureAnalysis, _ golden: DataGolden.Analysis, _ label: String) {
        #expect(analysis.merged.count == golden.merged.count, "\(label): merged count")
        for (mine, theirs) in zip(analysis.merged, golden.merged) {
            #expect(abs(mine.longitude - theirs[0]) <= 1e-12 && abs(mine.latitude - theirs[1]) <= 1e-12, "\(label): merged")
        }
        #expect(abs(analysis.length - golden.lengthM) <= 1e-6, "\(label): length")
        #expect(abs(analysis.score - golden.score) <= 1e-6, "\(label): score")
        #expect(analysis.corners.count == golden.corners.count, "\(label): corner count")
        for (mine, theirs) in zip(analysis.corners, golden.corners) {
            #expect(mine.ordinal == theirs.ordinal, "\(label): ordinal")
            #expect(mine.turn.rawValue == theirs.direction, "\(label): turn")
            #expect(abs(mine.minRadius - theirs.minRadiusM) <= 1e-6, "\(label): minRadius")
            #expect(abs(mine.entry - theirs.entryM) <= 1e-6, "\(label): entry")
            #expect(abs(mine.apexDistance - theirs.apexM) <= 1e-6, "\(label): apexDistance")
            #expect(abs(mine.exit - theirs.exitM) <= 1e-6, "\(label): exit")
            #expect(
                abs(mine.apex.longitude - theirs.apex[0]) <= 1e-12 && abs(mine.apex.latitude - theirs.apex[1]) <= 1e-12,
                "\(label): apex")
        }
    }

    @Test func everyFixtureSegmentRescoresLikeThePipeline() throws {
        let golden = try DataGolden.load()
        #expect(!golden.segments.isEmpty)
        for segment in golden.segments {
            let analysis = try Curvature.analyze(line(segment.coordinates))
            expectMatches(analysis, segment.analysis, "way \(segment.osmWayId)")
        }
    }

    @Test func everySyntheticTrackScoresLikeThePipeline() throws {
        let golden = try DataGolden.load()
        #expect(!golden.tracks.isEmpty)
        for track in golden.tracks {
            let analysis = try Curvature.analyze(line(track.input))
            expectMatches(analysis, track.analysis, track.name)
        }
    }

    @Test func anEmptyOnePointOrTwoPointInputScoresZeroWithNoCorners() throws {
        let inputs = [
            [],
            [CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25)],
            [CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25), CLLocationCoordinate2D(latitude: 46.1001, longitude: 12.2501)],
        ]
        for input in inputs {
            let analysis = try Curvature.analyze(input)
            #expect(analysis.score == 0)
            #expect(analysis.corners.isEmpty)
            #expect(analysis.merged.count == input.count)
        }
    }

    @Test func aNaNOrOutOfRangeCoordinateIsInvalidInput() {
        let good = CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25)
        let bad = [
            kCLLocationCoordinate2DInvalid,
            CLLocationCoordinate2D(latitude: .nan, longitude: 12),
            CLLocationCoordinate2D(latitude: 46, longitude: .infinity),
            CLLocationCoordinate2D(latitude: 91, longitude: 12),
            CLLocationCoordinate2D(latitude: 46, longitude: 181),
        ]
        for point in bad {
            #expect(throws: QueryError.self) { try Curvature.analyze([good, point, good]) }
            #expect(throws: QueryError.self) { try Curvature.analyze([point]) }
        }
    }
}
