import CoreLocation
import Foundation
import SQLite3

/// A bounding box as the layer files store it, for the R*Tree row of a record.
struct RowBox {
    var minLon: Double
    var minLat: Double
    var maxLon: Double
    var maxLat: Double

    /// The box around `coordinates`, or `nil` when there are none (the pipeline then writes no R*Tree row).
    init?(around coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return nil }
        minLon = first.longitude
        maxLon = first.longitude
        minLat = first.latitude
        maxLat = first.latitude
        for coordinate in coordinates.dropFirst() {
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
        }
    }
}

/// One `trails` row. `nil` columns are NULL; `bbox` nil writes no R*Tree row and NULL bounds, as the pipeline does
/// for a trail without geometry.
struct TrailRow {
    var id: Int64
    var source: String
    var sourceID: String
    var sourceLicence: String?
    var sourceDate: String?
    var osmType: String?
    var osmID: Int64?
    var ref: String?
    var refREI: String?
    var name: String?
    var difficulty: Int?
    var difficultyScheme: String?
    var difficultyValue: String?
    var network: String?
    var `operator`: String?
    var osmcSymbol: String?
    var fromName: String?
    var toName: String?
    var roundtrip: Bool?
    var surveyDate: String?
    var website: String?
    var length: Double
    var ascent: Double?
    var descent: Double?
    var bbox: RowBox?
    var geometry: String
    var geometryStatus: String
    var secondaryOf: Int64?

    /// An OSM relation trail by default (`relation/<id>`). `geometry` defaults to `legs` encoded, `bbox` to the box around them.
    init(
        id: Int64, source: String = "osm", sourceID: String? = nil, sourceLicence: String? = "ODbL 1.0",
        sourceDate: String? = "2026-10-14T20:21:12Z", osmType: String? = "relation", osmID: Int64? = nil,
        ref: String? = nil, refREI: String? = nil, name: String? = nil,
        difficulty: Int? = nil, difficultyScheme: String? = nil, difficultyValue: String? = nil,
        network: String? = nil, operator: String? = nil, osmcSymbol: String? = nil,
        fromName: String? = nil, toName: String? = nil, roundtrip: Bool? = nil,
        surveyDate: String? = nil, website: String? = nil,
        length: Double = 0, ascent: Double? = nil, descent: Double? = nil,
        legs: [[CLLocationCoordinate2D]] = [], geometry: String? = nil, geometryStatus: String = "ordered",
        secondaryOf: Int64? = nil
    ) {
        self.id = id
        self.source = source
        self.sourceID = sourceID ?? "relation/\(id)"
        self.sourceLicence = sourceLicence
        self.sourceDate = sourceDate
        self.osmType = osmType
        self.osmID = osmID ?? (osmType == nil ? nil : id)
        self.ref = ref
        self.refREI = refREI
        self.name = name
        self.difficulty = difficulty
        self.difficultyScheme = difficultyScheme
        self.difficultyValue = difficultyValue
        self.network = network
        self.operator = `operator`
        self.osmcSymbol = osmcSymbol
        self.fromName = fromName
        self.toName = toName
        self.roundtrip = roundtrip
        self.surveyDate = surveyDate
        self.website = website
        self.length = length
        self.ascent = ascent
        self.descent = descent
        self.bbox = RowBox(around: legs.flatMap { $0 })
        self.geometry = geometry ?? Polyline6Encoder.encode(legs: legs)
        self.geometryStatus = geometryStatus
        self.secondaryOf = secondaryOf
    }
}

/// One `places` row; the R*Tree row is the point itself.
struct PlaceRow {
    var id: Int64
    var osmType: String
    var osmID: Int64
    var kind: String
    var name: String?
    var nameIT: String?
    var nameDE: String?
    var nameFUR: String?
    var nameSL: String?
    var ele: Double?
    var wikidata: String?
    var coordinate: CLLocationCoordinate2D
    var rankScore: Double

    /// An OSM node by default, with `osmID` equal to `id`.
    init(
        id: Int64, osmType: String = "node", osmID: Int64? = nil, kind: String = "peak",
        name: String? = nil, nameIT: String? = nil, nameDE: String? = nil, nameFUR: String? = nil, nameSL: String? = nil,
        ele: Double? = nil, wikidata: String? = nil, coordinate: CLLocationCoordinate2D, rankScore: Double = 0
    ) {
        self.id = id
        self.osmType = osmType
        self.osmID = osmID ?? id
        self.kind = kind
        self.name = name
        self.nameIT = nameIT
        self.nameDE = nameDE
        self.nameFUR = nameFUR
        self.nameSL = nameSL
        self.ele = ele
        self.wikidata = wikidata
        self.coordinate = coordinate
        self.rankScore = rankScore
    }
}

/// One `segments` row. `bbox` nil writes no R*Tree row and NULL bounds.
struct SegmentRow {
    var id: Int64
    var osmWayID: Int64
    var name: String?
    var ref: String?
    var highway: String
    var surface: String?
    var oneway: Int
    var maxspeed: String?
    var length: Double
    var score: Double
    var startNode: Int64
    var endNode: Int64
    var bbox: RowBox?
    var geometry: String
    var junction: String?

    /// `osmWayID` defaults to `id`, `geometry` to `coordinates` encoded and `bbox` to the box around them.
    init(
        id: Int64, osmWayID: Int64? = nil, name: String? = nil, ref: String? = nil, highway: String = "secondary",
        surface: String? = nil, oneway: Int = 0, maxspeed: String? = nil, length: Double = 0, score: Double = 0,
        startNode: Int64, endNode: Int64, coordinates: [CLLocationCoordinate2D] = [], geometry: String? = nil,
        junction: String? = nil
    ) {
        self.id = id
        self.osmWayID = osmWayID ?? id
        self.name = name
        self.ref = ref
        self.highway = highway
        self.surface = surface
        self.oneway = oneway
        self.maxspeed = maxspeed
        self.length = length
        self.score = score
        self.startNode = startNode
        self.endNode = endNode
        self.bbox = RowBox(around: coordinates)
        self.geometry = geometry ?? Polyline6Encoder.encode(coordinates)
        self.junction = junction
    }
}

/// One `corners` row; the R*Tree row is the apex.
struct CornerRow {
    var id: Int64
    var segmentID: Int64
    var ordinal: Int
    var apex: CLLocationCoordinate2D
    var minRadius: Double
    /// `left` or `right`, in the segment's drawing direction.
    var direction: String
    var entry: Double
    var apexDistance: Double
    var exit: Double
}

/// One `junctions` row: a node of another way met by the segment at `along` metres from its first vertex.
struct JunctionRow {
    var segmentID: Int64
    var node: Int64
    var along: Double
}

/// Builds synthetic layer files with the pipeline's DDL (`SCHEMAS` in `pipeline/src/maqs/sqlite_out.py`, copied
/// verbatim), FTS5 and R*Tree filled, so tests cover cases the fixture lacks. Each file is written into a fresh path
/// in a test's `TemporaryDirectory`, never into the repository.
///
/// The options make broken variants: another `schemaVersion` or `layer`, a `metadataRows` count other than 1, a table
/// or `table.column` left out with `dropping`, and for curvature no `junctions` table (`nil`) or no `segments.junction`
/// column, as in files built before them.
enum LayerFileWriter {
    /// A write that SQLite refused, or an option that names nothing in the schema.
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: DDL, verbatim from pipeline/src/maqs/sqlite_out.py

    private static let metadataDDL = """
        CREATE TABLE metadata (
          schema_version INTEGER NOT NULL, layer TEXT NOT NULL, region TEXT NOT NULL,
          data_date TEXT NOT NULL, osm_timestamp TEXT, attribution TEXT NOT NULL
        );
        """

    private static let trailsDDL = metadataDDL + """

        CREATE TABLE trails (
          id INTEGER PRIMARY KEY, source TEXT NOT NULL, source_id TEXT NOT NULL,
          source_licence TEXT, source_date TEXT,
          osm_type TEXT, osm_id INTEGER, ref TEXT, ref_rei TEXT, name TEXT,
          difficulty INTEGER, difficulty_scheme TEXT, difficulty_value TEXT,
          network TEXT, operator TEXT, osmc_symbol TEXT, from_name TEXT, to_name TEXT, roundtrip INTEGER,
          survey_date TEXT, website TEXT,
          length_m REAL NOT NULL, ascent_m REAL, descent_m REAL,
          min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL,
          -- geometry: one encoded polyline per leg, legs joined by ';' (outside the polyline alphabet)
          geometry TEXT NOT NULL, geometry_status TEXT NOT NULL,
          secondary_of INTEGER REFERENCES trails(id)
        );
        CREATE VIRTUAL TABLE trails_fts USING fts5(ref, name, from_name, to_name, operator,
          content='trails', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
        CREATE VIRTUAL TABLE trails_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
        """

    private static let placesDDL = metadataDDL + """

        CREATE TABLE places (
          id INTEGER PRIMARY KEY, osm_type TEXT NOT NULL, osm_id INTEGER NOT NULL, kind TEXT NOT NULL,
          name TEXT, name_it TEXT, name_de TEXT, name_fur TEXT, name_sl TEXT,
          ele REAL, wikidata TEXT, lon REAL NOT NULL, lat REAL NOT NULL, rank_score REAL NOT NULL
        );
        CREATE VIRTUAL TABLE places_fts USING fts5(name, name_it, name_de, name_fur, name_sl,
          content='places', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
        CREATE VIRTUAL TABLE places_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
        """

    private static let curvatureDDL = metadataDDL + """

        CREATE TABLE segments (
          id INTEGER PRIMARY KEY, osm_way_id INTEGER NOT NULL, name TEXT, ref TEXT,
          highway TEXT NOT NULL, surface TEXT,
          oneway INTEGER NOT NULL DEFAULT 0, maxspeed TEXT, length_m REAL NOT NULL, score REAL NOT NULL,
          start_node INTEGER NOT NULL, end_node INTEGER NOT NULL,
          min_lon REAL, min_lat REAL, max_lon REAL, max_lat REAL, geometry TEXT NOT NULL,
          junction TEXT
        );
        CREATE TABLE corners (
          id INTEGER PRIMARY KEY, segment_id INTEGER NOT NULL REFERENCES segments(id),
          ordinal INTEGER NOT NULL,
          apex_lon REAL NOT NULL, apex_lat REAL NOT NULL, min_radius_m REAL NOT NULL,
          direction TEXT NOT NULL,
          entry_m REAL NOT NULL, apex_m REAL NOT NULL, exit_m REAL NOT NULL
        );
        CREATE INDEX corners_segment ON corners(segment_id, ordinal);
        CREATE TABLE junctions (
          segment_id INTEGER NOT NULL REFERENCES segments(id),
          node INTEGER NOT NULL,
          along_m REAL NOT NULL
        );
        CREATE INDEX junctions_node ON junctions(node);
        CREATE INDEX junctions_segment ON junctions(segment_id, along_m);
        CREATE VIRTUAL TABLE segments_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
        CREATE VIRTUAL TABLE corners_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
        """

    /// The last column of `segments`, cut from the DDL for a file built before it.
    private static let junctionColumnDDL = ",\n  junction TEXT\n"

    // MARK: Layers

    /// Writes a trails file of `rows`.
    static func trails(
        _ rows: [TrailRow], to url: URL, schemaVersion: Int = 1, layer: String? = nil, metadataRows: Int = 1,
        region: String = "synthetic", dropping: String? = nil
    ) throws {
        let metadata = Metadata(schemaVersion: schemaVersion, layer: layer ?? "trails", rows: metadataRows, region: region)
        try write(to: url, ddl: trailsDDL, metadata: metadata, ftsTables: ["trails_fts"], dropping: dropping) { database in
            for row in rows {
                try database.insert(into: "trails", [
                    ("id", .integer(row.id)), ("source", .text(row.source)), ("source_id", .text(row.sourceID)),
                    ("source_licence", .text(row.sourceLicence)), ("source_date", .text(row.sourceDate)),
                    ("osm_type", .text(row.osmType)), ("osm_id", .integer(row.osmID)),
                    ("ref", .text(row.ref)), ("ref_rei", .text(row.refREI)), ("name", .text(row.name)),
                    ("difficulty", .integer(row.difficulty.map { Int64($0) })),
                    ("difficulty_scheme", .text(row.difficultyScheme)), ("difficulty_value", .text(row.difficultyValue)),
                    ("network", .text(row.network)), ("operator", .text(row.operator)),
                    ("osmc_symbol", .text(row.osmcSymbol)), ("from_name", .text(row.fromName)),
                    ("to_name", .text(row.toName)), ("roundtrip", .integer(row.roundtrip.map { $0 ? 1 : 0 })),
                    ("survey_date", .text(row.surveyDate)), ("website", .text(row.website)),
                    ("length_m", .real(row.length)), ("ascent_m", .real(row.ascent)), ("descent_m", .real(row.descent)),
                    ("min_lon", .real(row.bbox?.minLon)), ("min_lat", .real(row.bbox?.minLat)),
                    ("max_lon", .real(row.bbox?.maxLon)), ("max_lat", .real(row.bbox?.maxLat)),
                    ("geometry", .text(row.geometry)), ("geometry_status", .text(row.geometryStatus)),
                    ("secondary_of", .integer(row.secondaryOf)),
                ])
                if let box = row.bbox {
                    try database.insertBox(into: "trails_rtree", id: row.id, box)
                }
            }
        }
    }

    /// Writes a places file of `rows`.
    static func places(
        _ rows: [PlaceRow], to url: URL, schemaVersion: Int = 1, layer: String? = nil, metadataRows: Int = 1,
        region: String = "synthetic", dropping: String? = nil
    ) throws {
        let metadata = Metadata(schemaVersion: schemaVersion, layer: layer ?? "places", rows: metadataRows, region: region)
        try write(to: url, ddl: placesDDL, metadata: metadata, ftsTables: ["places_fts"], dropping: dropping) { database in
            for row in rows {
                try database.insert(into: "places", [
                    ("id", .integer(row.id)), ("osm_type", .text(row.osmType)), ("osm_id", .integer(row.osmID)),
                    ("kind", .text(row.kind)), ("name", .text(row.name)), ("name_it", .text(row.nameIT)),
                    ("name_de", .text(row.nameDE)), ("name_fur", .text(row.nameFUR)), ("name_sl", .text(row.nameSL)),
                    ("ele", .real(row.ele)), ("wikidata", .text(row.wikidata)),
                    ("lon", .real(row.coordinate.longitude)), ("lat", .real(row.coordinate.latitude)),
                    ("rank_score", .real(row.rankScore)),
                ])
                if let point = RowBox(around: [row.coordinate]) {
                    try database.insertBox(into: "places_rtree", id: row.id, point)
                }
            }
        }
    }

    /// Writes a curvature file. `junctions` nil leaves the table out and `junctionColumn` false leaves out
    /// `segments.junction`, as in files built before them (`data-2026-10`).
    static func curvature(
        segments: [SegmentRow], corners: [CornerRow] = [], junctions: [JunctionRow]? = [], junctionColumn: Bool = true,
        to url: URL, schemaVersion: Int = 1, layer: String? = nil, metadataRows: Int = 1,
        region: String = "synthetic", dropping: String? = nil
    ) throws {
        var ddl = curvatureDDL
        if !junctionColumn {
            guard ddl.contains(junctionColumnDDL) else { throw Failure(description: "no junction column in the DDL") }
            ddl = ddl.replacingOccurrences(of: junctionColumnDDL, with: "\n")
        }
        let metadata = Metadata(schemaVersion: schemaVersion, layer: layer ?? "curvature", rows: metadataRows, region: region)
        try write(to: url, ddl: ddl, metadata: metadata, ftsTables: [], dropping: dropping) { database in
            for row in segments {
                var values: [(String, Value)] = [
                    ("id", .integer(row.id)), ("osm_way_id", .integer(row.osmWayID)),
                    ("name", .text(row.name)), ("ref", .text(row.ref)), ("highway", .text(row.highway)),
                    ("surface", .text(row.surface)), ("oneway", .integer(Int64(row.oneway))),
                    ("maxspeed", .text(row.maxspeed)), ("length_m", .real(row.length)), ("score", .real(row.score)),
                    ("start_node", .integer(row.startNode)), ("end_node", .integer(row.endNode)),
                    ("min_lon", .real(row.bbox?.minLon)), ("min_lat", .real(row.bbox?.minLat)),
                    ("max_lon", .real(row.bbox?.maxLon)), ("max_lat", .real(row.bbox?.maxLat)),
                    ("geometry", .text(row.geometry)),
                ]
                if junctionColumn {
                    values.append(("junction", .text(row.junction)))
                }
                try database.insert(into: "segments", values)
                if let box = row.bbox {
                    try database.insertBox(into: "segments_rtree", id: row.id, box)
                }
            }
            for row in corners {
                try database.insert(into: "corners", [
                    ("id", .integer(row.id)), ("segment_id", .integer(row.segmentID)),
                    ("ordinal", .integer(Int64(row.ordinal))),
                    ("apex_lon", .real(row.apex.longitude)), ("apex_lat", .real(row.apex.latitude)),
                    ("min_radius_m", .real(row.minRadius)), ("direction", .text(row.direction)),
                    ("entry_m", .real(row.entry)), ("apex_m", .real(row.apexDistance)), ("exit_m", .real(row.exit)),
                ])
                if let point = RowBox(around: [row.apex]) {
                    try database.insertBox(into: "corners_rtree", id: row.id, point)
                }
            }
            for row in junctions ?? [] {
                try database.insert(into: "junctions", [
                    ("segment_id", .integer(row.segmentID)), ("node", .integer(row.node)), ("along_m", .real(row.along)),
                ])
            }
            if junctions == nil {
                try database.execute("DROP TABLE junctions")
            }
        }
    }

    /// Runs `sql` against an existing file, for variants the options do not make (an extra column, a new table).
    static func execute(_ sql: String, in url: URL) throws {
        let database = try Database(path: url.path(percentEncoded: false), create: false)
        try database.execute(sql)
    }

    // MARK: Writing

    private struct Metadata {
        let schemaVersion: Int
        let layer: String
        let rows: Int
        let region: String
    }

    /// The pipeline's order (`write_sqlite`): schema, rows, metadata, FTS rebuild; then the variant's drop and VACUUM.
    private static func write(
        to url: URL, ddl: String, metadata: Metadata, ftsTables: [String], dropping: String?,
        fill: (Database) throws -> Void
    ) throws {
        let path = url.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw Failure(description: "\(url.lastPathComponent) exists; write each synthetic file to a new path")
        }
        let database = try Database(path: path, create: true)
        try database.execute(ddl)
        try database.execute("BEGIN")
        try fill(database)
        for _ in 0..<metadata.rows {
            try database.insert(into: "metadata", [
                ("schema_version", .integer(Int64(metadata.schemaVersion))), ("layer", .text(metadata.layer)),
                ("region", .text(metadata.region)), ("data_date", .text("2026-10-27")),
                ("osm_timestamp", .text("2026-10-14T20:21:12Z")),
                ("attribution", .text("© OpenStreetMap contributors (ODbL)")),
            ])
        }
        for table in ftsTables {
            try database.execute("INSERT INTO \(table)(\(table)) VALUES ('rebuild')")
        }
        try database.execute("COMMIT")
        if let dropping {
            try drop(dropping, in: database)
        }
        try database.execute("VACUUM")
    }

    /// Leaves out a table (`DROP TABLE`) or a column (the table rebuilt without it, since `DROP COLUMN` refuses
    /// indexed, key and foreign-key columns).
    private static func drop(_ name: String, in database: Database) throws {
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        let table = parts[0]
        let columns = try database.columns(of: table)
        guard !columns.isEmpty else { throw Failure(description: "no table \(table) to drop") }
        guard parts.count == 2 else {
            try database.execute("DROP TABLE \"\(table)\"")
            return
        }
        let column = parts[1]
        guard columns.contains(column) else { throw Failure(description: "no column \(name) to drop") }
        let kept = columns.filter { $0 != column }.map { "\"\($0)\"" }.joined(separator: ", ")
        try database.execute("""
            CREATE TABLE "\(table)__kept" AS SELECT \(kept) FROM "\(table)";
            DROP TABLE "\(table)";
            ALTER TABLE "\(table)__kept" RENAME TO "\(table)";
            """)
    }

    /// A column value; a `nil` payload is NULL.
    private enum Value {
        case integer(Int64?)
        case real(Double?)
        case text(String?)
    }

    /// A read-write connection used only while a file is written.
    private final class Database {
        private let handle: OpaquePointer
        private let path: String

        init(path: String, create: Bool) throws {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0)
            let code = sqlite3_open_v2(path, &handle, flags, nil)
            guard code == SQLITE_OK, let handle else {
                sqlite3_close_v2(handle)
                throw Failure(description: "cannot open \(path): SQLite result code \(code)")
            }
            self.handle = handle
            self.path = path
        }

        deinit { sqlite3_close_v2(handle) }

        func execute(_ sql: String) throws {
            var message: UnsafeMutablePointer<CChar>?
            let code = sqlite3_exec(handle, sql, nil, nil, &message)
            defer { sqlite3_free(message) }
            guard code == SQLITE_OK else {
                throw Failure(description: "\(sql.prefix(60))…: \(message.map { String(cString: $0) } ?? "result code \(code)")")
            }
        }

        /// Column names in table order; empty when there is no such table.
        func columns(of table: String) throws -> [String] {
            let statement = try prepare("SELECT name FROM pragma_table_info(?1) ORDER BY cid")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, table, -1, Self.transient)
            var names: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                names.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
            }
            return names
        }

        func insert(into table: String, _ values: [(String, Value)]) throws {
            let columns = values.map { "\"\($0.0)\"" }.joined(separator: ", ")
            let placeholders = values.indices.map { "?\($0 + 1)" }.joined(separator: ", ")
            let statement = try prepare("INSERT INTO \"\(table)\" (\(columns)) VALUES (\(placeholders))")
            defer { sqlite3_finalize(statement) }
            for (offset, (_, value)) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case .integer(let number?): sqlite3_bind_int64(statement, index, number)
                case .real(let number?): sqlite3_bind_double(statement, index, number)
                case .text(let text?): sqlite3_bind_text(statement, index, text, -1, Self.transient)
                case .integer(nil), .real(nil), .text(nil): sqlite3_bind_null(statement, index)
                }
            }
            let code = sqlite3_step(statement)
            guard code == SQLITE_DONE else {
                throw Failure(description: "insert into \(table): \(String(cString: sqlite3_errmsg(handle)))")
            }
        }

        func insertBox(into table: String, id: Int64, _ box: RowBox) throws {
            try insert(into: table, [
                ("id", .integer(id)), ("min_lon", .real(box.minLon)), ("max_lon", .real(box.maxLon)),
                ("min_lat", .real(box.minLat)), ("max_lat", .real(box.maxLat)),
            ])
        }

        private func prepare(_ sql: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                sqlite3_finalize(statement)
                throw Failure(description: "prepare \(sql.prefix(60))…: \(String(cString: sqlite3_errmsg(handle)))")
            }
            return statement
        }

        /// `SQLITE_TRANSIENT`, which Swift does not import: SQLite copies the bound bytes.
        private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
    }
}
