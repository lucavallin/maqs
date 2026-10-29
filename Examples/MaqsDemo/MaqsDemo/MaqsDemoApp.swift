import SwiftUI

/// The demo: one map screen with a few sheets, using the package's public API and nothing else.
@main
struct MaqsDemoApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            switch Demo.startup {
            case .success(let model):
                MapScreen(model: model)
            case .failure(let error):
                ContentUnavailableView("The demo could not start", systemImage: "exclamationmark.triangle",
                                       description: Text(error.localizedDescription))
            }
        }
    }
}

/// The demo's one model, made on first use: by the scene, or by the app delegate when the system relaunches the app
/// for the download session's events. `Maqs` allows one instance per background session identifier.
@MainActor
enum Demo {
    static let startup = Result<DemoModel, any Error> { try DemoModel() }
}
