import MaqsData

extension PlaceKind {
    /// The kind in words.
    var displayName: String {
        switch self {
        case .pass: "Pass"
        case .peak: "Peak"
        case .volcano: "Volcano"
        case .saddle: "Saddle"
        case .alpineHut: "Alpine hut"
        case .wildernessHut: "Wilderness hut"
        case .shelter: "Shelter"
        case .village: "Village"
        case .hamlet: "Hamlet"
        case .isolatedDwelling: "Isolated dwelling"
        case .other(let kind): kind
        }
    }
}
