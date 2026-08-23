import Foundation

/// One System Settings pane the launcher can open directly.
struct SystemSettingsPane: Identifiable, Equatable, Sendable {
    /// Stable launcher identifier, e.g. `"wifi"`.
    let id: String
    /// Display title, e.g. `"Wi-Fi"`.
    let title: String
    /// Space-separated lower-case search words.
    let keywords: String
    /// `x-apple.systempreferences:` URL that opens the pane.
    let url: URL
    /// SF Symbol name for the row icon.
    let systemImage: String
}

/// Static table of macOS System Settings panes (Ventura and later).
///
/// Identifiers come from `System Settings.app/Contents/Resources/Sidebar.plist`
/// and the ExtensionKit bundle ids on macOS 26.5, cross-checked against
/// bvanpeski/SystemPreferences (Ventura list) and the ezone.co.uk 2025 table.
/// Notes on the doubtful ones:
/// - General is `com.apple.systempreferences.GeneralSettings`; there is no
///   `General-Settings.extension` bundle.
/// - Storage is `com.apple.settings.Storage`; there is no
///   `Storage-Settings.extension` bundle.
/// - Extensions keeps the legacy `com.apple.ExtensionsPreferences` id; no
///   `Extensions-Settings.extension` bundle exists on macOS 26.5 (one source).
/// - Screen Saver (`ScreenSaver-Settings.extension`) is confirmed for macOS
///   13 to 15; on macOS 26 the section moved under Wallpaper and the id is
///   not in Sidebar.plist, so it may land on the Wallpaper pane.
/// - VPN (`NESettingsUIExtension`) is in Sidebar.plist on macOS 26.5, but a
///   gist comment reports the URL opens nothing on macOS 26.
/// - Keyboard Shortcuts `?Shortcuts` is reported to open the Modifier Keys
///   sheet on macOS 14.5 (one source).
/// - Privacy sub-panes use `com.apple.settings.PrivacySecurity.extension?Privacy_X`
///   (one 2025 source). The legacy `com.apple.preference.security?Privacy_X`
///   form is confirmed by two sources if this one stops working.
enum SystemSettingsPaneCatalog {
    static let panes: [SystemSettingsPane] = [
        // Connectivity
        pane("wifi", "Wi-Fi", "wifi wireless network internet airport",
             "com.apple.wifi-settings-extension", "wifi"),
        pane("bluetooth", "Bluetooth", "bluetooth wireless devices pairing headphones",
             "com.apple.BluetoothSettings", "dot.radiowaves.left.and.right"),
        pane("network", "Network", "network ethernet dns proxy firewall ip",
             "com.apple.Network-Settings.extension", "network"),
        pane("vpn", "VPN", "vpn tunnel network extension",
             "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", "lock.shield"),
        pane("battery", "Battery", "battery power energy saver health low power mode",
             "com.apple.Battery-Settings.extension", "battery.100percent"),

        // General
        pane("general", "General", "general about settings preferences",
             "com.apple.systempreferences.GeneralSettings", "gearshape"),
        pane("software-update", "Software Update", "software update macos upgrade install",
             "com.apple.Software-Update-Settings.extension", "arrow.down.circle"),
        pane("storage", "Storage", "storage disk space free up manage",
             "com.apple.settings.Storage", "internaldrive"),
        pane("airdrop-handoff", "AirDrop & Handoff", "airdrop handoff continuity universal clipboard",
             "com.apple.AirDrop-Handoff-Settings.extension", "dot.radiowaves.up.forward"),
        pane("login-items", "Login Items", "login items startup launch at login background extensions",
             "com.apple.LoginItems-Settings.extension", "checklist"),
        pane("date-time", "Date & Time", "date time clock timezone time zone ntp",
             "com.apple.Date-Time-Settings.extension", "clock"),
        pane("sharing", "Sharing", "sharing screen sharing file sharing remote login ssh hostname",
             "com.apple.Sharing-Settings.extension", "square.and.arrow.up"),

        // Appearance and system
        pane("appearance", "Appearance", "appearance dark mode light accent color theme",
             "com.apple.Appearance-Settings.extension", "paintpalette"),
        pane("accessibility", "Accessibility", "accessibility voiceover zoom display pointer a11y",
             "com.apple.Accessibility-Settings.extension", "accessibility"),
        pane("control-center", "Control Center", "control center menu bar modules",
             "com.apple.ControlCenter-Settings.extension", "switch.2"),
        pane("siri", "Siri", "siri spotlight apple intelligence assistant voice",
             "com.apple.Siri-Settings.extension", "waveform"),

        // Privacy & Security
        pane("privacy-security", "Privacy & Security", "privacy security permissions filevault lockdown",
             "com.apple.settings.PrivacySecurity.extension", "hand.raised"),
        pane("privacy-accessibility", "Privacy: Accessibility", "privacy accessibility permission control computer",
             "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility", "accessibility.badge.arrow.up.right"),
        pane("privacy-screen-recording", "Privacy: Screen Recording", "privacy screen recording capture system audio",
             "com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture", "record.circle"),
        pane("privacy-full-disk-access", "Privacy: Full Disk Access", "privacy full disk access files fda",
             "com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles", "folder.badge.person.crop"),
        pane("privacy-microphone", "Privacy: Microphone", "privacy microphone audio input permission",
             "com.apple.settings.PrivacySecurity.extension?Privacy_Microphone", "mic"),
        pane("privacy-camera", "Privacy: Camera", "privacy camera webcam permission",
             "com.apple.settings.PrivacySecurity.extension?Privacy_Camera", "camera"),

        // Desktop and display
        pane("desktop-dock", "Desktop & Dock", "desktop dock stage manager mission control hot corners windows",
             "com.apple.Desktop-Settings.extension", "dock.rectangle"),
        pane("displays", "Displays", "displays monitor resolution brightness night shift arrangement",
             "com.apple.Displays-Settings.extension", "display"),
        pane("wallpaper", "Wallpaper", "wallpaper desktop picture background",
             "com.apple.Wallpaper-Settings.extension", "photo"),
        pane("screen-saver", "Screen Saver", "screen saver screensaver",
             "com.apple.ScreenSaver-Settings.extension", "tv"),
        pane("lock-screen", "Lock Screen", "lock screen sleep require password login window",
             "com.apple.Lock-Screen-Settings.extension", "lock"),

        // Users
        pane("touch-id-password", "Touch ID & Password", "touch id password fingerprint apple watch unlock",
             "com.apple.Touch-ID-Settings.extension", "touchid"),
        pane("users-groups", "Users & Groups", "users groups accounts admin guest",
             "com.apple.Users-Groups-Settings.extension", "person.2"),
        pane("internet-accounts", "Internet Accounts", "internet accounts mail calendar contacts google exchange",
             "com.apple.Internet-Accounts-Settings.extension", "at"),
        pane("game-center", "Game Center", "game center games profile",
             "com.apple.Game-Center-Settings.extension", "gamecontroller"),
        pane("wallet-apple-pay", "Wallet & Apple Pay", "wallet apple pay cards payment",
             "com.apple.WalletSettingsExtension", "creditcard"),

        // Input
        pane("keyboard", "Keyboard", "keyboard input sources text replacement dictation function keys",
             "com.apple.Keyboard-Settings.extension", "keyboard"),
        pane("keyboard-shortcuts", "Keyboard Shortcuts", "keyboard shortcuts hotkeys modifier keys",
             "com.apple.Keyboard-Settings.extension?Shortcuts", "command"),
        pane("trackpad", "Trackpad", "trackpad gestures tap to click scroll",
             "com.apple.Trackpad-Settings.extension", "hand.draw"),
        pane("mouse", "Mouse", "mouse pointer tracking speed scroll",
             "com.apple.Mouse-Settings.extension", "computermouse"),
        pane("printers-scanners", "Printers & Scanners", "printers scanners print scan airprint",
             "com.apple.Print-Scan-Settings.extension", "printer"),

        // Sound and attention
        pane("sound", "Sound", "sound output input volume audio speakers alert",
             "com.apple.Sound-Settings.extension", "speaker.wave.2"),
        pane("notifications", "Notifications", "notifications alerts banners badges do not disturb",
             "com.apple.Notifications-Settings.extension", "bell"),
        pane("focus", "Focus", "focus do not disturb dnd modes",
             "com.apple.Focus-Settings.extension", "moon"),
        pane("screen-time", "Screen Time", "screen time app limits downtime usage",
             "com.apple.Screen-Time-Settings.extension", "hourglass"),

        // Apple Account
        pane("apple-account", "Apple Account", "apple account apple id sign in subscriptions",
             "com.apple.systempreferences.AppleIDSettings", "person.crop.circle"),
        pane("icloud", "iCloud", "icloud drive photos sync backup storage plan",
             "com.apple.systempreferences.AppleIDSettings?iCloud", "icloud"),

        // Extensions and passwords
        pane("extensions", "Extensions", "extensions plugins share menu finder quick look",
             "com.apple.ExtensionsPreferences", "puzzlepiece.extension"),
        pane("passwords", "Passwords", "passwords passkeys keychain autofill",
             "com.apple.Passwords-Settings.extension", "key"),
    ]

    /// Builds the `x-apple.systempreferences:` URL for a pane identifier.
    static func url(for identifier: String) -> URL {
        guard let url = URL(string: "x-apple.systempreferences:" + identifier) else {
            preconditionFailure("Invalid System Settings identifier: \(identifier)")
        }
        return url
    }

    private static func pane(
        _ id: String,
        _ title: String,
        _ keywords: String,
        _ identifier: String,
        _ systemImage: String
    ) -> SystemSettingsPane {
        SystemSettingsPane(
            id: id,
            title: title,
            keywords: keywords,
            url: url(for: identifier),
            systemImage: systemImage
        )
    }
}
