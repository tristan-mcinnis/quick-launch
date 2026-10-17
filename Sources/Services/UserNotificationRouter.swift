import Foundation
import UserNotifications

/// The app's one `UNUserNotificationCenter` delegate. It presents answer
/// notices as banners and sends a click on one to the AI Chat window.
@MainActor
final class UserNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UserNotificationRouter()

    /// A click on an answer notice.
    var answerOpen: (() -> Void)?

    /// Become the center's delegate. Called once the app has a bundle.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { self.answerOpen?() }
    }
}
