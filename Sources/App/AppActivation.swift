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
    /// The menu-bar fix-up after the app turns into a normal app.
    private static var menuBarTask: Task<Void, Never>?

    /// Turns the menu-bar app into a normal app (Dock, ⌘Tab, menu bar) and
    /// brings `window` to the front.
    ///
    /// macOS keeps showing the previous app's menu bar after an accessory
    /// app becomes regular, until the app is activated a second time. Once
    /// this app is active, activation goes to the Dock for a moment and
    /// comes straight back, which hands the menu bar over.
    static func becomeRegularApp(showing window: NSWindow) {
        let wasRegular = NSApp.activationPolicy() == .regular
        if !wasRegular { NSApp.setActivationPolicy(.regular) }
        bringToFront(window)
        guard !wasRegular else { return }
        menuBarTask?.cancel()
        menuBarTask = Task { @MainActor [weak window] in
            // Wait for the first activation to land (up to about a second).
            for _ in 0..<50 where !NSApp.isActive {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !Task.isCancelled, NSApp.isActive, let window, window.isVisible else { return }
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .first?.activate()
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, window.isVisible else { return }
            bringToFront(window)
        }
    }

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
