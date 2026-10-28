/// `MaqsUI` is the SwiftUI map of the Maqs package, drawn by MapLibre Native on iOS.
///
/// It is the only module that imports MapLibre. It builds its style at runtime from the style the app supplies,
/// the online sources in `sources.json` and the local PMTiles of installed regions, and it shows the credits of
/// the sources in use. MapLibre's binary is iOS-only, so every file that needs it sits inside
/// `#if canImport(MapLibre)`; on macOS the module compiles to this file and the logger.
enum MaqsUI {
    /// The module's name, read by the platform-independent package test.
    static let moduleName = "MaqsUI"
}
