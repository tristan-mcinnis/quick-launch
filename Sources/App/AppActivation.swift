import AppKit

/// Brings Quick Launch to the front for a window opened from the launcher.
///
/// macOS lets an app activate itself only when it is already active. The
/// launcher is a non-activating panel (it keeps the app behind it, so
/// paste-back lands there), so a normal window opened from it (AI Chat,
/// Settings) appeared behind the keyboard: typing still went to the app
/// behind. When a plain request is not enough, this asks LaunchServices to
/// open this app, which the system honours the same way as `open -a`.
@MainActor
enum AppActivation {
    static func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        guard !NSApp.isActive else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration,
            completionHandler: nil
        )
    }
}
