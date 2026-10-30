import Foundation
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

    @Test func plainPasteFailureRecoversTheOverlay() async {
        let selection = OutcomeSelection(outcome: .failed)
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: FakePasteboard())
        vm.rememberSelectionTarget(selection.target)
        vm.output = "the answer"
        var recovered = 0
        vm.recoverFromExternalActionFailure = { recovered += 1 }

        #expect(await vm.pasteOutputToPreviousApp() == false)
        #expect(recovered == 1)
    }

    @Test func plainPasteSkipRecoversTheOverlay() async {
        let selection = OutcomeSelection(outcome: .clipboardChanged)
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: FakePasteboard())
        vm.rememberSelectionTarget(selection.target)
        vm.output = "the answer"
        var recovered = 0
        vm.recoverFromExternalActionFailure = { recovered += 1 }

        #expect(await vm.pasteOutputToPreviousApp() == false)
        #expect(recovered == 1)
    }

    @Test func formattedPlainPathRecoversTheOverlay() async {
        for outcome in [PasteOutcome.clipboardChanged, .failed] {
            let selection = OutcomeSelection(outcome: outcome)
            let vm = QuickViewModel(selectedTextService: selection, pasteboard: FakePasteboard())
            vm.rememberSelectionTarget(selection.target)
            vm.output = "plain answer with no structure"
            var recovered = 0
            vm.recoverFromExternalActionFailure = { recovered += 1 }

            #expect(await vm.pasteFormattedOutputToPreviousApp() == false)
            #expect(recovered == 1)
        }
    }

    @Test func richFormattedPathLeavesTheClipboardAloneWhenItChanged() async {
        let selection = OutcomeSelection(outcome: .clipboardChanged)
        let pasteboard = FakePasteboard(string: "user's newer copy")
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.output = "# Title\n\n- one\n- two\n\n**bold** text"
        var recovered = 0
        vm.recoverFromExternalActionFailure = { recovered += 1 }

        #expect(await vm.pasteFormattedOutputToPreviousApp() == false)
        // The one write is the rich publish before the keystroke; no fallback follows it.
        #expect(pasteboard.formattedWriteCount == 1)
        #expect(pasteboard.writeCount == 1)
        #expect(vm.errorMessage == Self.skipped)
        #expect(!vm.justCopied)
        #expect(recovered == 1)
    }

    @Test func richFormattedPathFailureRecoversAndCopiesInstead() async {
        let selection = OutcomeSelection(outcome: .failed)
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.output = "# Title\n\n- one\n- two\n\n**bold** text"
        var recovered = 0
        vm.recoverFromExternalActionFailure = { recovered += 1 }

        #expect(await vm.pasteFormattedOutputToPreviousApp() == false)
        #expect(pasteboard.writeCount == 2)
        #expect(recovered == 1)
    }

    @Test func replaceSelectionLeavesTheClipboardAloneWhenItChanged() async {
        let selection = OutcomeSelection(outcome: .clipboardChanged, selectedText: "rough")
        let pasteboard = FakePasteboard(string: "user's newer copy")
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        let context = SelectedTextContext(target: selection.target, text: "rough")

        let replaced = await vm.writeBackValidated(output: "polished", in: context, service: selection)
        #expect(replaced == false)
        #expect(pasteboard.writeCount == 0)
        #expect(pasteboard.string == "user's newer copy")
        #expect(vm.errorMessage == Self.skipped)
        #expect(!vm.justCopied)
    }

    @Test func imagePasteLeavesTheClipboardAloneWhenItChanged() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-outcome-\(UUID().uuidString).png")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let selection = OutcomeSelection(outcome: .clipboardChanged)
        let pasteboard = FakePasteboard(string: "user's newer copy")
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)

        #expect(await vm.pasteImageFile(file) == false)
        #expect(pasteboard.writeCount == 0)
        #expect(pasteboard.string == "user's newer copy")
        #expect(vm.errorMessage == Self.skipped)
        #expect(!vm.justCopied)
    }

    @Test func launcherItemPasteLeavesTheClipboardAloneWhenItChanged() async {
        let selection = OutcomeSelection(outcome: .clipboardChanged)
        let pasteboard = FakePasteboard(string: "user's newer copy")
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        let item = LauncherCatalogItem(
            kind: .snippet, itemID: "s", title: "S", detail: "Test", value: "Hello there"
        )

        #expect(await vm.pasteLauncherItem(item) == false)
        #expect(pasteboard.writeCount == 0)
        #expect(pasteboard.string == "user's newer copy")
        #expect(vm.errorMessage == Self.skipped)
    }

    @Test func clipboardEntryPlainPasteLeavesTheClipboardAloneWhenItChanged() async {
        let selection = OutcomeSelection(outcome: .clipboardChanged)
        let pasteboard = FakePasteboard(string: "user's newer copy")
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        let item = LauncherCatalogItem(
            kind: .clipboard, itemID: "c", title: "C", detail: "Test", value: "From history"
        )

        #expect(await vm.pasteClipboardEntryAsPlainText(item) == false)
        // The single write is the transient publish before the keystroke.
        #expect(pasteboard.writeCount == 1)
        #expect(pasteboard.transientWriteCount == 1)
        #expect(vm.errorMessage == Self.skipped)
        #expect(!vm.justCopied)
    }

    private static func richItem() -> LauncherCatalogItem {
        var item = LauncherCatalogItem(
            kind: .clipboard, itemID: "rich", title: "Rich", detail: "Test", value: "Pic"
        )
        item.clipboardPayload = ClipboardPayload(
            kind: .image,
            text: "Pic",
            items: [[ClipboardRawItem(type: "public.png", data: Data([1, 2, 3]))]]
        )
        return item
    }

    @Test func copyingARichItemWritesTheInjectedPasteboard() async {
        let pasteboard = FakePasteboard(string: "user's copy")
        let vm = QuickViewModel(selectedTextService: OutcomeSelection(outcome: .pasted), pasteboard: pasteboard)
        let item = Self.richItem()

        #expect(await vm.copyLauncherItem(item))
        #expect(pasteboard.payloadWriteCount == 1)
        #expect(pasteboard.lastPayload == item.clipboardPayload)
    }

    @Test func pastingARichItemWritesTheInjectedPasteboardBeforeTheGuardBaseline() async {
        let selection = OutcomeSelection(outcome: .pasted)
        let pasteboard = FakePasteboard()
        selection.onPastePasteboard = { selection.payloadWritesAtKeystroke = pasteboard.payloadWriteCount }
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)

        #expect(await vm.pasteLauncherItem(Self.richItem()))
        #expect(pasteboard.payloadWriteCount == 1)
        // The write lands before the service takes its change-count baseline.
        #expect(selection.payloadWritesAtKeystroke == 1)
    }

    @Test func richRestorePasteLeavesTheClipboardAloneWhenItChanged() async {
        let selection = OutcomeSelection(outcome: .clipboardChanged)
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        var recovered = 0
        vm.recoverFromExternalActionFailure = { recovered += 1 }

        #expect(await vm.pasteLauncherItem(Self.richItem()) == false)
        // Only the restore before the keystroke; no copy-instead after it.
        #expect(pasteboard.payloadWriteCount == 1)
        #expect(pasteboard.writeCount == 1)
        #expect(vm.errorMessage == Self.skipped)
        #expect(!vm.justCopied)
        #expect(recovered == 1)
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
    let selectedText: String?
    var onPastePasteboard: (() -> Void)?
    var payloadWritesAtKeystroke = -1
    init(outcome: PasteOutcome, selectedText: String? = nil) {
        self.outcome = outcome
        self.selectedText = selectedText
    }

    var isAccessibilityTrusted: Bool { true }
    func currentExternalTarget() -> SelectionTarget? { target }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        selectedText.map { SelectedTextContext(target: target, text: $0) }
    }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { outcome == .pasted }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { outcome == .pasted }
    func replaceOutcome(_ text: String, in context: SelectedTextContext) async -> PasteOutcome { outcome }
    func pasteOutcome(_ text: String, to target: SelectionTarget) async -> PasteOutcome { outcome }
    func pastePasteboardOutcome(to target: SelectionTarget) async -> PasteOutcome {
        onPastePasteboard?()
        return outcome
    }
    func openAccessibilitySettings() {}
}
