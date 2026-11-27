import SQLite3

/// The rule every full-text search shares: what the user typed becomes an FTS5 expression with no syntax of its own.
enum FullText {
    /// The words of `text`, split on whitespace; none for blank text.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Each word an FTS5 string (inner `"` doubled), the last a prefix, ANDed by juxtaposition: no user text reaches
    /// FTS5 as syntax.
    static func matchExpression(_ words: [String]) -> String {
        words.enumerated().map { index, word in
            let quoted = "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return index == words.count - 1 ? quoted + "*" : quoted
        }.joined(separator: " ")
    }

    /// Whether `statement` last failed because FTS5 rejected the expression (`SQLITE_ERROR`), which is no match; a
    /// damaged or unreadable file fails with another code and still throws.
    static func rejected(_ statement: Statement) -> Bool {
        statement.failureCode & 0xFF == SQLITE_ERROR
    }
}
