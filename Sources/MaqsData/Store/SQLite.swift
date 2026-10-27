import Foundation
import SQLite3

/// A read-only SQLite connection to one layer file, opened as an immutable URI: no locks, no journal, no `-wal` or
/// `-shm` file.
///
/// Apple's libsqlite3 invalidates the connection's descriptor when the file is unlinked or renamed while open: reads
/// that miss SQLite's page cache then fail with `SQLITE_IOERR_VNODE`, which is ``QueryError/unreadable(file:)``.
///
/// Not `Sendable`: one reader actor owns each connection and runs every call to completion, so a connection and its
/// statements are never used from two threads.
final class Connection {
    /// The file's last path component, the only name an error or a log line carries.
    let fileName: String
    private let handle: OpaquePointer
    private var statements: [String: Statement] = [:]

    /// Opens `url` with `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI` as `file:<percent-encoded path>?immutable=1`.
    ///
    /// SQLite reads nothing yet: a file that is not a database fails at the first statement, as ``QueryError/corruptData(file:detail:)``.
    /// - Throws: ``QueryError/cannotOpen(file:)`` when the URL is not a local file or SQLite cannot open it.
    init(url: URL) throws(QueryError) {
        let fileName = url.lastPathComponent
        guard url.isFileURL, let uri = Self.immutableURI(for: url) else { throw .cannotOpen(file: fileName) }
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard code == SQLITE_OK, let handle else {
            // SQLite hands back a handle even when the open fails; it must still be closed.
            sqlite3_close_v2(handle)
            throw .cannotOpen(file: fileName)
        }
        // Extended codes tell a short read (a truncated file) from other I/O failures.
        sqlite3_extended_result_codes(handle, 1)
        self.handle = handle
        self.fileName = fileName
    }

    deinit {
        // Statements finalize themselves when released; close_v2 waits for any still held elsewhere.
        statements.removeAll()
        sqlite3_close_v2(handle)
    }

    /// The prepared statement for `sql`, cached by its text and reset with its bindings cleared on every call.
    ///
    /// Preparing the same text again resets the statement, so finish stepping one before preparing its text again.
    func prepare(_ sql: String) throws(QueryError) -> Statement {
        if let cached = statements[sql] {
            cached.reset()
            return cached
        }
        var pointer: OpaquePointer?
        let code = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &pointer, nil)
        guard code == SQLITE_OK, let pointer else {
            sqlite3_finalize(pointer)
            // SQL with no statement in it prepares to nothing with SQLITE_OK; that is a misuse, not a damaged file.
            throw .sqlite(code == SQLITE_OK ? SQLITE_MISUSE : code, file: fileName)
        }
        let statement = Statement(handle: pointer, fileName: fileName)
        statements[sql] = statement
        return statement
    }

    /// The column names of `table` (`PRAGMA table_info`); empty when the file has no such table.
    func columns(of table: String) throws(QueryError) -> Set<String> {
        let statement = try prepare("SELECT name FROM pragma_table_info(?1)")
        defer { statement.reset() }
        try statement.bind(table, at: 1)
        var names: Set<String> = []
        while try statement.step() {
            if let name = statement.text(at: 0) { names.insert(name) }
        }
        return names
    }

    /// `file:` with the path percent-encoded by `URLComponents`, so a space, `#`, `?` or `%` in a directory or
    /// file name stays part of the path instead of starting SQLite's query or fragment.
    private static func immutableURI(for url: URL) -> String? {
        var components = URLComponents()
        components.scheme = "file"
        components.host = ""
        components.path = url.path(percentEncoded: false)
        components.query = "immutable=1"
        return components.string
    }
}

/// One prepared statement of a ``Connection``. Bind indexes start at 1 and column indexes at 0, as in SQLite.
final class Statement {
    private let handle: OpaquePointer
    private let fileName: String

    fileprivate init(handle: OpaquePointer, fileName: String) {
        self.handle = handle
        self.fileName = fileName
    }

    deinit { sqlite3_finalize(handle) }

    /// Binds an integer, or NULL when `value` is nil.
    func bind(_ value: Int64?, at index: Int32) throws(QueryError) {
        try check(value.map { sqlite3_bind_int64(handle, index, $0) } ?? sqlite3_bind_null(handle, index))
    }

    /// Binds a real, or NULL when `value` is nil.
    func bind(_ value: Double?, at index: Int32) throws(QueryError) {
        try check(value.map { sqlite3_bind_double(handle, index, $0) } ?? sqlite3_bind_null(handle, index))
    }

    /// Binds UTF-8 text, copied by SQLite, or NULL when `value` is nil.
    func bind(_ value: String?, at index: Int32) throws(QueryError) {
        guard let value else { return try check(sqlite3_bind_null(handle, index)) }
        let code = value.utf8CString.withUnsafeBufferPointer { buffer in
            // The count includes the terminating NUL, which SQLite must not store.
            sqlite3_bind_text64(handle, index, buffer.baseAddress, UInt64(buffer.count - 1), Self.transient, UInt8(SQLITE_UTF8))
        }
        try check(code)
    }

    /// Advances to the next row: `true` when there is one, `false` when the statement is done.
    func step() throws(QueryError) -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: true
        case SQLITE_DONE: false
        case let code: throw .sqlite(code, file: fileName)
        }
    }

    /// The column as an integer; 0 for NULL.
    func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(handle, column)
    }

    /// The column as a real; 0 for NULL.
    func double(at column: Int32) -> Double {
        sqlite3_column_double(handle, column)
    }

    /// The column as text, or nil for NULL. Bytes that are not UTF-8 become replacement characters.
    func text(at column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(handle, column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    /// Whether the column is NULL.
    func isNull(at column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    /// Rewinds the statement and clears its bindings, ending its read.
    func reset() {
        // reset repeats the code of a failed step, which step already threw; there is nothing new to report.
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    private func check(_ code: Int32) throws(QueryError) {
        guard code == SQLITE_OK else { throw .sqlite(code, file: fileName) }
    }

    /// `SQLITE_TRANSIENT`, which Swift does not import: SQLite copies the bound bytes before the call returns.
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
}
