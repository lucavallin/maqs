import CoreLocation
import Foundation

/// Road segments from the installed curvature files: what lies near a position, a segment by its way id, and the
/// corners ahead of a rider matched to a road.
///
/// Several files are read together (Triveneto and Veneto may both be installed); a way found in more than one
/// comes back once, from the first file in the order given. With no files every query answers empty.
public actor Roads {
    private var files: [LayerFile]

    /// Opens every file or none.
    ///
    /// - Throws: ``QueryError`` naming the first file that cannot be opened, is not a curvature file, is damaged, or
    ///   repeats another file's region.
    public init(files: [URL]) throws(QueryError) {
        self.files = try LayerFile.openAll(files, as: .curvature)
    }

    /// Replaces the files this reader answers from, opening every one or none: when one fails the previous files
    /// stay in place.
    ///
    /// Call it after `MaqsCore` installs, updates or removes a pack. Apple's SQLite cannot read an open file after
    /// it is deleted or renamed over, so until you call it, queries on a replaced file may throw
    /// ``QueryError/unreadable(file:)``.
    ///
    /// - Throws: what ``init(files:)`` throws.
    public func setFiles(_ urls: [URL]) throws(QueryError) {
        files = try LayerFile.openAll(urls, as: .curvature)
    }

    /// The segments within `within` metres of `position`, nearest first.
    ///
    /// Each result carries the nearest point's distance along the segment and the drawing-direction heading there,
    /// which is what a map-matcher needs. A way found in more than one file is returned once, from the first file.
    ///
    /// - Parameters:
    ///   - position: A real position; the no-fix value and non-finite values are rejected.
    ///   - within: 1...500 metres.
    ///   - limit: 1...100.
    /// - Throws: ``QueryError/invalidInput(_:)`` for a position or a bound out of range, before any file is read;
    ///   ``QueryError/corruptData(file:detail:)`` for a stored geometry that is not a valid polyline; otherwise a
    ///   file error.
    public func segments(near position: CLLocationCoordinate2D, within: Double = 50, limit: Int = 20) throws(QueryError) -> [NearbySegment] {
        guard Geodesy.isValid(position) else { throw .invalidInput("position must be a real coordinate") }
        guard (1...500).contains(within) else { throw .invalidInput("within must be within 1...500 metres") }
        guard (1...100).contains(limit) else { throw .invalidInput("limit must be within 1...100") }

        let latitudeDegrees = within / Self.metresPerDegree
        // Longitude degrees shrink towards the poles; near them take the whole range rather than divide by ~0.
        let cosine = cos(position.latitude * .pi / 180)
        let longitudeDegrees = cosine < 0.01 ? 360 : latitudeDegrees / cosine
        let latitudeMargin = latitudeDegrees + Self.rtreeMargin
        let longitudeMargin = longitudeDegrees + Self.rtreeMargin

        var found: [Candidate] = []
        var seen: Set<Int64> = []
        for (index, file) in files.enumerated() {
            let statement = try file.connection.prepare("\(Self.select(file)) JOIN segments_rtree r ON r.id = s.id "
                + "WHERE r.min_lon <= ?1 AND r.max_lon >= ?2 AND r.min_lat <= ?3 AND r.max_lat >= ?4 ORDER BY s.id")
            defer { statement.reset() }
            try statement.bind(position.longitude + longitudeMargin, at: 1)
            try statement.bind(position.longitude - longitudeMargin, at: 2)
            try statement.bind(position.latitude + latitudeMargin, at: 3)
            try statement.bind(position.latitude - latitudeMargin, at: 4)
            var thisFile: [Int64] = []
            while try statement.step() {
                let row = Self.row(statement)
                // The first file to hold a way answers for it, even when its copy is out of range.
                thisFile.append(row.wayID)
                if seen.contains(row.wayID) { continue }
                let geometry = try Self.decode(row, in: file)
                guard let hit = Geodesy.nearestPoint(on: geometry, to: position), hit.distance <= within else { continue }
                found.append(Candidate(row: row, geometry: geometry, file: file, fileIndex: index, hit: hit))
            }
            seen.formUnion(thisFile)
        }
        found.sort { a, b in
            if a.hit.distance != b.hit.distance { return a.hit.distance < b.hit.distance }
            if a.fileIndex != b.fileIndex { return a.fileIndex < b.fileIndex }
            return a.row.wayID < b.row.wayID
        }
        var results: [NearbySegment] = []
        for candidate in found.prefix(limit) {
            let segment = try Self.segment(candidate.row, geometry: candidate.geometry, in: candidate.file)
            results.append(NearbySegment(segment: segment, distance: candidate.hit.distance,
                                         along: candidate.hit.along, heading: candidate.hit.heading))
        }
        return results
    }

    /// The segment of the OSM way `id`, from the first file that holds it; nil when none does.
    ///
    /// - Throws: ``QueryError/corruptData(file:detail:)`` for a stored geometry that is not a valid polyline;
    ///   otherwise a file error.
    public func segment(_ id: RoadSegment.ID) throws(QueryError) -> RoadSegment? {
        try Self.stored(id, in: files)?.segment
    }

    /// The corners coming up within `distance` metres of a rider the app has matched to a road.
    ///
    /// The walk follows the road from the position through every open file, from junction to junction: the ends of
    /// segments and, in a file with the curvature layer's `junctions` table, the nodes where roads meet a segment
    /// mid-way. So a side road is a fork on the road it leaves, the stem of a T-junction turns onto the through road,
    /// and a roundabout drawn as one ring is walked round across its closing node.
    ///
    /// Where several branches lead on it guesses. It keeps the branches with the path's last road number (`ref`),
    /// then its last name, then its last `highway` class, each step only when it leaves a branch; tags are compared
    /// whole, trimmed, with whitespace collapsed and case ignored, and a branch without the tag never matches. Among
    /// what is left it takes the smallest turn, measured over 20 m either side of the junction (or the whole
    /// stretch, when shorter); ties go to the lower way id, then `forward`. Each guess is a ``Fork``, and the corners
    /// past it are marked ``UpcomingCorner/afterFork``; ask again on every position update and a wrong guess is
    /// corrected once the rider is through the junction.
    ///
    /// The walk never enters a segment against its effective one-way (``RoadSegment/oneway``), except that it keeps
    /// to the rider's own segment in the direction given, straight on past junctions, until it leaves it. It never
    /// travels the stretch between two junctions twice, so a loop ends the walk.
    ///
    /// In a file without the `junctions` table (built before it) the walk knows segment ends only: it passes side
    /// roads that meet the segment mid-way without a fork, and where the road ends in the middle of another way it
    /// stops with ``Lookahead/End/noContinuation(at:)``.
    ///
    /// - Parameters:
    ///   - position: The matched position. Its segment is read again from the open files by its id; `along` is
    ///     clamped to 0...length, and at the very end it continues from the node, at distance 0.
    ///   - distance: Above 0 and at most 10,000 metres.
    /// - Throws: ``QueryError/invalidInput(_:)`` for a distance out of range or an `along` that is not finite, before
    ///   any file is read; ``QueryError/unknownSegment(_:)`` when no open file holds the segment;
    ///   ``QueryError/corruptData(file:detail:)`` for a stored value that cannot be decoded; otherwise a file error.
    public func cornersAhead(from position: RoadPosition, distance: Double = 1_000) throws(QueryError) -> Lookahead {
        guard distance > 0, distance <= 10_000 else {
            throw .invalidInput("distance must be above 0 and at most 10000 metres")
        }
        guard position.along.isFinite else { throw .invalidInput("along must be a finite number") }
        guard let start = try Self.stored(position.segment.id, in: files) else {
            throw .unknownSegment(position.segment.id)
        }
        var walk = LookaheadWalk(files: files, distance: distance)
        return try walk.run(from: start, direction: position.direction, along: position.along)
    }

    // MARK: Rows

    /// Metres per degree of latitude on the sphere the module measures with (`6_371_008.8 × π / 180`), rounded; the
    /// box only has to contain the circle, and the margin below covers the rounding.
    private static let metresPerDegree = 111_195.0
    /// Slack for the R*Tree's float32 rounding of its boxes, in degrees (about a metre).
    private static let rtreeMargin = 1e-5

    /// One `segments` row before its corners are read.
    struct Row {
        var rowID: Int64
        var wayID: Int64
        var name: String?
        var ref: String?
        var highway: String
        var surface: String?
        var junction: String?
        var maxspeed: String?
        var oneway: OneWay
        var length: Double
        var score: Double
        var startNode: Int64
        var endNode: Int64
        var encodedGeometry: String
    }

    /// A row in range of the position, with its decoded geometry and where the position lies on it.
    private struct Candidate {
        var row: Row
        var geometry: [CLLocationCoordinate2D]
        var file: LayerFile
        var fileIndex: Int
        var hit: (distance: Double, along: Double, heading: Double)
    }

    /// A segment with the file and row it was read from, so the lookahead can read the row's other tables.
    struct StoredSegment {
        let segment: RoadSegment
        let rowID: Int64
        let file: LayerFile
    }

    /// The segment of way `id` from the first file that holds it, with where it is stored; nil when none does.
    static func stored(_ id: RoadSegment.ID, in files: [LayerFile]) throws(QueryError) -> StoredSegment? {
        for file in files {
            let statement = try file.connection.prepare("\(select(file)) WHERE s.osm_way_id = ?1 ORDER BY s.id LIMIT 1")
            defer { statement.reset() }
            try statement.bind(id, at: 1)
            guard try statement.step() else { continue }
            return try stored(row(statement), in: file)
        }
        return nil
    }

    /// `row` with its geometry decoded and its corners read.
    static func stored(_ row: Row, in file: LayerFile) throws(QueryError) -> StoredSegment {
        StoredSegment(segment: try segment(row, geometry: decode(row, in: file), in: file), rowID: row.rowID, file: file)
    }

    /// The columns of ``Row``, from `segments s`, then `extra` as column 14 when given; `junction` is NULL in a file
    /// without the column.
    static func select(_ file: LayerFile, adding extra: String? = nil) -> String {
        let junction = file.hasJunctionColumn ? "s.junction" : "NULL"
        let tail = extra.map { ", \($0)" } ?? ""
        return "SELECT s.id, s.osm_way_id, s.name, s.ref, s.highway, s.surface, \(junction), s.maxspeed, s.oneway, "
            + "s.length_m, s.score, s.start_node, s.end_node, s.geometry\(tail) FROM segments s"
    }

    static func row(_ statement: Statement) -> Row {
        let highway = statement.text(at: 4) ?? ""
        let junction = statement.text(at: 6)
        return Row(
            rowID: statement.int64(at: 0), wayID: statement.int64(at: 1), name: statement.text(at: 2),
            ref: statement.text(at: 3), highway: highway, surface: statement.text(at: 5), junction: junction,
            maxspeed: statement.text(at: 7),
            oneway: effectiveOneWay(column: statement.int64(at: 8), junction: junction, highway: highway),
            length: statement.double(at: 9), score: statement.double(at: 10),
            startNode: statement.int64(at: 11), endNode: statement.int64(at: 12),
            encodedGeometry: statement.text(at: 13) ?? "")
    }

    /// The `oneway` column when it is set (1 forward, -1 backward), otherwise forward for roundabouts and motorways.
    static func effectiveOneWay(column: Int64, junction: String?, highway: String) -> OneWay {
        if column == 1 { return .forward }
        if column == -1 { return .backward }
        return junction == "roundabout" || highway == "motorway" ? .forward : .none
    }

    private static func decode(_ row: Row, in file: LayerFile) throws(QueryError) -> [CLLocationCoordinate2D] {
        do throws(PolylineError) {
            return try Polyline6.decode(row.encodedGeometry[...])
        } catch {
            throw .corruptData(file: file.fileName, detail: "the geometry of segment \(row.rowID) is not a valid polyline")
        }
    }

    /// The public segment of `row`, with its corners read by `segment_id` in ordinal order.
    private static func segment(_ row: Row, geometry: [CLLocationCoordinate2D], in file: LayerFile) throws(QueryError) -> RoadSegment {
        RoadSegment(
            id: row.wayID, name: row.name, ref: row.ref, highway: row.highway, surface: row.surface,
            junction: row.junction, maxspeed: row.maxspeed, oneway: row.oneway, length: row.length, score: row.score,
            startNode: row.startNode, endNode: row.endNode, geometry: geometry,
            corners: try corners(ofRow: row.rowID, in: file))
    }

    private static func corners(ofRow rowID: Int64, in file: LayerFile) throws(QueryError) -> [Corner] {
        let statement = try file.connection.prepare(
            "SELECT ordinal, apex_lon, apex_lat, min_radius_m, direction, entry_m, apex_m, exit_m "
                + "FROM corners WHERE segment_id = ?1 ORDER BY ordinal")
        defer { statement.reset() }
        try statement.bind(rowID, at: 1)
        var corners: [Corner] = []
        while try statement.step() {
            guard let direction = statement.text(at: 4), let turn = Turn(rawValue: direction) else {
                throw .corruptData(file: file.fileName, detail: "a corner of segment \(rowID) has no left or right direction")
            }
            corners.append(Corner(
                ordinal: Int(clamping: statement.int64(at: 0)),
                apex: CLLocationCoordinate2D(latitude: statement.double(at: 2), longitude: statement.double(at: 1)),
                minRadius: statement.double(at: 3), turn: turn,
                entry: statement.double(at: 5), apexDistance: statement.double(at: 6), exit: statement.double(at: 7)))
        }
        return corners
    }
}
