import AppKit

/// The Edit menu's keys for windows that have no Edit menu.
///
/// Quick Launch is an accessory app: while the launcher, the Translator or
/// Settings is key there is no Edit menu, and AppKit delivers ⌘V, ⌘Z and the
/// rest only through menu key equivalents. A text field then ignores Paste.
/// Each such window calls `perform` for a key nothing else claimed, which
/// sends the action down the window's own responder chain, as the menu would.
@MainActor
enum StandardEditKeys {
    static func action(for event: NSEvent) -> Selector? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.overlayRelevant
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("x", [.command]): return #selector(NSText.cut(_:))
        case ("c", [.command]): return #selector(NSText.copy(_:))
        case ("v", [.command]): return #selector(NSText.paste(_:))
        case ("a", [.command]): return #selector(NSText.selectAll(_:))
        case ("z", [.command]): return Selector(("undo:"))
        case ("z", [.command, .shift]): return Selector(("redo:"))
        default: return nil
        }
    }

    /// True when a responder in `window` took the action. The first
    /// responder that implements it is asked first, as the menu asks it: a
    /// read-only answer refuses Cut and Paste, and the key goes unhandled.
    static func perform(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let action = action(for: event) else { return false }
        var responder = window.firstResponder
        while let candidate = responder {
            if candidate.responds(to: action) {
                let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
                if let validator = candidate as? NSMenuItemValidation {
                    guard validator.validateMenuItem(item) else { return false }
                } else if let validator = candidate as? NSUserInterfaceValidations {
                    guard validator.validateUserInterfaceItem(item) else { return false }
                }
                _ = candidate.perform(action, with: nil)
                return true
            }
            responder = candidate.nextResponder
        }
        return false
    }
}

/// A titled panel (Settings) whose fields keep the Edit keys while the app
/// has no Edit menu.
final class StandardEditingPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return StandardEditKeys.perform(event, in: self)
    }
}
