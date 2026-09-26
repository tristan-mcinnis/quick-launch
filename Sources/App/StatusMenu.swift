import AppKit

/// The menu the status item shows on a right-click. `AppDelegate` builds it
/// fresh on every click from the current settings, so "Open Quick Launch"
/// always shows the hotkey the user set, the moment they change it.
///
/// Order: the two windows first (Quick Launch, then AI Chat), then Settings
/// and Caffeinate; Welcome; the version and GitHub; Quit.
/// Every item carries a `Command` as its tag and sends one action, so the
/// menu can be built and read in a test without the app.
@MainActor
enum StatusMenu {
    enum Command: Int, CaseIterable {
        case openQuickLaunch = 1
        case openAIChat
        case openSettings
        case toggleCaffeinate
        case showWelcome
        case openWebsite
        case quit
    }

    /// What the menu shows that changes while the app runs.
    struct State {
        /// The launcher hotkey, as `QuickSettings` stores it.
        var hotkeyKeyCode: UInt16
        var hotkeyModifiers: UInt
        /// The sleep assertion is held right now.
        var isCaffeinating: Bool
        /// A Caffeinate session is in force, even while the battery has paused
        /// the assertion. Defaults to `isCaffeinating` for a caller that has no
        /// paused state to report.
        var hasCaffeinateSession: Bool
        var version: String

        init(
            settings: QuickSettings,
            isCaffeinating: Bool,
            hasCaffeinateSession: Bool? = nil,
            version: String
        ) {
            hotkeyKeyCode = settings.hotkeyKeyCode
            hotkeyModifiers = settings.hotkeyModifiers
            self.isCaffeinating = isCaffeinating
            self.hasCaffeinateSession = hasCaffeinateSession ?? isCaffeinating
            self.version = version
        }
    }

    static func make(_ state: State, target: AnyObject?, action: Selector?) -> NSMenu {
        let menu = NSMenu()
        // Each item's `isEnabled` is the truth: the version line stays
        // disabled.
        menu.autoenablesItems = false
        @discardableResult
        func add(_ title: String, _ command: Command?, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: command == nil ? nil : action, keyEquivalent: key)
            if let command {
                item.tag = command.rawValue
                item.target = target
            } else {
                item.isEnabled = false
            }
            menu.addItem(item)
            return item
        }

        let open = add("Open Quick Launch", .openQuickLaunch)
        if let key = keyEquivalent(forKeyCode: state.hotkeyKeyCode) {
            open.keyEquivalent = key
            open.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: state.hotkeyModifiers)
                .overlayRelevant
        }
        add("AI Chat", .openAIChat)
        add("Settings…", .openSettings, key: ",")
        let caffeinate = add(caffeinateMenuTitle(state), .toggleCaffeinate)
        caffeinate.state = state.hasCaffeinateSession ? .on : .off

        menu.addItem(.separator())
        add("Show Welcome Again", .showWelcome)

        menu.addItem(.separator())
        add("Quick Launch v\(state.version)", nil)
        add("View Quick Launch on GitHub", .openWebsite)

        menu.addItem(.separator())
        add("Quit Quick Launch", .quit, key: "q")
        return menu
    }

    /// The Caffeinate item names the action, not the state: Caffeinate when no
    /// session is in force, Decaffeinate when one is. A battery-paused session
    /// is still in force and still cancellable, and the title says so.
    static func caffeinateMenuTitle(_ state: State) -> String {
        guard state.hasCaffeinateSession else { return "Caffeinate" }
        return state.isCaffeinating ? "Decaffeinate" : "Decaffeinate (Paused)"
    }

    /// The menu key equivalent for a key code, or nil for a key a menu
    /// cannot draw (the item then shows no key rather than a wrong one).
    static func keyEquivalent(forKeyCode keyCode: UInt16) -> String? {
        func scalar(_ value: Int) -> String? {
            UnicodeScalar(value).map { String(Character($0)) }
        }
        switch keyCode {
        case 49: return " "
        case 36: return "\r"
        case 48: return "\t"
        case 51: return scalar(NSBackspaceCharacter)
        case 53: return scalar(0x1B)
        case 123: return scalar(NSLeftArrowFunctionKey)
        case 124: return scalar(NSRightArrowFunctionKey)
        case 125: return scalar(NSDownArrowFunctionKey)
        case 126: return scalar(NSUpArrowFunctionKey)
        default:
            if let function = functionKeys[keyCode] { return scalar(function) }
            let name = QuickSettings.keyName(for: keyCode)
            guard name.count == 1 else { return nil }
            return name.lowercased()
        }
    }

    /// F1…F12 by key code.
    private static let functionKeys: [UInt16: Int] = [
        122: NSF1FunctionKey, 120: NSF2FunctionKey, 99: NSF3FunctionKey,
        118: NSF4FunctionKey, 96: NSF5FunctionKey, 97: NSF6FunctionKey,
        98: NSF7FunctionKey, 100: NSF8FunctionKey, 101: NSF9FunctionKey,
        109: NSF10FunctionKey, 103: NSF11FunctionKey, 111: NSF12FunctionKey,
    ]
}
