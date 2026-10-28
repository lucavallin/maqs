import Foundation

/// What can go wrong when the map prepares its style or reads its bundled resources.
public enum MapError: Error, Equatable, LocalizedError {
    /// The style JSON is not usable. The associated value says why, for example which key is missing.
    case invalidStyle(String)
    /// MapLibre reported that the assembled style failed to load.
    case styleFailedToLoad
    /// The `Maqs` instance the map was given is not configured with the basemap layer, which every map draws.
    case basemapNotConfigured
    /// A file bundled with the package is absent. The associated value is the file's last path component.
    case resourcesMissing(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStyle(let reason):
            "The map style is not valid: \(reason). Check the style JSON the app passes in."
        case .styleFailedToLoad:
            "The map style failed to load. Check the style JSON and that the sources it names are reachable, then try again."
        case .basemapNotConfigured:
            "The map needs the basemap layer. Add .basemap to the layers of the MaqsConfiguration the app creates Maqs with."
        case .resourcesMissing(let name):
            "The map resource \(name) is missing from the app bundle. Rebuild the app and make sure the Maqs package resources are included."
        }
    }
}
