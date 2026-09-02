import Foundation

/// Shows and hides the overlay panel and opens the app's other windows.
/// The view model talks to this instead of posting notifications, so the
/// one AppDelegate implementation is the only place that knows about panels
/// and tests can count calls.
@MainActor
protocol OverlayPresenting: AnyObject {
    func presentOverlay()
    func dismissOverlay()
    func openSettings()
    func openTranslator()
    func openTypeToClick()
}

/// Default presenter: posts the legacy notifications so any observer that has
/// not moved to the protocol keeps working. AppDelegate replaces it at launch.
@MainActor
final class NotificationOverlayPresenter: OverlayPresenting {
    init() {}
    func presentOverlay() { NotificationCenter.default.post(name: .presentOverlay, object: nil) }
    func dismissOverlay() { NotificationCenter.default.post(name: .dismissOverlay, object: nil) }
    func openSettings() { NotificationCenter.default.post(name: .openSettings, object: nil) }
    func openTranslator() { NotificationCenter.default.post(name: .openTranslator, object: nil) }
    func openTypeToClick() { NotificationCenter.default.post(name: .openTypeToClick, object: nil) }
}
