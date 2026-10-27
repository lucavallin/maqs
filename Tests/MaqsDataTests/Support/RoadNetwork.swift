import CoreLocation
import Foundation
@testable import MaqsData

/// A synthetic road network for the lookahead tests: ways drawn in metres on a local plane around (12.25, 46.1),
/// written as a curvature file the way the pipeline writes one.
///
/// Each way's coordinates are rounded to the polyline's 1e-6° first, so the stored geometry decodes to exactly the
/// line that was measured. The geometry is that line after the 5 m merge, `length_m` its haversine length, and the
/// corners those ``Curvature/analyze(_:)`` finds; `start_node` and `end_node` are the first and last node ids. Row ids
/// are 1, 2, … in way order, so they differ from the way ids the tests use.
struct RoadNetwork {
    /// How the file records roads that meet mid-way.
    enum Junctions {
        /// The pipeline's rule: a row for every interior node of a way that another way also has, at its end or
        /// inside it, at the distance along the stored geometry to the point nearest the node.
        case derived
        /// No `junctions` table, as in files built before it.
        case none
    }

    /// A node: its OSM id and its position in metres east (`x`) and north (`y`) of the origin.
    typealias Node = (id: Int64, x: Double, y: Double)

    /// One OSM way and its tags.
    struct Way {
        var id: Int64
        var nodes: [Node]
        var ref: String?
        var name: String?
        var highway: String
        var oneway: Int
        var junction: String?

        init(
            _ id: Int64, _ nodes: [Node], ref: String? = nil, name: String? = nil, highway: String = "secondary",
            oneway: Int = 0, junction: String? = nil
        ) {
            self.id = id
            self.nodes = nodes
            self.ref = ref
            self.name = name
            self.highway = highway
            self.oneway = oneway
            self.junction = junction
        }
    }

    static let origin = CLLocationCoordinate2D(latitude: 46.1, longitude: 12.25)

    var ways: [Way]

    init(_ ways: [Way]) {
        self.ways = ways
    }

    /// The point `x` metres east and `y` metres north of the origin (110,574 m per degree of latitude, 111,320 ×
    /// cos(46.1°) per degree of longitude), rounded to 1e-6°.
    static func coordinate(x: Double, y: Double) -> CLLocationCoordinate2D {
        let longitudeScale = Geodesy.metresPerDegreeLongitudeAtEquator * cos(origin.latitude * .pi / 180)
        return CLLocationCoordinate2D(
            latitude: rounded(origin.latitude + y / Geodesy.metresPerDegreeLatitude),
            longitude: rounded(origin.longitude + x / longitudeScale))
    }

    /// Writes the ways, or only those whose id is in `only`, as a curvature file at `url`.
    func write(to url: URL, only: Set<Int64>? = nil, junctions: Junctions = .none, region: String = "synthetic") throws {
        let kept = ways.filter { only?.contains($0.id) ?? true }
        let analyses = try kept.map { try Curvature.analyze(Self.line(of: $0)) }
        var segments: [SegmentRow] = []
        var corners: [CornerRow] = []
        for (index, (way, analysis)) in zip(kept, analyses).enumerated() {
            let rowID = Int64(index + 1)
            segments.append(SegmentRow(
                id: rowID, osmWayID: way.id, name: way.name, ref: way.ref, highway: way.highway, oneway: way.oneway,
                length: analysis.length, score: analysis.score,
                startNode: way.nodes.first?.id ?? 0, endNode: way.nodes.last?.id ?? 0,
                coordinates: analysis.merged, junction: way.junction))
            for corner in analysis.corners {
                corners.append(CornerRow(
                    id: Int64(corners.count + 1), segmentID: rowID, ordinal: corner.ordinal, apex: corner.apex,
                    minRadius: corner.minRadius, direction: corner.turn.rawValue,
                    entry: corner.entry, apexDistance: corner.apexDistance, exit: corner.exit))
            }
        }
        let rows: [JunctionRow]?
        switch junctions {
        case .derived: rows = Self.junctionRows(kept, analyses)
        case .none: rows = nil
        }
        try LayerFileWriter.curvature(segments: segments, corners: corners, junctions: rows, to: url, region: region)
    }

    /// The `junctions` rows of `ways`, in way then distance order (`junction_rows` in
    /// `pipeline/src/maqs/curvature/step.py`).
    ///
    /// The merged line is a subsequence of the way's located nodes, matched in order. A node whose vertex the merge
    /// dropped is placed at the nearest point of the stretch between the kept vertices around it.
    static func junctionRows(_ ways: [Way], _ analyses: [CurvatureAnalysis]) -> [JunctionRow] {
        var owners: [Int64: Set<Int>] = [:]
        for (index, way) in ways.enumerated() {
            for node in way.nodes { owners[node.id, default: []].insert(index) }
        }
        var rows: [JunctionRow] = []
        for (index, (way, analysis)) in zip(ways, analyses).enumerated() where way.nodes.count > 2 {
            let located = line(of: way)
            let merged = analysis.merged
            var offsets = [0.0]
            for vertex in 1..<merged.count {
                offsets.append(offsets[vertex - 1] + Geodesy.distance(merged[vertex - 1], merged[vertex]))
            }
            var kept: [Int?] = Array(repeating: nil, count: located.count)
            kept[0] = 0
            kept[located.count - 1] = merged.count - 1
            var matched = 1
            for vertex in 1..<(located.count - 1)
            where matched < merged.count - 1 && same(located[vertex], merged[matched]) {
                kept[vertex] = matched
                matched += 1
            }
            var found: [(along: Double, node: Int64)] = []
            for vertex in 1..<(located.count - 1) where (owners[way.nodes[vertex].id]?.count ?? 0) > 1 {
                if let position = kept[vertex] {
                    found.append((offsets[position], way.nodes[vertex].id))
                    continue
                }
                let before = (0..<vertex).last { kept[$0] != nil }.flatMap { kept[$0] } ?? 0
                let after = ((vertex + 1)..<located.count).first { kept[$0] != nil }.flatMap { kept[$0] }
                    ?? merged.count - 1
                let along = Geodesy.nearestPoint(on: Array(merged[before...after]), to: located[vertex])?.along ?? 0
                found.append((offsets[before] + along, way.nodes[vertex].id))
            }
            found.sort { $0.along != $1.along ? $0.along < $1.along : $0.node < $1.node }
            rows += found.map { JunctionRow(segmentID: Int64(index + 1), node: $0.node, along: $0.along) }
        }
        return rows
    }

    private static func line(of way: Way) -> [CLLocationCoordinate2D] {
        way.nodes.map { coordinate(x: $0.x, y: $0.y) }
    }

    private static func rounded(_ degrees: Double) -> Double {
        (degrees * 1_000_000).rounded(.toNearestOrEven) / 1_000_000
    }

    private static func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        a.latitude == b.latitude && a.longitude == b.longitude
    }
}
