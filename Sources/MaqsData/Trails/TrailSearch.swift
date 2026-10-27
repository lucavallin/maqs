import CoreLocation
import Foundation
import SQLite3

/// The three search tiers of ``Trails/search(_:near:difficulty:limit:)`` (`docs/superpowers/specs`, Trails).
enum TrailSearch {
    /// A trail that matched in a scan, with what ordering needs; the summary is loaded for the winners only.
    struct Candidate {
        let fileIndex: Int
        let rowID: Int64
        let id: TrailID
        let ref: String?
        let refREI: String?
        let name: String?
        let area: QueryArea?
    }

    /// Parameter 1 of the full-text SQL is the `MATCH` expression.
    private static let scanColumns = "t.id, t.source, t.source_id, t.ref, t.ref_rei, t.name, t.difficulty, t.min_lon, t.min_lat, t.max_lon, t.max_lat"
    private static let plainSQL = "SELECT \(scanColumns) FROM trails t WHERE t.secondary_of IS NULL ORDER BY t.id"
    private static let fullTextSQL = """
        SELECT \(scanColumns) FROM trails_fts JOIN trails t ON t.id = trails_fts.rowid \
        WHERE trails_fts MATCH ?1 AND t.secondary_of IS NULL ORDER BY t.id
        """

    /// `near` and the arguments are checked by the caller.
    static func search(
        _ text: String, near: CLLocationCoordinate2D?, difficulty: ClosedRange<Int>?, limit: Int, in files: [LayerFile]
    ) throws(QueryError) -> [TrailSummary] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, !files.isEmpty else { return [] }
        let query = words.joined(separator: " ")
        var chosen: [Candidate] = []
        var seen: Set<TrailID> = []

        // Tiers 1 and 2 read the same rows: one scan per file, kept for both.
        var plain: [[Candidate]]?
        func plainRows() throws(QueryError) -> [[Candidate]] {
            if let plain { return plain }
            var rows: [[Candidate]] = []
            for (index, file) in files.enumerated() {
                rows.append(try scan(plainSQL, in: file, index: index, difficulty: difficulty))
            }
            plain = rows
            return rows
        }

        for tier in 1...3 {
            if chosen.count >= limit { break }
            var found: [Candidate] = []
            var inTier: Set<TrailID> = []
            func take(_ candidate: Candidate) {
                if !seen.contains(candidate.id), inTier.insert(candidate.id).inserted { found.append(candidate) }
            }
            switch tier {
            case 1:
                for candidate in try plainRows().joined() where equals(candidate, query) { take(candidate) }
            case 2:
                guard query.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
                for candidate in try plainRows().joined() where containsNumber(candidate, query) { take(candidate) }
            default:
                let expression = matchExpression(words)
                for (index, file) in files.enumerated() {
                    for candidate in try fullText(expression, in: file, index: index, difficulty: difficulty) { take(candidate) }
                }
            }
            seen.formUnion(inTier)
            chosen += ordered(found, near: near)
        }

        var summaries: [TrailSummary] = []
        for candidate in chosen.prefix(limit) {
            summaries.append(try summary(of: candidate, in: files[candidate.fileIndex]))
        }
        return summaries
    }

    // MARK: Tiers

    /// `ref`, `ref:REI` or name equal to the text; `caseInsensitiveCompare` is accent-sensitive, like the column text.
    private static func equals(_ candidate: Candidate, _ query: String) -> Bool {
        [candidate.ref, candidate.refREI, candidate.name].contains { $0?.caseInsensitiveCompare(query) == .orderedSame }
    }

    /// `ref` or `ref:REI` holding the number as a whole run of ASCII digits.
    private static func containsNumber(_ candidate: Candidate, _ number: String) -> Bool {
        [candidate.ref, candidate.refREI].contains { value in
            guard let value else { return false }
            return value.split(whereSeparator: { !($0.isASCII && $0.isNumber) }).contains { $0 == number }
        }
    }

    /// Each word an FTS5 string (inner `"` doubled), the last a prefix, ANDed by juxtaposition: no user text reaches
    /// FTS5 as syntax.
    private static func matchExpression(_ words: [String]) -> String {
        words.enumerated().map { index, word in
            let quoted = "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return index == words.count - 1 ? quoted + "*" : quoted
        }.joined(separator: " ")
    }

    /// A syntax error from FTS5 (`SQLITE_ERROR`) is no match; a damaged or unreadable file still throws.
    static func fullText(
        _ expression: String, in file: LayerFile, index: Int, difficulty: ClosedRange<Int>?
    ) throws(QueryError) -> [Candidate] {
        let statement = try file.connection.prepare(fullTextSQL)
        defer { statement.reset() }
        do throws(QueryError) {
            try statement.bind(expression as String?, at: 1)
            return try rows(of: statement, index: index, difficulty: difficulty)
        } catch {
            if statement.failureCode & 0xFF == SQLITE_ERROR { return [] }
            throw error
        }
    }

    private static func scan(
        _ sql: String, in file: LayerFile, index: Int, difficulty: ClosedRange<Int>?
    ) throws(QueryError) -> [Candidate] {
        let statement = try file.connection.prepare(sql)
        defer { statement.reset() }
        return try rows(of: statement, index: index, difficulty: difficulty)
    }

    private static func rows(
        of statement: Statement, index: Int, difficulty: ClosedRange<Int>?
    ) throws(QueryError) -> [Candidate] {
        var candidates: [Candidate] = []
        while try statement.step() {
            if let difficulty {
                guard !statement.isNull(at: 6), difficulty.contains(Int(clamping: statement.int64(at: 6))) else { continue }
            }
            var area: QueryArea?
            if (7...10).allSatisfy({ !statement.isNull(at: Int32($0)) }) {
                let bounds = (7...10).map { statement.double(at: Int32($0)) }
                if bounds.allSatisfy(\.isFinite) { area = QueryArea(stored: bounds[0], bounds[1], bounds[2], bounds[3]) }
            }
            candidates.append(Candidate(
                fileIndex: index, rowID: statement.int64(at: 0),
                id: TrailID(source: statement.text(at: 1) ?? "", sourceID: statement.text(at: 2) ?? ""),
                ref: statement.text(at: 3), refREI: statement.text(at: 4), name: statement.text(at: 5), area: area))
        }
        return candidates
    }

    // MARK: Order

    /// Nearest bounding box first (0 inside it), trails without one last; without `near`, file order then id.
    private static func ordered(_ candidates: [Candidate], near: CLLocationCoordinate2D?) -> [Candidate] {
        let keyed = candidates.map { candidate in
            (candidate, near.map { point in candidate.area.map { distance(from: point, to: $0) } ?? .infinity } ?? 0)
        }
        return keyed.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.0.fileIndex != b.0.fileIndex { return a.0.fileIndex < b.0.fileIndex }
            return a.0.rowID < b.0.rowID
        }.map(\.0)
    }

    /// Metres from `point` to the nearest point of `area`: 0 inside it, otherwise to the point with the longitude
    /// and latitude clamped into the box.
    private static func distance(from point: CLLocationCoordinate2D, to area: QueryArea) -> Double {
        let nearest = CLLocationCoordinate2D(
            latitude: min(max(point.latitude, area.minLatitude), area.maxLatitude),
            longitude: min(max(point.longitude, area.minLongitude), area.maxLongitude))
        return Geodesy.distance(point, nearest)
    }

    private static func summary(of candidate: Candidate, in file: LayerFile) throws(QueryError) -> TrailSummary {
        let statement = try file.connection.prepare("SELECT \(TrailRows.summaryColumns) FROM trails t WHERE t.id = ?1")
        defer { statement.reset() }
        try statement.bind(candidate.rowID, at: 1)
        guard try statement.step() else {
            throw .corruptData(file: file.fileName, detail: "trail \(candidate.rowID) vanished during a search")
        }
        return TrailRows.summary(statement, region: file.region)
    }
}
