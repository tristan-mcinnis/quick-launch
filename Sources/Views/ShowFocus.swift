import AppKit

/// Puts the caret in the launcher or Quick AI field in the same turn the
/// panel becomes key. `FocusRequest` still runs after it as the fallback: it
/// waits a layout pass, which is long enough for a fast typist to outrun.
enum ShowFocus {
    /// The one editable, visible text field under `root`. SwiftUI does not
    /// carry an accessibility identifier onto the AppKit field, so the field
    /// is found by being alone: the launcher shows one, and Quick AI shows
    /// only its composer. Two candidates (a chooser pane with its own search)
    /// returns nil rather than guessing.
    @MainActor
    static func soleInputField(in root: NSView) -> NSTextField? {
        var found: [NSTextField] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, field.isEditable, !field.isHiddenOrHasHiddenAncestor {
                found.append(field)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found.count == 1 ? found[0] : nil
    }

    /// Whether a text field or field editor already holds the keys. Moving
    /// it would drop the caret, or break an input-method composition.
    @MainActor
    static func textResponderHoldsFocus(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isFieldEditor || text.isEditable }
        return responder is NSTextField
    }

    /// True when the field took first responder here. False leaves focus
    /// untouched for the fallback request.
    @MainActor
    @discardableResult
    static func focusInput(in window: NSWindow) -> Bool {
        guard let content = window.contentView, !textResponderHoldsFocus(in: window),
              let field = soleInputField(in: content) else { return false }
        return window.makeFirstResponder(field)
    }
}
