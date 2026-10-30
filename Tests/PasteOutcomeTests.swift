import Testing
@testable import QuickLaunch

/// A skipped paste (the clipboard changed under us) must leave the user's
/// newer copy alone: no copy-instead fallback, a clear message.
@MainActor
@Suite("Paste outcome")
struct PasteOutcomeTests {
    private static let skipped =
        "Clipboard changed, so the paste was skipped. The answer is still in Quick Launch."

    @Test func plainPasteLeavesTheClipboardAloneWhenItChanged() async {
        let selection = OutcomeSelection(outcome: .clipboardChanged)
        let pasteboard = FakePasteboard(string: "user's newer copy")
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.output = "the answer"

        #expect(await vm.pasteOutputToPreviousApp() == false)
        #expect(pasteboard.writeCount == 0)
        #expect(pasteboard.string == "user's newer copy")
        #expect(vm.errorMessage == Self.skipped)
        #expect(!vm.justCopied)
    }

    @Test func formattedPlainPathLeavesTheClipboardAloneWhenItChanged() async {
        let selection = OutcomeSelection(outcome: .clipboardChanged)
        let pasteboard = FakePasteboard(string: "user's newer copy")
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.output = "plain answer with no structure"

        #expect(await vm.pasteFormattedOutputToPreviousApp() == false)
        #expect(pasteboard.writeCount == 0)
        #expect(vm.errorMessage == Self.skipped)
    }

    @Test func plainPasteFailureStillCopiesInstead() async {
        let selection = OutcomeSelection(outcome: .failed)
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.output = "the answer"

        #expect(await vm.pasteOutputToPreviousApp() == false)
        #expect(pasteboard.string == "the answer")
        #expect(vm.errorMessage == "Could not paste into Editor. The result was copied instead.")
    }

    @Test func translatorLeavesTheClipboardAloneWhenItChanged() async {
        let selection = OutcomeSelection(outcome: .clipboardChanged)
        let pasteboard = FakePasteboard(string: "user's newer copy")
        let model = TranslatorModel(
            lastTarget: .english, selectedTextService: selection, pasteboard: pasteboard
        )
        model.prepare(target: selection.target, selectedText: nil)
        model.translation = "Hello"

        #expect(await model.pasteBack() == false)
        #expect(pasteboard.writeCount == 0)
        #expect(model.message == "Clipboard changed, so the paste was skipped. The translation is still here.")
    }
}

@MainActor
private final class OutcomeSelection: SelectedTextServicing {
    let target = SelectionTarget(processIdentifier: 321, applicationName: "Editor")
    let outcome: PasteOutcome
    init(outcome: PasteOutcome) { self.outcome = outcome }

    var isAccessibilityTrusted: Bool { true }
    func currentExternalTarget() -> SelectionTarget? { target }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? { nil }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { outcome == .pasted }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { outcome == .pasted }
    func pasteOutcome(_ text: String, to target: SelectionTarget) async -> PasteOutcome { outcome }
    func pastePasteboardOutcome(to target: SelectionTarget) async -> PasteOutcome { outcome }
    func openAccessibilitySettings() {}
}
