import Foundation

@MainActor
protocol SelectedTextServicing: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    func currentExternalTarget() -> SelectionTarget?
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext?
    /// Whether `target` holds a non-empty selection, read silently: no
    /// permission prompt, no focus change, nothing attached. The capture
    /// chooser's preselect asks this instead of capturing, so opening the
    /// chooser can never raise the Accessibility prompt or take focus from
    /// the app behind.
    func hasSelection(from target: SelectionTarget) -> Bool
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool
    func paste(_ text: String, to target: SelectionTarget) async -> Bool
    /// Activates `target` and presses ⌘V, for images already on the pasteboard.
    func pastePasteboard(to target: SelectionTarget) async -> Bool
    /// The same as `replace`, `paste` and `pastePasteboard`, but telling a
    /// paste skipped because the clipboard changed (the caller must not copy
    /// over the user's newer copy) from any other failure. The defaults map
    /// the Bool methods, so a conformer that only has those still works.
    func replaceOutcome(_ text: String, in context: SelectedTextContext) async -> PasteOutcome
    func pasteOutcome(_ text: String, to target: SelectionTarget) async -> PasteOutcome
    func pastePasteboardOutcome(to target: SelectionTarget) async -> PasteOutcome
    func openAccessibilitySettings()
}

extension SelectedTextServicing {
    func replaceOutcome(_ text: String, in context: SelectedTextContext) async -> PasteOutcome {
        await replace(text, in: context) ? .pasted : .failed
    }

    func pasteOutcome(_ text: String, to target: SelectionTarget) async -> PasteOutcome {
        await paste(text, to: target) ? .pasted : .failed
    }

    func pastePasteboardOutcome(to target: SelectionTarget) async -> PasteOutcome {
        await pastePasteboard(to: target) ? .pasted : .failed
    }

    func pastePasteboard(to target: SelectionTarget) async -> Bool { false }

    /// The shared silent read: `capture` with the permission prompt off.
    /// Test fakes inherit it; override when a test needs a fixed answer.
    func hasSelection(from target: SelectionTarget) -> Bool {
        guard let context = capture(from: target, promptForPermission: false) else { return false }
        return !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
