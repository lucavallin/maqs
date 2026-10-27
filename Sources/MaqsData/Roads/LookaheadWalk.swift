import CoreLocation

/// The walk behind ``Roads/cornersAhead(from:distance:)``: along the road from a position, from junction point to
/// junction point, taking the likeliest branch where several lead on and collecting the corners on the way.
///
/// A junction point is a place on a segment where other roads can meet it, with the OSM nodes there: the segment's
/// two ends and, in a file with the `junctions` table, each place inside it where it passes a node another segment
/// also has. A stretch is the piece of a segment between two neighbouring junction points. The walk travels whole
/// stretches (the first one from the position) and records each, so it never travels a stretch twice and every walk
/// ends. Because it records stretches rather than segments, it walks a ring round across its closing node and
/// follows a road that leaves a way back onto the rest of that way.
///
/// Not `Sendable`: it reads the reader actor's files and lives for one call on that actor.
struct LookaheadWalk {
    /// How far before and after a junction the turn onto a branch is measured, in metres.
    private static let turnReach = 20.0
    /// Half the side of the R*Tree box searched around a node, in degrees: it covers the polyline's 1e-6° rounding and
    /// the R*Tree's float32 rounding.
    private static let nodeBox = 1e-5
    /// How far a node met mid-way can lie from its junction row's point, in metres. The row places the node on the
    /// stored line, from which the 5 m vertex merge may have dropped the node's own vertex: a dropped vertex lies
    /// within 5 m of a kept one, or within 10 m near the way's last vertex, where the merge also runs backward. The
    /// box searched for segments ending at such a node is widened by this much.
    private static let rowSlack = 10.0
    /// Turns closer than this, in degrees, are a tie: mirrored branches differ only by floating-point rounding.
    private static let turnTie = 1e-6
    /// The fork rule's tags, in the order they narrow the branches.
    private static let rules: [(reason: Fork.Reason, tag: @Sendable (RoadSegment) -> String?)] = [
        (.sameRef, { $0.ref }), (.sameName, { $0.name }), (.sameHighway, { $0.highway }),
    ]

    /// A place on a segment where other roads can meet it.
    private struct JunctionPoint {
        /// The OSM nodes there: usually one, more where junction rows share a distance or fall on an end.
        var nodes: [Int64]
        /// Metres from the segment's first vertex.
        let along: Double
        let coordinate: CLLocationCoordinate2D
        /// Metres the nodes can lie from `coordinate`: 0 at an end vertex, ``rowSlack`` once a junction row is here.
        var slack: Double

        mutating func add(_ node: Int64) {
            if !nodes.contains(node) { nodes.append(node) }
            slack = LookaheadWalk.rowSlack
        }
    }

    /// A piece of a segment between two neighbouring junction points, in drawing-direction metres, `from <= to`.
    private struct Stretch {
        let from: Double
        let to: Double
    }

    /// A way along a segment: entered `along` metres from its first vertex and travelled in `direction`.
    private struct Entry {
        let stored: Roads.StoredSegment
        /// The segment's junction points by distance along it, at least two: its start first, its end last.
        let points: [JunctionPoint]
        let direction: TravelDirection
        let along: Double

        var segment: RoadSegment { stored.segment }
        var branch: RoadBranch { RoadBranch(segment: segment.id, direction: direction) }
        var key: BranchKey { BranchKey(segment.id, direction, along) }
    }

    /// A branch's identity: its way, its direction and where it is entered, to the metre. The same way in two files
    /// is one branch, while a way that passes a node twice offers a branch for each pass.
    private struct BranchKey: Hashable {
        let way: RoadSegment.ID
        let direction: TravelDirection
        let metre: Double

        init(_ way: RoadSegment.ID, _ direction: TravelDirection, _ along: Double) {
            self.way = way
            self.direction = direction
            self.metre = along.rounded()
        }
    }

    /// Where the path's current step starts. Distances on its segment count from here, so going straight on past a
    /// junction met mid-way adds no rounding.
    private struct StepStart {
        /// Metres from the segment's first vertex.
        let along: Double
        /// Metres ahead of the position.
        let distance: Double

        /// How far ahead of the position the point `to` metres along the segment lies, travelling in `direction`.
        func ahead(_ to: Double, _ direction: TravelDirection) -> Double {
            distance + (direction == .forward ? to - along : along - to)
        }
    }

    private struct CornerKey: Hashable {
        let segment: RoadSegment.ID
        let ordinal: Int
    }

    private let files: [LayerFile]
    private let distance: Double
    /// The stretches travelled, by way id.
    private var covered: [RoadSegment.ID: [Stretch]] = [:]
    private var reported: Set<CornerKey> = []
    /// The path's last non-empty value of each rule's tag, normalised.
    private var carried: [Fork.Reason: String] = [:]
    private var corners: [UpcomingCorner] = []
    private var path: [PathStep] = []
    private var forks: [Fork] = []

    init(files: [LayerFile], distance: Double) {
        self.files = files
        self.distance = distance
    }

    /// Walks from `along` metres on `start` in `direction`, which may run against the segment's one-way: the walk
    /// keeps to it straight on, past junctions met mid-way, until it leaves the segment.
    mutating func run(from start: Roads.StoredSegment, direction: TravelDirection, along: Double) throws(QueryError)
        -> Lookahead {
        var entry = Entry(stored: start, points: try junctionPoints(of: start), direction: direction,
                          along: Self.clamped(along, to: start.segment.length))
        var entryDistance = 0.0
        var step = StepStart(along: entry.along, distance: 0)
        var entering = true
        var onStart = true
        while true {
            let (point, stretch) = Self.next(entry)
            if entering {
                step = StepStart(along: entry.along, distance: entryDistance)
                path.append(PathStep(
                    segment: entry.segment.id, direction: entry.direction, along: step.along, distance: step.distance))
            }
            let nodeDistance = step.ahead(point.along, entry.direction)
            covered[entry.segment.id, default: []].append(stretch)
            carry(entry.segment)
            collectCorners(on: entry, from: entryDistance, to: nodeDistance, measuredFrom: step)
            if nodeDistance >= distance { return finish(.reachedDistance) }

            let straightOn = BranchKey(entry.segment.id, entry.direction, point.along)
            let open = try branches(at: point).filter { isOpen($0, exempt: onStart && $0.key == straightOn) }
            guard var chosen = open.first else { return finish(.noContinuation(at: nodeDistance)) }
            if open.count > 1 {
                let (choice, reason) = choose(among: open, arrivingOn: entry, over: stretch)
                chosen = choice
                forks.append(Fork(
                    distance: nodeDistance, chosen: choice.branch,
                    alternatives: open.filter { $0.key != choice.key }.map(\.branch), reason: reason))
            }
            // Straight on along the same segment continues its step.
            entering = chosen.key != straightOn
            onStart = onStart && !entering
            entry = chosen
            entryDistance = nodeDistance
        }
    }

    private func finish(_ end: Lookahead.End) -> Lookahead {
        Lookahead(corners: corners, path: path, forks: forks, end: end)
    }

    // MARK: Junction points

    /// The points of `stored` where other roads can meet it, by distance along it: its start, then, in a file with
    /// the `junctions` table, its rows (`junctions_segment`), then its end. Rows at one distance share a point, and
    /// rows at a distance of 0 or the length join the start or the end.
    ///
    /// - Throws: ``QueryError/corruptData(file:detail:)`` for a length that is negative or not finite, or a row
    ///   distance that is not finite, which would leave the walk without stretches to record.
    private func junctionPoints(of stored: Roads.StoredSegment) throws(QueryError) -> [JunctionPoint] {
        let segment = stored.segment
        guard segment.length.isFinite, segment.length >= 0 else {
            throw .corruptData(file: stored.file.fileName, detail: "segment \(stored.rowID) has no valid length")
        }
        // An empty geometry, which the pipeline never writes, finds no branch at its ends.
        var start = JunctionPoint(nodes: [segment.startNode], along: 0,
                                  coordinate: segment.geometry.first ?? kCLLocationCoordinate2DInvalid, slack: 0)
        var end = JunctionPoint(nodes: [segment.endNode], along: segment.length,
                                coordinate: segment.geometry.last ?? kCLLocationCoordinate2DInvalid, slack: 0)
        var inside: [JunctionPoint] = []
        if stored.file.hasJunctions {
            let statement = try stored.file.connection.prepare(
                "SELECT node, along_m FROM junctions WHERE segment_id = ?1 ORDER BY along_m, node")
            defer { statement.reset() }
            try statement.bind(stored.rowID, at: 1)
            while try statement.step() {
                let node = statement.int64(at: 0)
                let along = try Self.rowAlong(
                    statement.double(at: 1), length: segment.length, row: stored.rowID, in: stored.file)
                if along == 0 {
                    start.add(node)
                } else if along == segment.length {
                    end.add(node)
                } else if inside.last?.along == along {
                    inside[inside.count - 1].add(node)
                } else {
                    inside.append(JunctionPoint(nodes: [node], along: along,
                                                coordinate: Geodesy.point(on: segment.geometry, at: along),
                                                slack: Self.rowSlack))
                }
            }
        }
        return [start] + inside + [end]
    }

    /// A junction row's `along_m` on segment row `rowID` of `file`, clamped to its `length`: the pipeline measures it
    /// on the stored line, so rounding can put it a hair past an end.
    ///
    /// - Throws: ``QueryError/corruptData(file:detail:)`` for a distance that is not finite.
    private static func rowAlong(_ along: Double, length: Double, row rowID: Int64, in file: LayerFile)
        throws(QueryError) -> Double {
        guard along.isFinite else {
            throw .corruptData(file: file.fileName, detail: "a junction of segment \(rowID) has no valid distance")
        }
        return clamped(along, to: length)
    }

    private static func clamped(_ along: Double, to length: Double) -> Double {
        min(max(along, 0), length)
    }

    /// The junction point `entry` reaches next and the stretch that leads to it.
    ///
    /// The segment's far end counts even at distance 0, so a rider at the very end continues from its node; a point
    /// inside the segment must lie strictly ahead. The first stretch from a position is the whole stretch around it,
    /// so the walk never turns back onto the rider's own stretch.
    private static func next(_ entry: Entry) -> (point: JunctionPoint, stretch: Stretch) {
        let points = entry.points
        switch entry.direction {
        case .forward:
            let index = points.indices.dropFirst().first { points[$0].along > entry.along } ?? points.count - 1
            return (points[index], Stretch(from: points[index - 1].along, to: points[index].along))
        case .backward:
            let index = points.indices.dropLast().last { points[$0].along < entry.along } ?? 0
            return (points[index], Stretch(from: points[index].along, to: points[index + 1].along))
        }
    }

    // MARK: Branches

    /// Every way on from `point`, from every open file and for each of its nodes: the segments that start or end at
    /// the node, found through `segments_rtree` around the point and travelled away from it, and, in a file with the
    /// `junctions` table, the segments that pass through it (`junctions_node`), each travelled both ways from there.
    /// The segment the walk is on is one of the latter, so going straight on is a branch.
    ///
    /// A branch found in several files (``BranchKey``) comes from the first. The order is by way id, `forward` first,
    /// then by where the branch is entered, the order ties are broken in.
    private func branches(at point: JunctionPoint) throws(QueryError) -> [Entry] {
        var found: [Entry] = []
        var seen: Set<BranchKey> = []
        func add(_ row: Roads.Row, _ ways: [(direction: TravelDirection, along: Double)], in file: LayerFile)
            throws(QueryError) {
            let new = ways.filter { seen.insert(BranchKey(row.wayID, $0.direction, $0.along)).inserted }
            guard !new.isEmpty else { return }
            let stored = try Roads.stored(row, in: file)
            let points = try junctionPoints(of: stored)
            found += new.map { Entry(stored: stored, points: points, direction: $0.direction, along: $0.along) }
        }

        let latitudeBox = Self.nodeBox + point.slack / Geodesy.metresPerDegreeLatitude
        // Longitude degrees shrink towards the poles; the floor keeps the box finite there.
        let cosine = max(cos(point.coordinate.latitude * .pi / 180), 0.01)
        let longitudeBox = Self.nodeBox + point.slack / (Geodesy.metresPerDegreeLongitudeAtEquator * cosine)
        for file in files {
            for node in point.nodes {
                let ends = try file.connection.prepare("\(Roads.select(file)) JOIN segments_rtree r ON r.id = s.id "
                    + "WHERE r.min_lon <= ?1 AND r.max_lon >= ?2 AND r.min_lat <= ?3 AND r.max_lat >= ?4 "
                    + "AND (s.start_node = ?5 OR s.end_node = ?5) ORDER BY s.id")
                defer { ends.reset() }
                try ends.bind(point.coordinate.longitude + longitudeBox, at: 1)
                try ends.bind(point.coordinate.longitude - longitudeBox, at: 2)
                try ends.bind(point.coordinate.latitude + latitudeBox, at: 3)
                try ends.bind(point.coordinate.latitude - latitudeBox, at: 4)
                try ends.bind(node, at: 5)
                while try ends.step() {
                    let row = Roads.row(ends)
                    var ways: [(direction: TravelDirection, along: Double)] = []
                    if row.startNode == node { ways.append((.forward, 0)) }
                    if row.endNode == node { ways.append((.backward, row.length)) }
                    try add(row, ways, in: file)
                }

                guard file.hasJunctions else { continue }
                let through = try file.connection.prepare("\(Roads.select(file, adding: "j.along_m")) "
                    + "JOIN junctions j ON j.segment_id = s.id WHERE j.node = ?1 ORDER BY s.id, j.along_m")
                defer { through.reset() }
                try through.bind(node, at: 1)
                while try through.step() {
                    let row = Roads.row(through)
                    let along = try Self.rowAlong(through.double(at: 14), length: row.length, row: row.rowID, in: file)
                    try add(row, [(.forward, along), (.backward, along)], in: file)
                }
            }
        }
        return found.sorted { a, b in
            if a.segment.id != b.segment.id { return a.segment.id < b.segment.id }
            if a.direction != b.direction { return a.direction == .forward }
            return a.along < b.along
        }
    }

    /// Whether the walk may take `branch`: not against its effective one-way, unless `exempt`, and its first stretch
    /// not yet on the path (judged by the stretch's middle, so a stretch is never travelled twice).
    private func isOpen(_ branch: Entry, exempt: Bool) -> Bool {
        if !exempt {
            switch (branch.direction, branch.segment.oneway) {
            case (.forward, .backward), (.backward, .forward): return false
            default: break
            }
        }
        let stretch = Self.next(branch).stretch
        let middle = (stretch.from + stretch.to) / 2
        return !(covered[branch.segment.id] ?? []).contains { $0.from <= middle && middle <= $0.to }
    }

    // MARK: The fork rule

    /// The likeliest of `branches` and the last rule that narrowed them.
    ///
    /// Each rule keeps the branches whose tag equals the path's last one, when at least one does; then the smallest
    /// turn decides, ties going to the earlier branch (lower way id, then `forward`).
    private func choose(among branches: [Entry], arrivingOn entry: Entry, over stretch: Stretch)
        -> (Entry, Fork.Reason) {
        var remaining = branches
        var reason = Fork.Reason.smallestTurn
        for (rule, tag) in Self.rules {
            guard let wanted = carried[rule] else { continue }
            let matching = remaining.filter { Self.normalised(tag($0.segment)) == wanted }
            if !matching.isEmpty, matching.count < remaining.count {
                remaining = matching
                reason = rule
            }
        }
        let node = entry.direction == .forward ? stretch.to : stretch.from
        let back = Self.moved(node, by: Self.turnReach, entry.direction == .forward ? .backward : .forward, within: stretch)
        let incoming = Self.bearing(on: entry.segment, from: back, to: node)
        var best = remaining[0]
        var bestTurn = Double.infinity
        for branch in remaining {
            let far = Self.moved(branch.along, by: Self.turnReach, branch.direction, within: Self.next(branch).stretch)
            let outgoing = Self.bearing(on: branch.segment, from: branch.along, to: far)
            let difference = abs(outgoing - incoming).truncatingRemainder(dividingBy: 360)
            let turn = difference > 180 ? 360 - difference : difference
            if turn < bestTurn - Self.turnTie {
                best = branch
                bestTurn = turn
            }
        }
        return (best, reason)
    }

    /// Keeps the segment's tags that are set as the path's last ones.
    private mutating func carry(_ segment: RoadSegment) {
        for (rule, tag) in Self.rules {
            if let value = Self.normalised(tag(segment)) { carried[rule] = value }
        }
    }

    /// `text` trimmed, its runs of whitespace collapsed to one space and lowercased; nil when nothing is left.
    private static func normalised(_ text: String?) -> String? {
        guard let words = text?.split(whereSeparator: \.isWhitespace), !words.isEmpty else { return nil }
        return words.joined(separator: " ").lowercased()
    }

    /// `along` moved `metres` in `direction`, kept inside `stretch`.
    private static func moved(
        _ along: Double, by metres: Double, _ direction: TravelDirection, within stretch: Stretch
    ) -> Double {
        direction == .forward ? min(stretch.to, along + metres) : max(stretch.from, along - metres)
    }

    /// The bearing from the point `from` metres along `segment` to the point `to` metres along it.
    private static func bearing(on segment: RoadSegment, from: Double, to: Double) -> Double {
        Geodesy.initialBearing(
            from: Geodesy.point(on: segment.geometry, at: from), to: Geodesy.point(on: segment.geometry, at: to))
    }

    // MARK: Corners

    /// Reports the corners of `entry`'s segment whose apex lies on the stretch travelled, from `start` to `end` metres
    /// ahead of the position, and within the walk's distance. Distances count from `step`; they, the turns and the
    /// order follow the direction of travel.
    private mutating func collectCorners(
        on entry: Entry, from start: Double, to end: Double, measuredFrom step: StepStart
    ) {
        let forward = entry.direction == .forward
        func ahead(_ along: Double) -> Double { step.ahead(along, entry.direction) }
        let ordered: [Corner] = forward ? entry.segment.corners : entry.segment.corners.reversed()
        for corner in ordered {
            let apex = ahead(corner.apexDistance)
            guard apex >= start, apex <= end, apex <= distance,
                  reported.insert(CornerKey(segment: entry.segment.id, ordinal: corner.ordinal)).inserted
            else { continue }
            corners.append(UpcomingCorner(
                turn: forward ? corner.turn : (corner.turn == .left ? .right : .left), minRadius: corner.minRadius,
                entry: ahead(forward ? corner.entry : corner.exit), apex: apex,
                exit: ahead(forward ? corner.exit : corner.entry), apexCoordinate: corner.apex,
                segment: entry.segment.id, afterFork: !forks.isEmpty))
        }
    }
}
