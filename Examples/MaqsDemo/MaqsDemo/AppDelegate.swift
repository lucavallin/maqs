import UIKit

/// Hands the background download session's events to `Maqs`, which calls the system's handler once it has them all.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard case .success(let model) = Demo.startup,
              identifier == model.maqs.configuration.backgroundSessionIdentifier
        else {
            // No session of this app has that identifier, so there is nothing to wait for.
            completionHandler()
            return
        }
        // UIKit does not mark the handler Sendable. Maqs calls it once, on the main thread, which is what UIKit asks.
        nonisolated(unsafe) let handler = completionHandler
        model.maqs.handleEventsForBackgroundURLSession(identifier: identifier) { handler() }
    }
}
