import AppKit

/// Brings Quick Launch to the front for a window opened from the launcher.
///
/// macOS lets an app activate itself only when it is already active. The
/// launcher is a non-activating panel (it keeps the app behind it, so
/// paste-back lands there), so a normal window opened from it (AI Chat,
/// Settings) appeared behind the keyboard: typing still went to the app
/// behind. When a plain request is not enough, this asks LaunchServices to
/// open this app, which the system honours the same way as `open -a`.
///
/// It also hands the menu bar back as normal windows close
/// (`settleAfterClosing`): the app stays a normal app while any normal
/// window is still up.
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

    /// A normal window is closing: back to a menu-bar app, with no menu bar
    /// of its own (the launcher panel keeps its keys), once no other normal
    /// window is shown. AI Chat and Settings each call this as they close,
    /// so whichever closes last hands the menu bar back; Settings opened
    /// from AI Chat keeps its Edit menu, ⌘Tab, and the Dock while it is up.
    static func settleAfterClosing(_ closing: NSWindow) {
        let others = NSApp.windows.filter { $0 !== closing }.map(WindowPresence.init)
        guard !keepsRegularApp(otherWindows: others) else { return }
        menuBarTask?.cancel()
        menuBarTask = nil
        // The Window menu goes with the menu bar it belonged to; leaving it
        // set would hand AppKit a detached menu to keep populating.
        NSApp.windowsMenu = nil
        NSApp.mainMenu = nil
        NSApp.setActivationPolicy(.accessory)
    }

    /// Whether the app stays a normal app (Dock, ⌘Tab, menu bar) while
    /// these other windows are open.
    static func keepsRegularApp(otherWindows: [WindowPresence]) -> Bool {
        otherWindows.contains { $0.isNormal && $0.isShown }
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

/// One of the app's windows, as the menu-bar decision sees it.
struct WindowPresence: Equatable, Sendable {
    /// A titled window: AI Chat, Settings, Welcome, or a system panel such
    /// as About. The launcher, the Translator, and Type to Click are
    /// borderless panels and never hold the menu bar.
    var isNormal: Bool
    /// On screen, or minimised to the Dock (its Dock tile needs the app to
    /// stay a normal app).
    var isShown: Bool

    init(isNormal: Bool, isShown: Bool) {
        self.isNormal = isNormal
        self.isShown = isShown
    }

    @MainActor
    init(_ window: NSWindow) {
        isNormal = window.styleMask.contains(.titled)
        isShown = window.isVisible || window.isMiniaturized
    }
}
