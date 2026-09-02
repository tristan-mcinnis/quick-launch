import Foundation

/// App-wide notifications. Overlay show/hide goes through `OverlayPresenting`
/// instead; these remain for settings and window-management fan-out.
extension Notification.Name {
    static let dismissOverlay = Notification.Name("QuickLaunch.dismissOverlay")
    static let presentOverlay = Notification.Name("QuickLaunch.presentOverlay")
    static let screenAwarenessSettingsChanged = Notification.Name("QuickLaunch.screenAwarenessSettingsChanged")
    static let openTranslator = Notification.Name("QuickLaunch.openTranslator")
    static let translatorSettingsChanged = Notification.Name("QuickLaunch.translatorSettingsChanged")
    static let openTypeToClick = Notification.Name("QuickLaunch.openTypeToClick")
    static let typeToClickSettingsChanged = Notification.Name("QuickLaunch.typeToClickSettingsChanged")
    static let openSettings = Notification.Name("QuickLaunch.openSettings")
    static let hotkeyChanged = Notification.Name("QuickLaunch.hotkeyChanged")
    static let actionHotkeysChanged = Notification.Name("QuickLaunch.actionHotkeysChanged")
    static let launcherItemHotkeysChanged = Notification.Name("QuickLaunch.launcherItemHotkeysChanged")
    static let clipboardHistorySettingsChanged = Notification.Name("QuickLaunch.clipboardHistorySettingsChanged")
    static let providerChanged = Notification.Name("QuickLaunch.providerChanged")
}
