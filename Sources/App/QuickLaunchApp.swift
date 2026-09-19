import SwiftUI
import AppKit

@main
struct QuickLaunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        // Quick Launch is a menu-bar app: every window (the launcher panel,
        // Settings, AI Chat) is AppKit-owned and built by `AppDelegate`. The
        // SwiftUI Settings scene duplicated that panel and nothing ever
        // opened it (`showSettingsWindow:` is never sent), so no scene
        // remains; the empty scene keeps the App lifecycle and the delegate
        // adaptor. Settings is opened by `.openSettings` through
        // `AppDelegate.showSettingsPanel`.
    }
}
