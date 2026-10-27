import CoreLocation
import Foundation

/// The trails SQL and the decoding of a `trails` row, shared by search and lookup.
enum TrailRows {
    /// The columns of a ``TrailSummary``, in the order ``summary(_:region:)`` reads them (0...21).
    static let summaryColumns = """
        t.id, t.source, t.source_id, t.ref, t.ref_rei, t.name, t.difficulty, t.difficulty_scheme, t.difficulty_value, \
        t.network, t.operator, t.osmc_symbol, t.from_name, t.to_name, t.length_m, t.ascent_m, t.descent_m, \
        t.min_lon, t.min_lat, t.max_lon, t.max_lat, t.geometry_status
        """

    /// The columns a ``Trail`` adds to its summary (22...30).
    static let detailColumns = """
        t.roundtrip, t.survey_date, t.website, t.source_licence, t.source_date, t.osm_type, t.osm_id, t.secondary_of, \
        t.geometry
        """

    /// Parameters 1...4 are the box, 5 and 6 the difficulty range (NULL for none), 7 the limit.
    static let areaSQL = """
        SELECT \(summaryColumns) FROM trails t JOIN trails_rtree r ON r.id = t.id \
        WHERE r.min_lon <= ?1 AND r.max_lon >= ?2 AND r.min_lat <= ?3 AND r.max_lat >= ?4 \
        AND t.secondary_of IS NULL AND (?5 IS NULL OR t.difficulty BETWEEN ?5 AND ?6) \
        ORDER BY t.length_m DESC, t.id LIMIT ?7
        """

    /// The one row selected by `clause` (over the alias `t`) with its path, or nil when there is none.
    static func trail(
        in file: LayerFile, where clause: String, bind: (Statement) throws(QueryError) -> Void
    ) throws(QueryError) -> Trail? {
        let statement = try file.connection.prepare("SELECT \(summaryColumns), \(detailColumns) FROM trails t WHERE \(clause)")
        defer { statement.reset() }
        try bind(statement)
        guard try statement.step() else { return nil }
        let summary = summary(statement, region: file.region)
        let geometry = statement.text(at: 30) ?? ""
        let secondaryRow = statement.isNull(at: 29) ? nil : statement.int64(at: 29)
        var secondaryOf: TrailID?
        if let secondaryRow { secondaryOf = try id(ofRow: secondaryRow, in: file) }
        return Trail(
            summary: summary,
            roundtrip: statement.isNull(at: 22) ? nil : statement.int64(at: 22) != 0,
            surveyDate: statement.text(at: 23), website: statement.text(at: 24),
            sourceLicence: statement.text(at: 25), sourceDate: statement.text(at: 26),
            osmType: statement.text(at: 27), osmID: statement.isNull(at: 28) ? nil : statement.int64(at: 28),
            secondaryOf: secondaryOf, path: try path(geometry, of: summary.featureID, in: file)
        )
    }

    /// The summary in the current row of a statement that selected ``summaryColumns`` first.
    static func summary(_ statement: Statement, region: String) -> TrailSummary {
        let area: QueryArea?
        if (17...20).allSatisfy({ !statement.isNull(at: Int32($0)) }) {
            let bounds = (17...20).map { statement.double(at: Int32($0)) }
            area = bounds.allSatisfy(\.isFinite) ? QueryArea(stored: bounds[0], bounds[1], bounds[2], bounds[3]) : nil
        } else {
            area = nil
        }
        return TrailSummary(
            id: TrailID(source: statement.text(at: 1) ?? "", sourceID: statement.text(at: 2) ?? ""),
            region: region, featureID: statement.int64(at: 0),
            ref: statement.text(at: 3), refREI: statement.text(at: 4), name: statement.text(at: 5),
            from: statement.text(at: 12), to: statement.text(at: 13),
            difficulty: TrailDifficulty(
                grade: statement.isNull(at: 6) ? nil : Int(clamping: statement.int64(at: 6)),
                scheme: statement.text(at: 7), originalValue: statement.text(at: 8)),
            network: statement.text(at: 9), operator: statement.text(at: 10), osmcSymbol: statement.text(at: 11),
            length: statement.double(at: 14),
            ascent: statement.isNull(at: 15) ? nil : statement.double(at: 15),
            descent: statement.isNull(at: 16) ? nil : statement.double(at: 16),
            area: area, geometryStatus: GeometryStatus(statement.text(at: 21) ?? ""))
    }

    /// A difficulty filter must lie within the grades 1...6.
    static func check(_ difficulty: ClosedRange<Int>?) throws(QueryError) {
        if let difficulty, difficulty.lowerBound < 1 || difficulty.upperBound > 6 {
            throw .invalidInput("difficulty must lie within 1...6")
        }
    }

    /// The key of row `rowID`, or nil when the file has no such row.
    private static func id(ofRow rowID: Int64, in file: LayerFile) throws(QueryError) -> TrailID? {
        let statement = try file.connection.prepare("SELECT source, source_id FROM trails WHERE id = ?1")
        defer { statement.reset() }
        try statement.bind(rowID, at: 1)
        guard try statement.step() else { return nil }
        return TrailID(source: statement.text(at: 0) ?? "", sourceID: statement.text(at: 1) ?? "")
    }

    private static func path(_ geometry: String, of rowID: Int64, in file: LayerFile) throws(QueryError) -> [[CLLocationCoordinate2D]] {
        do throws(PolylineError) {
            return try Polyline6.decodeLegs(geometry)
        } catch {
            throw .corruptData(file: file.fileName, detail: "the path of trail \(rowID) is not a valid polyline")
        }
    }
}
