import CoreLocation

/// The walk behind ``Roads/cornersAhead(from:distance:)``: along the road from a position, from junction point to
/// junction point, taking the likeliest branch where several lead on and collecting the corners on the way.
///
/// A junction point is a place on a segment where other roads can meet it, with the OSM node there. A stretch is the
/// piece of a segment between two neighbouring junction points. The walk travels whole stretches (the first one
/// from the position) and records each, so it never travels a stretch twice and every walk ends.
///
/// Not `Sendable`: it reads the reader actor's files and lives for one call on that actor.
struct LookaheadWalk {
    /// How far before and after a junction the turn onto a branch is measured, in metres.
    private static let turnReach = 20.0
    /// Half the side of the R*Tree box searched around a node, in degrees: it covers the polyline's 1e-6° rounding and
    /// the R*Tree's float32 rounding.
    private static let nodeBox = 1e-5
    /// Turns closer than this, in degrees, are a tie: mirrored branches differ only by floating-point rounding.
    private static let turnTie = 1e-6
    /// The fork rule's tags, in the order they narrow the branches.
    private static let rules: [(reason: Fork.Reason, tag: @Sendable (RoadSegment) -> String?)] = [
        (.sameRef, { $0.ref }), (.sameName, { $0.name }), (.sameHighway, { $0.highway }),
    ]

    /// A place on a segment where other roads can meet it.
    private struct JunctionPoint {
        let node: Int64
        /// Metres from the segment's first vertex.
        let along: Double
        let coordinate: CLLocationCoordinate2D
    }

    /// A piece of a segment between two neighbouring junction points, in drawing-direction metres, `from <= to`.
    private struct Stretch {
        let from: Double
        let to: Double
    }

    /// A way along a segment: entered `along` metres from its first vertex and travelled in `direction`.
    private struct Entry {
        let stored: Roads.StoredSegment
        let direction: TravelDirection
        let along: Double

        var segment: RoadSegment { stored.segment }
        var branch: RoadBranch { RoadBranch(segment: segment.id, direction: direction) }
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

    /// Walks from `along` metres on `start` in `direction`, which may run against the segment's one-way.
    mutating func run(from start: Roads.StoredSegment, direction: TravelDirection, along: Double) throws(QueryError)
        -> Lookahead {
        var entry = Entry(stored: start, direction: direction, along: min(max(along, 0), start.segment.length))
        var entryDistance = 0.0
        while true {
            let (point, stretch) = try next(entry)
            let nodeDistance = entryDistance + abs(point.along - entry.along)
            path.append(PathStep(
                segment: entry.segment.id, direction: entry.direction, along: entry.along, distance: entryDistance))
            covered[entry.segment.id, default: []].append(stretch)
            carry(entry.segment)
            collectCorners(on: entry, from: entryDistance, to: nodeDistance)
            if nodeDistance >= distance { return finish(.reachedDistance) }

            var open: [Entry] = []
            for branch in try branches(at: point) {
                if try isOpen(branch) { open.append(branch) }
            }
            guard var chosen = open.first else { return finish(.noContinuation(at: nodeDistance)) }
            if open.count > 1 {
                let (choice, reason) = try choose(among: open, arrivingOn: entry, over: stretch)
                chosen = choice
                forks.append(Fork(
                    distance: nodeDistance, chosen: choice.branch,
                    alternatives: open.map(\.branch).filter { $0 != choice.branch }, reason: reason))
            }
            entry = chosen
            entryDistance = nodeDistance
        }
    }

    private func finish(_ end: Lookahead.End) -> Lookahead {
        Lookahead(corners: corners, path: path, forks: forks, end: end)
    }

    // MARK: Junction points

    /// The points of `stored` where other roads can meet it, by distance along it: its two ends, first and last.
    ///
    /// - Throws: ``QueryError/corruptData(file:detail:)`` for a length that is negative or not finite, which would
    ///   leave the walk without stretches to record.
    private func junctionPoints(of stored: Roads.StoredSegment) throws(QueryError) -> [JunctionPoint] {
        let segment = stored.segment
        guard segment.length.isFinite, segment.length >= 0 else {
            throw .corruptData(file: stored.file.fileName, detail: "segment \(stored.rowID) has no valid length")
        }
        // An empty geometry, which the pipeline never writes, finds no branch at its ends.
        return [
            JunctionPoint(node: segment.startNode, along: 0,
                          coordinate: segment.geometry.first ?? kCLLocationCoordinate2DInvalid),
            JunctionPoint(node: segment.endNode, along: segment.length,
                          coordinate: segment.geometry.last ?? kCLLocationCoordinate2DInvalid),
        ]
    }

    /// The junction point `entry` reaches next and the stretch that leads to it.
    ///
    /// The segment's far end counts even at distance 0, so a rider at the very end continues from its node; a point
    /// inside the segment must lie strictly ahead.
    private func next(_ entry: Entry) throws(QueryError) -> (point: JunctionPoint, stretch: Stretch) {
        let points = try junctionPoints(of: entry.stored)
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

    /// Every way on from `point`: the segments of every open file that start or end at its node, found through
    /// `segments_rtree` around its coordinate, each travelled away from the node.
    ///
    /// A way and direction found in several files comes from the first. The order is by way id, `forward` first,
    /// the order ties are broken in.
    private func branches(at point: JunctionPoint) throws(QueryError) -> [Entry] {
        var found: [Entry] = []
        var seen: Set<RoadBranch> = []
        for file in files {
            let statement = try file.connection.prepare("\(Roads.select(file)) JOIN segments_rtree r ON r.id = s.id "
                + "WHERE r.min_lon <= ?1 AND r.max_lon >= ?2 AND r.min_lat <= ?3 AND r.max_lat >= ?4 "
                + "AND (s.start_node = ?5 OR s.end_node = ?5) ORDER BY s.id")
            defer { statement.reset() }
            try statement.bind(point.coordinate.longitude + Self.nodeBox, at: 1)
            try statement.bind(point.coordinate.longitude - Self.nodeBox, at: 2)
            try statement.bind(point.coordinate.latitude + Self.nodeBox, at: 3)
            try statement.bind(point.coordinate.latitude - Self.nodeBox, at: 4)
            try statement.bind(point.node, at: 5)
            while try statement.step() {
                let row = Roads.row(statement)
                var ways: [(direction: TravelDirection, along: Double)] = []
                if row.startNode == point.node { ways.append((.forward, 0)) }
                if row.endNode == point.node { ways.append((.backward, row.length)) }
                ways = ways.filter { seen.insert(RoadBranch(segment: row.wayID, direction: $0.direction)).inserted }
                guard !ways.isEmpty else { continue }
                let stored = try Roads.stored(row, in: file)
                found += ways.map { Entry(stored: stored, direction: $0.direction, along: $0.along) }
            }
        }
        return found.sorted { a, b in
            a.segment.id != b.segment.id ? a.segment.id < b.segment.id : a.direction == .forward && b.direction == .backward
        }
    }

    /// Whether the walk may take `branch`: not against its effective one-way, and its first stretch not yet on the
    /// path (judged by the stretch's middle, so a stretch is never travelled twice).
    private func isOpen(_ branch: Entry) throws(QueryError) -> Bool {
        switch (branch.direction, branch.segment.oneway) {
        case (.forward, .backward), (.backward, .forward): return false
        default: break
        }
        let stretch = try next(branch).stretch
        let middle = (stretch.from + stretch.to) / 2
        return !(covered[branch.segment.id] ?? []).contains { $0.from <= middle && middle <= $0.to }
    }

    // MARK: The fork rule

    /// The likeliest of `branches` and the last rule that narrowed them.
    ///
    /// Each rule keeps the branches whose tag equals the path's last one, when at least one does; then the smallest
    /// turn decides, ties going to the earlier branch (lower way id, then `forward`).
    private func choose(among branches: [Entry], arrivingOn entry: Entry, over stretch: Stretch) throws(QueryError)
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
            let far = Self.moved(branch.along, by: Self.turnReach, branch.direction, within: try next(branch).stretch)
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
    /// ahead of the position, and within the walk's distance. Distances, turns and order follow the direction of travel.
    private mutating func collectCorners(on entry: Entry, from start: Double, to end: Double) {
        let forward = entry.direction == .forward
        func ahead(_ along: Double) -> Double { start + (forward ? along - entry.along : entry.along - along) }
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
