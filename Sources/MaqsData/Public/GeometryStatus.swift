/// How completely a trail's geometry could be assembled.
public enum GeometryStatus: Sendable, Equatable {
    /// The legs run in order from one end to the other.
    case ordered
    /// The legs are ordered but have gaps between some of them.
    case gaps
    /// The geometry could not be ordered or is missing.
    case incomplete
    /// A status written by a newer data release, as the file states it.
    case other(String)

    init(_ text: String) {
        switch text {
        case "ordered": self = .ordered
        case "gaps": self = .gaps
        case "incomplete": self = .incomplete
        default: self = .other(text)
        }
    }
}
