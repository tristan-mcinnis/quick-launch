import Foundation

@MainActor
protocol SelectedTextServicing: AnyObject {
    var isAccessibilityTrusted: Bool { get }
    func currentExternalTarget() -> SelectionTarget?
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext?
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool
    func paste(_ text: String, to target: SelectionTarget) async -> Bool
    /// Activates `target` and presses ⌘V, for images already on the pasteboard.
    func pastePasteboard(to target: SelectionTarget) async -> Bool
    func openAccessibilitySettings()
}

extension SelectedTextServicing {
    func pastePasteboard(to target: SelectionTarget) async -> Bool { false }
}
