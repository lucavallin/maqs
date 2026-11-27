import Foundation
import SQLite3

/// The rule every full-text search shares: what the user typed becomes an FTS5 expression with no syntax of its own.
enum FullText {
    /// The words of `text`, split on whitespace; none for blank text.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Each word an FTS5 string (inner `"` doubled), the last a prefix, ANDed by juxtaposition: no user text reaches
    /// FTS5 as syntax. A word with `ss` or `ß` is an OR of both spellings (``spellings(of:)``).
    static func matchExpression(_ words: [String]) -> String {
        words.enumerated().map { index, word in
            let star = index == words.count - 1 ? "*" : ""
            let terms = spellings(of: word).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + star }
            return terms.count == 1 ? terms[0] : "(" + terms.joined(separator: " OR ") + ")"
        }.joined(separator: " ")
    }

    /// The word as typed and, when it holds `ß` or `ss`, with every one swapped for the other. The tokenizer folds case
    /// and accents but keeps `ß`, which has no decomposition, so "grossglockner" would never find Großglockner; German
    /// writes either, and Italian and English write `ss`.
    static func spellings(of word: String) -> [String] {
        var spellings = [word]
        if word.contains("ß") {
            spellings.append(word.replacingOccurrences(of: "ß", with: "ss"))
        } else if word.range(of: "ss", options: .caseInsensitive) != nil {
            spellings.append(word.replacingOccurrences(of: "ss", with: "ß", options: .caseInsensitive))
        }
        return spellings
    }

    /// Whether `statement` last failed because FTS5 rejected the expression (`SQLITE_ERROR`), which is no match; a
    /// damaged or unreadable file fails with another code and still throws.
    static func rejected(_ statement: Statement) -> Bool {
        statement.failureCode & 0xFF == SQLITE_ERROR
    }
}
