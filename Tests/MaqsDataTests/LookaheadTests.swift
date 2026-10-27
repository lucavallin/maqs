import CoreLocation
import Foundation
import MaqsTestSupport
import Testing
@testable import MaqsData

@Suite struct LookaheadTests {
    private typealias Way = RoadNetwork.Way

    /// A stem (way 100) drawn north from node 1 to node 2 at the origin, where two branches leave: way 201 nearly
    /// straight on (about 6° to the left) and way 202 a sharper turn (about 31° to the right). No tags.
    private static func fork() -> RoadNetwork {
        RoadNetwork([
            Way(100, [(1, 0, -100), (2, 0, 0)]),
            Way(201, [(2, 0, 0), (3, -10, 100)]),
            Way(202, [(2, 0, 0), (4, 60, 100)]),
        ])
    }

    /// One way (100) with two corners: a right bend at about 102 m and a left bend at about 306 m.
    private static let sBend = Way(100, [(1, 0, 0), (5, 100, 20), (6, 200, 0), (7, 300, -20), (2, 400, 0)])

    private func roads(_ network: RoadNetwork, in directory: TemporaryDirectory) throws -> Roads {
        let url = directory.url.appending(path: "roads.sqlite")
        try network.write(to: url)
        return try Roads(files: [url])
    }

    private func lookahead(
        _ roads: Roads, on id: Int64, _ direction: TravelDirection, at along: Double, distance: Double = 1_000
    ) async throws -> Lookahead {
        let segment = try #require(await roads.segment(id))
        return try await roads.cornersAhead(from: RoadPosition(segment: segment, direction: direction, along: along),
                                            distance: distance)
    }

    private func length(of id: Int64, in roads: Roads) async throws -> Double {
        try #require(await roads.segment(id)).length
    }

    // MARK: Path and forks

    @Test("a way split continues with no fork")
    func waySplit() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([
            Way(100, [(1, 0, 0), (2, 0, 100)]),
            Way(200, [(2, 0, 100), (3, 0, 200)]),
        ]), in: directory)
        let first = try await length(of: 100, in: roads)
        let second = try await length(of: 200, in: roads)
        let result = try await lookahead(roads, on: 100, .forward, at: 0)
        #expect(result.path == [
            PathStep(segment: 100, direction: .forward, along: 0, distance: 0),
            PathStep(segment: 200, direction: .forward, along: 0, distance: first),
        ])
        #expect(result.forks.isEmpty)
        #expect(result.end == .noContinuation(at: first + second))
    }

    @Test("a Y split is decided by ref, compared trimmed, whitespace collapsed, case ignored and whole")
    func forkByRef() async throws {
        let directory = try TemporaryDirectory()
        var network = Self.fork()
        network.ways[0].ref = "SS 51"
        network.ways[1].ref = "SS51"
        network.ways[2].ref = " ss  51 "
        let roads = try roads(network, in: directory)
        let result = try await lookahead(roads, on: 100, .forward, at: 0)
        let stem = try await length(of: 100, in: roads)
        #expect(result.forks == [Fork(distance: stem, chosen: RoadBranch(segment: 202, direction: .forward),
                                      alternatives: [RoadBranch(segment: 201, direction: .forward)], reason: .sameRef)])
        #expect(result.path.map(\.segment) == [100, 202])
    }

    @Test("a Y split is decided by name when ref does not narrow it")
    func forkByName() async throws {
        let directory = try TemporaryDirectory()
        var network = Self.fork()
        for index in network.ways.indices { network.ways[index].ref = "SP1" }
        network.ways[0].name = "Via Roma"
        network.ways[1].name = "Via Verdi"
        network.ways[2].name = "Via Roma"
        let result = try await lookahead(roads(network, in: directory), on: 100, .forward, at: 0)
        #expect(result.forks.map(\.chosen) == [RoadBranch(segment: 202, direction: .forward)])
        #expect(result.forks.map(\.reason) == [.sameName])
    }

    @Test("a Y split is decided by highway")
    func forkByHighway() async throws {
        let directory = try TemporaryDirectory()
        var network = Self.fork()
        network.ways[0].highway = "primary"
        network.ways[2].highway = "primary"
        let result = try await lookahead(roads(network, in: directory), on: 100, .forward, at: 0)
        #expect(result.forks.map(\.chosen) == [RoadBranch(segment: 202, direction: .forward)])
        #expect(result.forks.map(\.reason) == [.sameHighway])
    }

    @Test("a Y split with nothing to tell the branches apart takes the smallest turn")
    func forkBySmallestTurn() async throws {
        let directory = try TemporaryDirectory()
        let result = try await lookahead(roads(Self.fork(), in: directory), on: 100, .forward, at: 0)
        #expect(result.forks.map(\.chosen) == [RoadBranch(segment: 201, direction: .forward)])
        #expect(result.forks.map(\.alternatives) == [[RoadBranch(segment: 202, direction: .forward)]])
        #expect(result.forks.map(\.reason) == [.smallestTurn])
    }

    @Test("a tie goes to the lower way id")
    func tie() async throws {
        let directory = try TemporaryDirectory()
        // Mirrored about the stem's meridian, so both turns are the same; the higher id is written first.
        let roads = try roads(RoadNetwork([
            Way(100, [(1, 0, -100), (2, 0, 0)]),
            Way(302, [(2, 0, 0), (3, -50, 100)]),
            Way(301, [(2, 0, 0), (4, 50, 100)]),
        ]), in: directory)
        let result = try await lookahead(roads, on: 100, .forward, at: 0)
        #expect(result.forks.map(\.chosen) == [RoadBranch(segment: 301, direction: .forward)])
        #expect(result.forks.map(\.alternatives) == [[RoadBranch(segment: 302, direction: .forward)]])
        #expect(result.forks.map(\.reason) == [.smallestTurn])
    }

    @Test("the carried ref crosses an unnamed link")
    func carriedRef() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([
            Way(100, [(1, 0, -100), (2, 0, 0)], ref: "SS1"),
            Way(150, [(2, 0, 0), (5, 0, 30)]),
            Way(201, [(5, 0, 30), (3, -10, 130)], ref: "SP2"),
            Way(202, [(5, 0, 30), (4, 60, 130)], ref: "SS1"),
        ]), in: directory)
        let result = try await lookahead(roads, on: 100, .forward, at: 0)
        let link = try await length(of: 100, in: roads) + length(of: 150, in: roads)
        #expect(result.path.map(\.segment) == [100, 150, 202])
        #expect(result.forks.map(\.distance) == [link])
        #expect(result.forks.map(\.reason) == [.sameRef])
    }

    @Test("a branch without the tag never matches, not even a path without it")
    func missingTagNeverMatches() async throws {
        let directory = try TemporaryDirectory()
        var network = Self.fork()
        // Were a missing tag equal to a missing tag, way 202 would win by ref or name.
        network.ways[1].ref = "SP2"
        network.ways[1].name = "Via Verdi"
        let result = try await lookahead(roads(network, in: directory), on: 100, .forward, at: 0)
        #expect(result.forks.map(\.chosen) == [RoadBranch(segment: 201, direction: .forward)])
        #expect(result.forks.map(\.reason) == [.smallestTurn])
    }

    // MARK: One-way

    @Test("a one-way branch entered against its direction is left out")
    func oneWayBranch() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([
            Way(100, [(1, 0, -100), (2, 0, 0)]),
            Way(201, [(3, -10, 100), (2, 0, 0)], oneway: 1),
            Way(202, [(2, 0, 0), (4, 60, 100)]),
            Way(203, [(2, 0, 0), (5, -60, 100)], oneway: -1),
        ]), in: directory)
        let result = try await lookahead(roads, on: 100, .forward, at: 0)
        #expect(result.forks.isEmpty)
        #expect(result.path.map(\.segment) == [100, 202])
    }

    @Test("the starting segment ignores its own one-way")
    func startAgainstOneWay() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([
            Way(100, [(1, 0, 0), (2, 0, 100)], oneway: 1),
            Way(99, [(0, 0, -100), (1, 0, 0)]),
        ]), in: directory)
        let before = try await length(of: 99, in: roads)
        let result = try await lookahead(roads, on: 100, .backward, at: 50)
        #expect(result.path == [
            PathStep(segment: 100, direction: .backward, along: 50, distance: 0),
            PathStep(segment: 99, direction: .backward, along: before, distance: 50),
        ])
        #expect(result.end == .noContinuation(at: 50 + before))
    }

    @Test("roundabouts and motorways without a oneway tag are one-way, circular junctions are not",
          arguments: [("secondary", "roundabout", true), ("motorway", nil, true), ("secondary", "circular", false)]
              as [(String, String?, Bool)])
    func impliedOneWay(highway: String, junction: String?, oneWay: Bool) async throws {
        let directory = try TemporaryDirectory()
        // Way 201 is drawn towards the fork, so leaving the fork along it is against its drawing direction.
        let roads = try roads(RoadNetwork([
            Way(100, [(1, 0, -100), (2, 0, 0)]),
            Way(201, [(3, -10, 100), (2, 0, 0)], highway: highway, junction: junction),
            Way(202, [(2, 0, 0), (4, 60, 100)]),
        ]), in: directory)
        let result = try await lookahead(roads, on: 100, .forward, at: 0)
        #expect(result.forks.isEmpty == oneWay)
        if oneWay {
            #expect(result.path.map(\.segment) == [100, 202])
        } else {
            #expect(result.forks.map(\.chosen) == [RoadBranch(segment: 201, direction: .backward)])
        }
    }

    // MARK: Ends and loops

    @Test("a dead end gives noContinuation at the node's distance")
    func deadEnd() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([Way(100, [(1, 0, 0), (2, 0, 100)])]), in: directory)
        let total = try await length(of: 100, in: roads)
        let result = try await lookahead(roads, on: 100, .forward, at: 30)
        #expect(result.end == .noContinuation(at: total - 30))
        #expect(result.path.count == 1)
    }

    @Test("a loop of three segments does not repeat")
    func loop() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([
            Way(101, [(1, 0, 0), (2, 100, 0)]),
            Way(102, [(2, 100, 0), (3, 50, 80)]),
            Way(103, [(3, 50, 80), (1, 0, 0)]),
        ]), in: directory)
        var total = 0.0
        for id: Int64 in [101, 102, 103] { total += try await length(of: id, in: roads) }
        let result = try await lookahead(roads, on: 101, .forward, at: 0, distance: 10_000)
        #expect(result.path.map(\.segment) == [101, 102, 103])
        #expect(result.forks.isEmpty)
        #expect(result.end == .noContinuation(at: total))
    }

    // MARK: Corners

    @Test("backward travel flips turns, distances and order")
    func backward() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([Self.sBend]), in: directory)
        let segment = try #require(await roads.segment(100))
        #expect(segment.corners.map(\.turn) == [.right, .left])
        let result = try await lookahead(roads, on: 100, .backward, at: segment.length)
        let length = segment.length
        #expect(result.corners == segment.corners.reversed().map { corner in
            UpcomingCorner(
                turn: corner.turn == .left ? .right : .left, minRadius: corner.minRadius,
                entry: length - corner.exit, apex: length - corner.apexDistance, exit: length - corner.entry,
                apexCoordinate: corner.apex, segment: 100, afterFork: false)
        })
        #expect(result.corners.map(\.turn) == [.right, .left])
    }

    @Test("a corner with its entry behind and its apex ahead is reported")
    func entryBehind() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([Self.sBend]), in: directory)
        let segment = try #require(await roads.segment(100))
        let result = try await lookahead(roads, on: 100, .forward, at: 50)
        let first = try #require(result.corners.first)
        #expect(first.entry == segment.corners[0].entry - 50)
        #expect(first.entry < 0)
        #expect(first.apex == segment.corners[0].apexDistance - 50)
        #expect(first.exit == segment.corners[0].exit - 50)
        #expect(result.corners.count == 2)
    }

    @Test("a corner with its apex behind is not reported")
    func apexBehind() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([Self.sBend]), in: directory)
        let segment = try #require(await roads.segment(100))
        let result = try await lookahead(roads, on: 100, .forward, at: 150)
        #expect(result.corners.map(\.apex) == [segment.corners[1].apexDistance - 150])
        #expect(result.corners.map(\.turn) == [.left])
    }

    @Test("corners past the distance are left out")
    func pastDistance() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([Self.sBend]), in: directory)
        let segment = try #require(await roads.segment(100))
        let result = try await lookahead(roads, on: 100, .forward, at: 0, distance: 200)
        #expect(result.corners.map(\.apex) == [segment.corners[0].apexDistance])
        #expect(result.end == .reachedDistance)
    }

    @Test("corners after a fork are afterFork, corners before it are not")
    func afterFork() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([
            Way(100, [(1, 0, -200), (5, 20, -100), (2, 0, 0)], ref: "SS1"),
            Way(201, [(2, 0, 0), (6, -20, 100), (3, 0, 200)], ref: "SS1"),
            Way(202, [(2, 0, 0), (4, 60, 100)]),
        ]), in: directory)
        let result = try await lookahead(roads, on: 100, .forward, at: 0)
        #expect(result.forks.count == 1)
        #expect(result.corners.map(\.segment) == [100, 201])
        #expect(result.corners.map(\.afterFork) == [false, true])
    }

    // MARK: Positions and files

    @Test("a continuation in a second file is followed")
    func secondFile() async throws {
        let directory = try TemporaryDirectory()
        let network = RoadNetwork([
            Way(100, [(1, 0, 0), (2, 0, 100)]),
            Way(200, [(2, 0, 100), (3, 0, 200)]),
        ])
        let first = directory.url.appending(path: "a.sqlite")
        let second = directory.url.appending(path: "b.sqlite")
        try network.write(to: first, only: [100], region: "a")
        try network.write(to: second, only: [200], region: "b")
        let roads = try Roads(files: [first, second])
        let result = try await lookahead(roads, on: 100, .forward, at: 0)
        #expect(result.path.map(\.segment) == [100, 200])
        #expect(result.forks.isEmpty)
    }

    @Test("along below 0 is clamped to 0, and along past the length to the length")
    func clamped() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([Way(100, [(1, 0, 0), (2, 0, 100)])]), in: directory)
        let total = try await length(of: 100, in: roads)
        #expect(try await lookahead(roads, on: 100, .forward, at: -5).path.first?.along == 0)
        #expect(try await lookahead(roads, on: 100, .forward, at: -5).end == .noContinuation(at: total))
        #expect(try await lookahead(roads, on: 100, .backward, at: total + 5).path.first?.along == total)
        #expect(try await lookahead(roads, on: 100, .backward, at: total + 5).end == .noContinuation(at: total))
    }

    @Test("an out-of-range distance or a non-finite along is invalidInput before any file is read",
          arguments: [
              (0.0, 0.0, "distance"), (10_001.0, 0.0, "distance"), (.nan, 0.0, "distance"), (-1.0, 0.0, "distance"),
              (1_000.0, .nan, "along"), (1_000.0, .infinity, "along"),
          ] as [(Double, Double, String)])
    func invalidInput(distance: Double, along: Double, name: String) async throws {
        let directory = try TemporaryDirectory()
        let segment = try #require(await roads(Self.fork(), in: directory).segment(100))
        // No files: a check made after the lookup would throw unknownSegment instead.
        let empty = try Roads(files: [])
        let expected = name == "distance"
            ? "distance must be above 0 and at most 10000 metres" : "along must be a finite number"
        await #expect(throws: QueryError.invalidInput(expected)) {
            try await empty.cornersAhead(from: RoadPosition(segment: segment, direction: .forward, along: along),
                                         distance: distance)
        }
    }

    @Test("the edges of the distance are accepted")
    func distanceEdges() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(Self.fork(), in: directory)
        #expect(try await lookahead(roads, on: 100, .forward, at: 0, distance: 10_000).path.count == 2)
        #expect(try await lookahead(roads, on: 100, .forward, at: 0, distance: 1e-9).end == .reachedDistance)
    }

    @Test("a segment in none of the open files is unknownSegment")
    func unknownSegment() async throws {
        let directory = try TemporaryDirectory()
        let other = directory.url.appending(path: "other.sqlite")
        try RoadNetwork([Way(999, [(1, 0, 0), (2, 0, 100)])]).write(to: other, region: "other")
        let segment = try #require(await Roads(files: [other]).segment(999))
        let roads = try roads(Self.fork(), in: directory)
        await #expect(throws: QueryError.unknownSegment(999)) {
            try await roads.cornersAhead(from: RoadPosition(segment: segment, direction: .forward, along: 0))
        }
    }

    @Test("with no files cornersAhead throws unknownSegment")
    func noFiles() async throws {
        let directory = try TemporaryDirectory()
        let segment = try #require(await roads(Self.fork(), in: directory).segment(100))
        let empty = try Roads(files: [])
        await #expect(throws: QueryError.unknownSegment(100)) {
            try await empty.cornersAhead(from: RoadPosition(segment: segment, direction: .forward, along: 0))
        }
    }

    // MARK: Review focus 5

    @Test("a rider at the very end continues onto the next segment, counting from 0 at the node")
    func atTheEnd() async throws {
        let directory = try TemporaryDirectory()
        let roads = try roads(RoadNetwork([
            Way(100, [(1, 0, 0), (2, 100, 0)]),
            Way(200, [(2, 100, 0), (5, 200, 20), (3, 300, 0)]),
        ]), in: directory)
        let first = try await length(of: 100, in: roads)
        let next = try #require(await roads.segment(200))
        let corner = try #require(next.corners.first)
        let result = try await lookahead(roads, on: 100, .forward, at: first)
        #expect(result.path == [
            PathStep(segment: 100, direction: .forward, along: first, distance: 0),
            PathStep(segment: 200, direction: .forward, along: 0, distance: 0),
        ])
        #expect(result.corners == [UpcomingCorner(
            turn: corner.turn, minRadius: corner.minRadius, entry: corner.entry, apex: corner.apexDistance,
            exit: corner.exit, apexCoordinate: corner.apex, segment: 200, afterFork: false)])
        #expect(result.end == .noContinuation(at: next.length))
        #expect(try await lookahead(roads, on: 100, .forward, at: first + 50).corners == result.corners)
        // The same at the first vertex, travelling backward.
        let back = try await lookahead(roads, on: 200, .backward, at: 0)
        #expect(back.path == [
            PathStep(segment: 200, direction: .backward, along: 0, distance: 0),
            PathStep(segment: 100, direction: .backward, along: first, distance: 0),
        ])
        #expect(back.end == .noContinuation(at: first))
    }

    // MARK: Review focus 2

    @Test("the network written into two files gives the same lookahead as one file, with no forks")
    func twoFiles() async throws {
        let directory = try TemporaryDirectory()
        let network = RoadNetwork([
            Self.sBend,
            Way(200, [(2, 400, 0), (8, 500, 20), (9, 600, 0)]),
            Way(300, [(9, 600, 0), (10, 700, -20), (11, 800, 0)]),
        ])
        let one = directory.url.appending(path: "one.sqlite")
        let first = directory.url.appending(path: "a.sqlite")
        let second = directory.url.appending(path: "b.sqlite")
        try network.write(to: one)
        try network.write(to: first, region: "a")
        try network.write(to: second, region: "b")
        let single = try await lookahead(Roads(files: [one]), on: 100, .forward, at: 0, distance: 2_000)
        let both = try await lookahead(Roads(files: [first, second]), on: 100, .forward, at: 0, distance: 2_000)
        #expect(both == single)
        #expect(both.forks.isEmpty)
        #expect(both.path.map(\.segment) == [100, 200, 300])
        #expect(both.corners.count == 4)
    }

    // MARK: Fixture

    @Test("on the fixture, the corners ahead of a segment from its start are its corners rows")
    func fixtureCorners() async throws {
        let roads = try Roads(files: [Fixtures.url("test/test-curvature.v1.sqlite")])
        var checked = 0
        for entry in try DataGolden.load().segments {
            let segment = try #require(await roads.segment(entry.osmWayId))
            guard segment.length > 0, segment.length <= 10_000 else { continue }
            let position = RoadPosition(segment: segment, direction: .forward, along: 0)
            let result = try await roads.cornersAhead(from: position, distance: segment.length)
            #expect(result.corners == segment.corners.map { corner in
                UpcomingCorner(
                    turn: corner.turn, minRadius: corner.minRadius, entry: corner.entry, apex: corner.apexDistance,
                    exit: corner.exit, apexCoordinate: corner.apex, segment: segment.id, afterFork: false)
            }, "way \(segment.id)")
            #expect(result.end == .reachedDistance, "way \(segment.id)")
            if !segment.corners.isEmpty { checked += 1 }
        }
        #expect(checked > 50)
    }

    // MARK: Test support

    @Test("the network's derived junctions follow the pipeline's rule")
    func derivedJunctions() throws {
        // A T-junction: the stem (200) ends at node 3 inside the through way (100). The merge drops node 3's vertex,
        // 2 m after node 6; nodes 2 and 6 are shared with nothing, and the stem has no interior node.
        let network = RoadNetwork([
            Way(100, [(1, 0, 0), (2, 50, 0), (6, 98, 0), (3, 100, 0), (4, 200, 0)]),
            Way(200, [(3, 100, 0), (5, 100, 100)]),
        ])
        let analyses = try network.ways.map { way in
            try Curvature.analyze(way.nodes.map { RoadNetwork.coordinate(x: $0.x, y: $0.y) })
        }
        #expect(analyses[0].merged.count == 4)
        let rows = RoadNetwork.junctionRows(network.ways, analyses)
        #expect(rows.count == 1)
        #expect(rows.first?.segmentID == 1)
        #expect(rows.first?.node == 3)
        let along = try #require(rows.first?.along)
        #expect(abs(along - 100) < 0.2)
    }
}
