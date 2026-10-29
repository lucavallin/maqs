import MaqsCore

extension PackSummary {
    /// The English name, else any name, else the id.
    var displayName: String {
        if let name = names["en"] ?? names.values.sorted().first { return name }
        return switch id {
        case .region(let id), .base(let id): id
        }
    }
}
