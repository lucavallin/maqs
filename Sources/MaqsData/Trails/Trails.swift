import CoreLocation
import Foundation

/// Trail search and lookup over the installed trails files.
///
/// Several files are read together (Triveneto and Veneto may both be installed); a trail found in more than one
/// comes back once, from the first file in the order given. With no files every query answers empty.
public actor Trails {
    private var files: [LayerFile]

    /// Opens every file or none.
    ///
    /// - Throws: ``QueryError`` naming the first file that cannot be opened, is not a trails file, is damaged, or
    ///   repeats another file's region.
    public init(files: [URL]) throws(QueryError) {
        self.files = try LayerFile.openAll(files, as: .trails)
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
        files = try LayerFile.openAll(urls, as: .trails)
    }

    /// Finds trails by number, name or place.
    ///
    /// Results come in three groups, each trail once, in the first it qualifies for: a `ref`, `ref:REI` or name equal
    /// to `text` ignoring case; for a text of digits, a `ref` or `ref:REI` that contains the number as a whole run
    /// of digits (`926` finds `926A`, `E926` and `926/1`, never `1926`); then full-text matches over number, name,
    /// start, end and operator, each word a whole word and the last a prefix. Punctuation is never search syntax.
    /// Within a group the trail nearest to `near` comes first (trails without geometry last), otherwise file
    /// order. Secondary records are left out.
    ///
    /// - Parameters:
    ///   - text: What the user typed; blank text finds nothing.
    ///   - near: Orders results by distance to a trail's bounding box.
    ///   - difficulty: A range within 1...6; trails without a grade are left out when it is given.
    ///   - limit: 1...500.
    /// - Throws: ``QueryError/invalidInput(_:)`` for a limit or difficulty out of range or a `near` that is not a
    ///   real position (NaN, infinity, the no-fix value), before any file is read; otherwise a file error.
    public func search(
        _ text: String, near: CLLocationCoordinate2D? = nil, difficulty: ClosedRange<Int>? = nil, limit: Int = 50
    ) throws(QueryError) -> [TrailSummary] {
        guard (1...500).contains(limit) else { throw .invalidInput("limit must be within 1...500") }
        try TrailRows.check(difficulty)
        if let near, !Geodesy.isValid(near) { throw .invalidInput("near is not a valid coordinate") }
        return try TrailSearch.search(text, near: near, difficulty: difficulty, limit: limit, in: files)
    }

    /// The primary trails whose bounding box meets `area`, longest first.
    ///
    /// - Parameters:
    ///   - area: The box to look in.
    ///   - difficulty: A range within 1...6; trails without a grade are left out when it is given.
    ///   - limit: 1...2000.
    /// - Throws: ``QueryError/invalidInput(_:)`` for a limit or difficulty out of range; otherwise a file error.
    public func trails(in area: QueryArea, difficulty: ClosedRange<Int>? = nil, limit: Int = 200) throws(QueryError) -> [TrailSummary] {
        guard (1...2000).contains(limit) else { throw .invalidInput("limit must be within 1...2000") }
        try TrailRows.check(difficulty)
        var found: [(summary: TrailSummary, fileIndex: Int)] = []
        var seen: Set<TrailID> = []
        for (index, file) in files.enumerated() {
            let statement = try file.connection.prepare(TrailRows.areaSQL)
            defer { statement.reset() }
            try statement.bind(area.maxLongitude, at: 1)
            try statement.bind(area.minLongitude, at: 2)
            try statement.bind(area.maxLatitude, at: 3)
            try statement.bind(area.minLatitude, at: 4)
            try statement.bind(difficulty.map { Int64($0.lowerBound) }, at: 5)
            try statement.bind(difficulty.map { Int64($0.upperBound) }, at: 6)
            try statement.bind(Int64(limit), at: 7)
            while try statement.step() {
                let summary = TrailRows.summary(statement, region: file.region)
                if seen.insert(summary.id).inserted { found.append((summary, index)) }
            }
        }
        found.sort { a, b in
            if a.summary.length != b.summary.length { return a.summary.length > b.summary.length }
            if a.fileIndex != b.fileIndex { return a.fileIndex < b.fileIndex }
            return a.summary.featureID < b.summary.featureID
        }
        return found.prefix(limit).map(\.summary)
    }

    /// The trail with the stable key `id`, primary or secondary, from the first file that holds it; nil when none does.
    ///
    /// - Throws: ``QueryError/corruptData(file:detail:)`` when the path cannot be decoded; otherwise a file error.
    public func trail(_ id: TrailID) throws(QueryError) -> Trail? {
        for file in files {
            if let trail = try TrailRows.trail(in: file, where: "t.source = ?1 AND t.source_id = ?2", bind: { statement throws(QueryError) in
                try statement.bind(id.source as String?, at: 1)
                try statement.bind(id.sourceID as String?, at: 2)
            }) {
                return trail
            }
        }
        return nil
    }

    /// The trail with row id `featureID` in the file of `region`, primary or secondary; nil when the region is not
    /// installed or has no such row.
    ///
    /// - Throws: ``QueryError/corruptData(file:detail:)`` when the path cannot be decoded; otherwise a file error.
    public func trail(region: String, featureID: Int64) throws(QueryError) -> Trail? {
        guard let file = files.first(where: { $0.region == region }) else { return nil }
        return try TrailRows.trail(in: file, where: "t.id = ?1", bind: { statement throws(QueryError) in
            try statement.bind(featureID, at: 1)
        })
    }
}
