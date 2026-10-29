import MaqsData

/// The sheets of the map screen.
enum DemoSheet: Identifiable {
    case regions
    case trailSearch
    case sightLine
    /// A trail's record, opened by a tap on the map.
    case trail(Trail)
    /// A place's record, opened by a tap on the map.
    case place(Place)

    var id: String {
        switch self {
        case .regions: "regions"
        case .trailSearch: "trail-search"
        case .sightLine: "sight-line"
        case .trail(let trail): "trail-\(trail.summary.region)-\(trail.summary.featureID)"
        case .place(let place): "place-\(place.region)-\(place.featureID)"
        }
    }
}
