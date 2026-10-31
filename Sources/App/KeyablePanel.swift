import AppKit
import Darwin
import SwiftUI
import HouseDesign

// Borderless panel that can still become key — needed so the TextField
// receives keyboard input. Without the override, a .borderless style mask
// prevents the panel from ever becoming the key window.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    weak var composerModel: QuickViewModel?
    /// The live in-app shortcut table. The panel takes ⌘K and the screenshot
    /// keys before the model sees them, so it has to ask the same table the
    /// model and the hints ask; nil (tests, and any panel built without a view
    /// model) falls back to the built-in keys.
    var bindings: (() -> ShortcutBindings)?
    var commandKHandler: (() -> Void)?
    var commandCHandler: (() -> Bool)?
    /// ⌘⇧S opens the capture chooser, ⌘⇧D captures the display under the pointer.
    var captureChooserHandler: (() -> Void)?
    var screenshotHandler: ((ScreenshotKind) -> Void)?
    /// Item shortcuts (⌘↩, ⌘E, ⌃X, ⌘⇧A…). Returns true when consumed.
    var shortcutHandler: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?
    /// ⇧↩ translates the typed text. Returns true when consumed.
    var translateHandler: (() -> Bool)?
    /// ⌫ on an empty field pops a layer. Returns true when consumed.
    var backspaceHandler: (() -> Bool)?
    /// Escape must work even when a SwiftUI TextField's field editor consumes
    /// cancelOperation before the root view sees `.onKeyPress(.escape)`.
    var escapeHandler: (() -> Bool)?
    /// Plain submit, used when a modified Return has no special meaning.
    var returnHandler: (() -> Void)?

    /// Applies the drag limits for the surface on screen. With limits (the
    /// Quick AI surface) the panel is resizable between them; without
    /// (root search, which is measured) it is not resizable at all, and
    /// the frame follows the content alone. Touches the style mask only
    /// when resizability actually changes.
    func applyUserResizeLimits(_ limits: PanelSizing.ResizeLimits?) {
        if let limits {
            if !styleMask.contains(.resizable) { styleMask.insert(.resizable) }
            if minSize != limits.minimum { minSize = limits.minimum }
            if maxSize != limits.maximum { maxSize = limits.maximum }
        } else {
            if styleMask.contains(.resizable) { styleMask.remove(.resizable) }
            // `setFrame(_:display:)` ignores these; clearing them keeps a
            // stale Quick AI minimum from reaching any other resize path.
            if minSize != .zero { minSize = .zero }
            if maxSize != Self.unlimitedSize { maxSize = Self.unlimitedSize }
        }
    }

    /// AppKit's own default `maxSize` (FLT_MAX in both dimensions).
    static let unlimitedSize = CGSize(
        width: CGFloat(Float.greatestFiniteMagnitude),
        height: CGFloat(Float.greatestFiniteMagnitude)
    )

    /// Unmodified keys never reach `performKeyEquivalent`; the field editor
    /// eats Backspace before SwiftUI sees it. `sendEvent` sees everything.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let editor = firstResponder as? NSTextView {
            // Pinyin and other input methods own Return and Escape until the
            // marked text is committed; no launcher action may steal them.
            if editor.hasMarkedText() {
                super.sendEvent(event)
                return
            }
            if let composerModel, QuickAIComposerEditing.handle(event, editor: editor, model: composerModel) {
                return
            }
        }
        if event.type == .keyDown, event.modifierFlags.overlayRelevant.isEmpty {
            switch VirtualKey(event: event) {
            case .escape where escapeHandler?() == true:
                return
            case .delete where backspaceHandler?() == true:
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, let editor = firstResponder as? NSTextView {
            if editor.hasMarkedText(), VirtualKey.isReturn(keyCode: event.keyCode) {
                return super.performKeyEquivalent(with: event)
            }
            if let composerModel, QuickAIComposerEditing.handle(event, editor: editor, model: composerModel) {
                return true
            }
        }
        let modifiers = event.modifierFlags.overlayRelevant
        let shortcuts = bindings?() ?? .defaults
        if event.type == .keyDown,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           modifiers == [.command],
           commandCHandler?() == true {
            return true
        }
        // An accessory app has no Edit menu while the launcher panel is key,
        // so the system never delivers Select All, Copy or Cut to the field
        // editor or to an answer's text view. Route them to the first
        // responder by hand before any shortcut can claim them. Paste and
        // undo go after `super`, so the composer's attachment paste wins.
        if event.type == .keyDown, modifiers == [.command],
           let editor = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a":
                editor.selectAll(nil)
                return true
            case "c":
                editor.copy(nil)
                return true
            case "x" where editor.isEditable:
                editor.cut(nil)
                return true
            default:
                break
            }
        }
        if event.type == .keyDown,
           shortcuts.matches(.commandPalette, keyCode: event.keyCode, modifiers: modifiers) {
            commandKHandler?()
            return true
        }
        if event.type == .keyDown {
            if shortcuts.matches(.attachWindow, keyCode: event.keyCode, modifiers: modifiers),
               let captureChooserHandler {
                captureChooserHandler()
                return true
            }
            if shortcuts.matches(.attachDisplay, keyCode: event.keyCode, modifiers: modifiers),
               let screenshotHandler {
                screenshotHandler(.display)
                return true
            }
        }
        if event.type == .keyDown,
           modifiers == [.shift],
           VirtualKey.isReturn(keyCode: event.keyCode) {
            // ⇧↩ translates when a direction is set; otherwise it submits
            // like a plain Return instead of silently doing nothing.
            if translateHandler?() == true { return true }
            if let returnHandler {
                returnHandler()
                return true
            }
        }
        if event.type == .keyDown,
           !modifiers.isEmpty,
           modifiers != [.shift],
           shortcutHandler?(event.charactersIgnoringModifiers, event.keyCode, modifiers) == true {
            return true
        }
        if super.performKeyEquivalent(with: event) { return true }
        return StandardEditKeys.perform(event, in: self)
    }
}
