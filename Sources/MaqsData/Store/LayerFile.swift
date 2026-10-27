import Foundation

/// The SQLite layers `MaqsData` reads, by their `metadata.layer` value.
enum Layer: String, Sendable {
    case trails, places, curvature

    /// The table whose rows ``LayerFile/rowCount`` counts.
    var mainTable: String {
        switch self {
        case .trails: "trails"
        case .places: "places"
        case .curvature: "segments"
        }
    }

    /// Every table this module reads, in check order, with the columns it selects by name. A virtual table lists no
    /// columns: it only has to exist. The curvature `junctions` table and `segments.junction` column are optional
    /// (files built before them are valid v1 files) and checked apart.
    var requiredTables: [(table: String, columns: [String])] {
        switch self {
        case .trails:
            [
                ("trails", [
                    "id", "source", "source_id", "source_licence", "source_date", "osm_type", "osm_id", "ref", "ref_rei",
                    "name", "difficulty", "difficulty_scheme", "difficulty_value", "network", "operator", "osmc_symbol",
                    "from_name", "to_name", "roundtrip", "survey_date", "website", "length_m", "ascent_m", "descent_m",
                    "min_lon", "min_lat", "max_lon", "max_lat", "geometry", "geometry_status", "secondary_of",
                ]),
                ("trails_fts", []),
                ("trails_rtree", []),
            ]
        case .places:
            [
                ("places", [
                    "id", "osm_type", "osm_id", "kind", "name", "name_it", "name_de", "name_fur", "name_sl", "ele",
                    "wikidata", "lon", "lat", "rank_score",
                ]),
                ("places_rtree", []),
            ]
        case .curvature:
            [
                ("segments", [
                    "id", "osm_way_id", "name", "ref", "highway", "surface", "oneway", "maxspeed", "length_m", "score",
                    "start_node", "end_node", "min_lon", "min_lat", "max_lon", "max_lat", "geometry",
                ]),
                ("corners", [
                    "id", "segment_id", "ordinal", "apex_lon", "apex_lat", "min_radius_m", "direction", "entry_m",
                    "apex_m", "exit_m",
                ]),
                ("segments_rtree", []),
            ]
        }
    }
}

/// One opened and checked layer file. Not `Sendable`: its connection belongs to the reader actor that opened it.
struct LayerFile {
    private static let metadataColumns = ["schema_version", "layer", "region"]
    private static let junctionColumns = ["segment_id", "node", "along_m"]

    let connection: Connection
    /// The file's last path component.
    let fileName: String
    /// `metadata.region`, unique among one reader's files.
    let region: String
    /// The rows of the layer's main table (``Layer/mainTable``).
    let rowCount: Int
    /// Curvature only: the `junctions` table exists.
    let hasJunctions: Bool
    /// Curvature only: the `segments.junction` column exists.
    let hasJunctionColumn: Bool

    /// Opens `url` and checks, in order: the `metadata` table exists, it has exactly one row, its `layer` is
    /// `layer`, its `schema_version` is 1, and every table and column this module reads exists. Unknown tables and
    /// columns are ignored.
    ///
    /// - Throws: ``QueryError/cannotOpen(file:)``, ``QueryError/incompatibleFile(file:missing:)``,
    ///   ``QueryError/corruptData(file:detail:)``, ``QueryError/wrongLayer(file:expected:found:)``,
    ///   ``QueryError/unsupportedSchemaVersion(file:version:)`` or ``QueryError/unreadable(file:)``.
    static func open(_ url: URL, as layer: Layer) throws(QueryError) -> LayerFile {
        let connection = try Connection(url: url)
        let file = connection.fileName
        try require("metadata", columns: metadataColumns, in: connection)
        let metadataRows = try count("metadata", in: connection)
        guard metadataRows == 1 else {
            throw .corruptData(file: file, detail: "metadata has \(metadataRows) rows, not 1")
        }
        let metadata = try connection.prepare("SELECT layer, schema_version, region FROM metadata")
        defer { metadata.reset() }
        guard try metadata.step(), let found = metadata.text(at: 0), !metadata.isNull(at: 1),
              let region = metadata.text(at: 2) else {
            throw .corruptData(file: file, detail: "metadata has a NULL layer, schema_version or region")
        }
        guard found == layer.rawValue else {
            throw .wrongLayer(file: file, expected: layer.rawValue, found: found)
        }
        let version = metadata.int64(at: 1)
        guard version == 1 else {
            throw .unsupportedSchemaVersion(file: file, version: Int(clamping: version))
        }
        for (table, columns) in layer.requiredTables {
            try require(table, columns: columns, in: connection)
        }
        var hasJunctions = false
        var hasJunctionColumn = false
        if layer == .curvature {
            let junctions = try connection.columns(of: "junctions")
            hasJunctions = !junctions.isEmpty
            if hasJunctions, let column = junctionColumns.first(where: { !junctions.contains($0) }) {
                throw .incompatibleFile(file: file, missing: "junctions.\(column)")
            }
            hasJunctionColumn = try connection.columns(of: "segments").contains("junction")
        }
        let rowCount = try count(layer.mainTable, in: connection)
        return LayerFile(connection: connection, fileName: file, region: region, rowCount: rowCount,
                         hasJunctions: hasJunctions, hasJunctionColumn: hasJunctionColumn)
    }

    /// Opens every file or none. Each rejection is logged with the file name and the error case before it is thrown;
    /// each file is logged once the whole set has opened.
    ///
    /// - Throws: what ``open(_:as:)`` throws, and ``QueryError/duplicateRegion(_:)`` when two files hold one region.
    static func openAll(_ urls: [URL], as layer: Layer) throws(QueryError) -> [LayerFile] {
        var files: [LayerFile] = []
        var regions: Set<String> = []
        for url in urls {
            let name = url.lastPathComponent
            let file: LayerFile
            do throws(QueryError) {
                file = try open(url, as: layer)
            } catch {
                logger.error("\(layer.rawValue, privacy: .public) file \(name, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
                throw error
            }
            guard regions.insert(file.region).inserted else {
                let error = QueryError.duplicateRegion(file.region)
                logger.error("\(layer.rawValue, privacy: .public) file \(name, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
                throw error
            }
            files.append(file)
        }
        for file in files {
            logger.info("\(layer.rawValue, privacy: .public) file \(file.fileName, privacy: .public) opened: region \(file.region, privacy: .public), \(file.rowCount, privacy: .public) rows")
        }
        return files
    }

    /// Throws ``QueryError/incompatibleFile(file:missing:)`` naming the table, or `table.column`, that is missing.
    private static func require(_ table: String, columns: [String], in connection: Connection) throws(QueryError) {
        let present = try connection.columns(of: table)
        guard !present.isEmpty else { throw .incompatibleFile(file: connection.fileName, missing: table) }
        if let column = columns.first(where: { !present.contains($0) }) {
            throw .incompatibleFile(file: connection.fileName, missing: "\(table).\(column)")
        }
    }

    /// The rows of `table`, one of this module's own table names.
    private static func count(_ table: String, in connection: Connection) throws(QueryError) -> Int {
        let statement = try connection.prepare("SELECT count(*) FROM \"\(table)\"")
        defer { statement.reset() }
        guard try statement.step() else {
            throw .corruptData(file: connection.fileName, detail: "count(*) of \(table) returned no row")
        }
        return Int(clamping: statement.int64(at: 0))
    }
}
