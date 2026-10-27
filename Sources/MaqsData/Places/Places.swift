import CoreLocation
import Foundation

/// Peaks, passes, huts and villages from the installed places files: what lies in a bearing cone or an area.
///
/// Several files are read together (Triveneto and Veneto may both be installed); a place found in more than one
/// comes back once, from the first file in the order given. With no files every query answers empty.
public actor Places {
    private var files: [LayerFile]

    /// Opens every file or none.
    ///
    /// - Throws: ``QueryError`` naming the first file that cannot be opened, is not a places file, is damaged, or
    ///   repeats another file's region.
    public init(files: [URL]) throws(QueryError) {
        self.files = try LayerFile.openAll(files, as: .places)
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
        files = try LayerFile.openAll(urls, as: .places)
    }

    /// The places inside `cone`, nearest first.
    ///
    /// A place counts when its great-circle distance from the origin is at most the cone's `maxDistance` and its
    /// bearing is within `halfAngle` of the cone's, both limits inclusive. A place less than 1 m from the origin has
    /// no direction and is left out. With `limit`, the places with the highest `rank_score` (ties by lower
    /// `featureID`) are kept, then sorted nearest first. To check what a place can see, build a line-of-sight
    /// target from ``Place/coordinate`` and ``Place/elevation``.
    ///
    /// - Parameters:
    ///   - cone: Where to look.
    ///   - kinds: Only these kinds; nil for all, an empty set finds nothing.
    ///   - limit: At least 1; nil for no limit.
    /// - Throws: ``QueryError/invalidInput(_:)`` for a limit under 1, before any file is read; otherwise a file error.
    public func places(in cone: BearingCone, kinds: Set<PlaceKind>? = nil, limit: Int? = nil) throws(QueryError) -> [PlaceInCone] {
        if let limit, limit < 1 { throw .invalidInput("limit must be at least 1") }
        if kinds?.isEmpty == true { return [] }
        let box = Self.box(around: cone.origin, reaching: cone.maxDistance)
        var found: [(result: PlaceInCone, fileIndex: Int)] = []
        var seen: Set<PlaceID> = []
        for (index, file) in files.enumerated() {
            let statement = try file.connection.prepare(Self.sql(kinds: kinds, ordered: false))
            defer { statement.reset() }
            try Self.bind(box, kinds: kinds, to: statement)
            while try statement.step() {
                let place = Self.place(statement, region: file.region)
                guard let result = Self.result(for: place, in: cone) else { continue }
                // The pipeline writes a place once per file; only a second file repeats one, and hashing every id of
                // a 30,000-place cone costs about 7 ms in a debug build.
                if files.count > 1, !seen.insert(place.id).inserted { continue }
                found.append((result, index))
            }
        }
        if let limit, found.count > limit {
            found.sort { a, b in
                if a.result.place.rankScore != b.result.place.rankScore { return a.result.place.rankScore > b.result.place.rankScore }
                return a.result.place.featureID < b.result.place.featureID
            }
            found.removeLast(found.count - limit)
        }
        // Sorted by plain-number keys, then mapped back: comparing whole results copies each place's strings and
        // names on every comparison, which dominated a 30,000-place cone.
        let keys = found.enumerated().map { position, entry in
            (distance: entry.result.distance, fileIndex: entry.fileIndex, featureID: entry.result.place.featureID,
             position: position)
        }.sorted { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.fileIndex != b.fileIndex { return a.fileIndex < b.fileIndex }
            return a.featureID < b.featureID
        }
        return keys.map { found[$0.position].result }
    }

    /// The places whose point lies in `area` (edges included), highest `rank_score` first.
    ///
    /// - Parameters:
    ///   - area: The box to look in.
    ///   - kinds: Only these kinds; nil for all, an empty set finds nothing.
    ///   - limit: 1...5000.
    /// - Throws: ``QueryError/invalidInput(_:)`` for a limit out of range, before any file is read; otherwise a file error.
    public func places(in area: QueryArea, kinds: Set<PlaceKind>? = nil, limit: Int = 500) throws(QueryError) -> [Place] {
        guard (1...5000).contains(limit) else { throw .invalidInput("limit must be within 1...5000") }
        if kinds?.isEmpty == true { return [] }
        let box = Box(minLongitude: area.minLongitude, maxLongitude: area.maxLongitude,
                      minLatitude: area.minLatitude, maxLatitude: area.maxLatitude)
        var found: [(place: Place, fileIndex: Int)] = []
        var seen: Set<PlaceID> = []
        for (index, file) in files.enumerated() {
            let statement = try file.connection.prepare(Self.sql(kinds: kinds, ordered: true))
            defer { statement.reset() }
            try Self.bind(box, kinds: kinds, to: statement)
            try statement.bind(Int64(limit), at: 5)
            while try statement.step() {
                let place = Self.place(statement, region: file.region)
                if seen.insert(place.id).inserted { found.append((place, index)) }
            }
        }
        found.sort { a, b in
            if a.place.rankScore != b.place.rankScore { return a.place.rankScore > b.place.rankScore }
            if a.fileIndex != b.fileIndex { return a.fileIndex < b.fileIndex }
            return a.place.featureID < b.place.featureID
        }
        return found.prefix(limit).map(\.place)
    }

    /// The place with the stable key `id`, from the first file that holds it; nil when none does.
    ///
    /// - Throws: A file error.
    public func place(_ id: PlaceID) throws(QueryError) -> Place? {
        for file in files {
            let statement = try file.connection.prepare("\(Self.select) WHERE p.osm_type = ?1 AND p.osm_id = ?2")
            defer { statement.reset() }
            try statement.bind(id.osmType as String?, at: 1)
            try statement.bind(id.osmID, at: 2)
            if try statement.step() { return Self.place(statement, region: file.region) }
        }
        return nil
    }

    /// The place with row id `featureID` in the file of `region`; nil when the region is not installed or has no
    /// such row.
    ///
    /// - Throws: A file error.
    public func place(region: String, featureID: Int64) throws(QueryError) -> Place? {
        guard let file = files.first(where: { $0.region == region }) else { return nil }
        let statement = try file.connection.prepare("\(Self.select) WHERE p.id = ?1")
        defer { statement.reset() }
        try statement.bind(featureID, at: 1)
        return try statement.step() ? Self.place(statement, region: file.region) : nil
    }

    // MARK: Cone geometry

    /// The least that counts as a direction: nearer than this the bearing is noise.
    private static let minimumDistance = 1.0
    /// Slack for the inclusive limits, far below anything a position can express (about a micrometre, and a
    /// nanodegree): a place put exactly on an edge is not lost to rounding in the haversine.
    private static let distanceTolerance = 1e-6
    private static let angleTolerance = 1e-9

    /// `place` seen from the cone's origin, or nil when it is outside the cone or too close to have a direction.
    private static func result(for place: Place, in cone: BearingCone) -> PlaceInCone? {
        let distance = Geodesy.distance(cone.origin, place.coordinate)
        guard distance >= minimumDistance, distance <= cone.maxDistance + distanceTolerance else { return nil }
        let bearing = Geodesy.initialBearing(from: cone.origin, to: place.coordinate)
        var offset = (bearing - cone.bearing).truncatingRemainder(dividingBy: 360)
        if offset > 180 { offset -= 360 }
        if offset < -180 { offset += 360 }
        guard abs(offset) <= cone.halfAngle + angleTolerance else { return nil }
        return PlaceInCone(place: place, distance: distance, bearing: bearing, offset: offset)
    }

    /// A longitude/latitude box for the R*Tree.
    private struct Box {
        var minLongitude: Double
        var maxLongitude: Double
        var minLatitude: Double
        var maxLatitude: Double
    }

    /// The bounding box of the circle of `radius` metres around `centre`, a little generous.
    ///
    /// Latitude is clamped to ±90. The whole longitude range is used when the box would cross ±180, when the circle
    /// holds a pole, or when `cos(latitude)` is under 0.01, where longitude degrees are too short to bound with
    /// any precision.
    private static func box(around centre: CLLocationCoordinate2D, reaching radius: Double) -> Box {
        let margin = 1e-6
        let angular = radius / Geodesy.radius
        let degrees = angular * 180 / .pi + margin
        let latitude = Box(minLongitude: -180, maxLongitude: 180,
                           minLatitude: max(-90, centre.latitude - degrees), maxLatitude: min(90, centre.latitude + degrees))
        let cosine = cos(centre.latitude * .pi / 180)
        guard cosine >= 0.01, sin(angular) < cosine else { return latitude }
        // The widest the circle reaches east and west of the centre, on the sphere.
        let span = asin(sin(angular) / cosine) * 180 / .pi + margin
        guard centre.longitude - span >= -180, centre.longitude + span <= 180 else { return latitude }
        return Box(minLongitude: centre.longitude - span, maxLongitude: centre.longitude + span,
                   minLatitude: latitude.minLatitude, maxLatitude: latitude.maxLatitude)
    }

    // MARK: SQL

    private static let select = """
        SELECT p.id, p.osm_type, p.osm_id, p.kind, p.name, p.name_it, p.name_de, p.name_fur, p.name_sl, p.ele, \
        p.wikidata, p.lon, p.lat, p.rank_score FROM places p
        """

    /// The R*Tree box query: parameters 1...4 are the box, 5 is the limit of an `ordered` query (unused in the
    /// other), and the kinds are 6 onward.
    private static func sql(kinds: Set<PlaceKind>?, ordered: Bool) -> String {
        var sql = "\(select) JOIN places_rtree r ON r.id = p.id "
            + "WHERE r.min_lon <= ?1 AND r.max_lon >= ?2 AND r.min_lat <= ?3 AND r.max_lat >= ?4"
        if let kinds {
            sql += " AND p.kind IN (\((6..<6 + kinds.count).map { "?\($0)" }.joined(separator: ", ")))"
        }
        if ordered { sql += " ORDER BY p.rank_score DESC, p.id LIMIT ?5" }
        return sql
    }

    /// Binds the box to parameters 1...4 and the kinds from 6; a set iterates in one order, so the placeholders and
    /// the values agree.
    private static func bind(_ box: Box, kinds: Set<PlaceKind>?, to statement: Statement) throws(QueryError) {
        try statement.bind(box.maxLongitude, at: 1)
        try statement.bind(box.minLongitude, at: 2)
        try statement.bind(box.maxLatitude, at: 3)
        try statement.bind(box.minLatitude, at: 4)
        for (offset, kind) in (kinds ?? []).enumerated() {
            try statement.bind(kind.column as String?, at: 6 + Int32(offset))
        }
    }

    /// The place in the current row of a statement that selected ``select``'s columns.
    private static func place(_ statement: Statement, region: String) -> Place {
        var names: [String: String] = [:]
        for (key, column) in [("it", 5), ("de", 6), ("fur", 7), ("sl", 8)] as [(String, Int32)] {
            if let value = statement.text(at: column) { names[key] = value }
        }
        return Place(
            id: PlaceID(osmType: statement.text(at: 1) ?? "", osmID: statement.int64(at: 2)),
            region: region, featureID: statement.int64(at: 0), kind: PlaceKind(column: statement.text(at: 3) ?? ""),
            name: statement.text(at: 4), localizedNames: names,
            elevation: statement.isNull(at: 9) ? nil : statement.double(at: 9), wikidata: statement.text(at: 10),
            coordinate: CLLocationCoordinate2D(latitude: statement.double(at: 12), longitude: statement.double(at: 11)),
            rankScore: statement.double(at: 13))
    }
}
