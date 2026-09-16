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
    /// Opens Settings at one searched destination: the pane row, then the
    /// scroll and highlight for its group. The default reveals through the
    /// notification and opens the window; a presenter that owns the window
    /// (the app delegate) passes the destination in at creation instead.
    func openSettings(destination: SettingsDestination)
    func openTranslator()
    /// Opens the Translator with the launch-time selected text handed over
    /// explicitly, so it survives the overlay closing (which clears the
    /// launch-scoped selection).
    func openTranslator(retainedSelection: String?)
    func openTypeToClick()
    /// A capture that hid the view's window for a moment (Selected Area)
    /// succeeded: the window comes back, as `recoverFromExternalActionFailure`
    /// brings it back after a failure. The AI Chat window's controller shows
    /// its window.
    func restoreAfterExternalAction()
}

extension OverlayPresenting {
    /// Default: present the overlay again, which is what the launcher panel
    /// and the AI Chat window (its `presentOverlay` shows the window) both
    /// need after a capture.
    func restoreAfterExternalAction() {
        presentOverlay()
    }

    /// Default: open the window, then ask it to reveal the group. The app
    /// delegate overrides this so a not-yet-created window is born on the
    /// destination instead of missing the reveal notification.
    func openSettings(destination: SettingsDestination) {
        openSettings()
        NotificationCenter.default.post(
            name: .revealSettingsDestination,
            object: destination
        )
    }

    /// Default: ignore the handed-over text and forward to `openTranslator()`.
    /// The app presenter overrides it to seed the Translator's retained
    /// selection.
    func openTranslator(retainedSelection: String?) {
        openTranslator()
    }
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
