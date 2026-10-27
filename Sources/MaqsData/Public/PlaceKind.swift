/// What a place is, as the places layer classifies it.
public enum PlaceKind: Sendable, Hashable {
    /// A mountain pass (`mountain_pass=yes`).
    case pass
    /// A summit.
    case peak
    /// A volcano.
    case volcano
    /// A saddle between two summits.
    case saddle
    /// A staffed mountain hut.
    case alpineHut
    /// An unstaffed mountain hut.
    case wildernessHut
    /// An open shelter.
    case shelter
    /// A named village.
    case village
    /// A named hamlet.
    case hamlet
    /// A named isolated dwelling.
    case isolatedDwelling
    /// A kind this version of the package does not know, as the file spells it, so a newer file still reads.
    case other(String)

    /// The kind a file's `kind` column spells.
    init(column: String) {
        switch column {
        case "pass": self = .pass
        case "peak": self = .peak
        case "volcano": self = .volcano
        case "saddle": self = .saddle
        case "alpine_hut": self = .alpineHut
        case "wilderness_hut": self = .wildernessHut
        case "shelter": self = .shelter
        case "village": self = .village
        case "hamlet": self = .hamlet
        case "isolated_dwelling": self = .isolatedDwelling
        default: self = .other(column)
        }
    }

    /// The spelling of the `kind` column.
    var column: String {
        switch self {
        case .pass: "pass"
        case .peak: "peak"
        case .volcano: "volcano"
        case .saddle: "saddle"
        case .alpineHut: "alpine_hut"
        case .wildernessHut: "wilderness_hut"
        case .shelter: "shelter"
        case .village: "village"
        case .hamlet: "hamlet"
        case .isolatedDwelling: "isolated_dwelling"
        case .other(let column): column
        }
    }
}
