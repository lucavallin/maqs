import Foundation

/// The demo's one model, made on first use: by the scene, or by the app delegate when the system relaunches the app
/// for the download session's events. `Maqs` allows one instance per background session identifier.
@MainActor
enum Demo {
    static let startup = Result<DemoModel, any Error> { try DemoModel() }
}
