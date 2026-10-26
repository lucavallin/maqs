import Foundation

/// Why a terrain operation could not run. These describe a problem with the caller's input or with an installed file, never with a network request.
public enum TerrainError: Error, Equatable, LocalizedError {
    /// The configuration is unusable; the payload says which part.
    case invalidConfiguration(String)
    /// The file at this URL is a PMTiles archive but not a terrarium elevation archive.
    case notTerrain(URL)
    /// A tile's image could not be decoded as a square terrarium tile.
    case undecodableTile
    /// The requested area is empty, inverted or outside the world.
    case invalidArea
    /// A coordinate or size is outside the accepted bounds; the payload says which.
    case invalidInput(String)

    /// A message for the user that says what to do.
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            "The terrain settings are not valid (\(detail)). Check the configuration passed to the app's terrain setup."
        case .notTerrain:
            "This file is not an elevation archive. Remove the region and install it again."
        case .undecodableTile:
            "An elevation tile is damaged. Remove the region and install it again."
        case .invalidArea:
            "The requested area is empty or outside the map. Choose an area with a positive size inside the world."
        case .invalidInput(let detail):
            "The request is outside what terrain queries accept (\(detail)). Adjust the input and try again."
        }
    }
}
