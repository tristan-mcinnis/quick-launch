import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// `⇧⌘S`: the compact capture-only chooser (Selected Text, Focused Window,
/// Selected Area, Entire Screen). `⇧⌘A` stays the full Add Context menu and
/// `⇧⌘D` stays the direct display capture.
@Suite("Capture chooser", .serialized)
@MainActor
struct CaptureChooserTests {
    private static let safari = SelectionTarget(processIdentifier: 42, applicationName: "Safari")

    private func settings() -> QuickSettings {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        return settings
    }

    // MARK: - Rows and order

    @Test func theChooserListsTheFourCapturesSelectedTextFirst() {
        #expect(AddContextEntry.captureChooserOrder
            == [.selectedText, .focusedWindow, .selectedArea, .entireScreen])
        #expect(AddContextEntry.captureChooser(offering: AddContextEntry.allCases)
            == [.selectedText, .focusedWindow, .selectedArea, .entireScreen])
        // A surface that cannot run one leaves it out, order kept.
        #expect(AddContextEntry.captureChooser(offering: [.entireScreen, .selectedArea])
            == [.selectedArea, .entireScreen])

        let vm = QuickViewModel(settings: settings(), service: MockQuickService())
        vm.rememberSelectionTarget(Self.safari)
        vm.openCaptureChooser()
        #expect(vm.isCaptureChooserPresented)
        #expect(vm.topLayer == .captureChooser)
        #expect(vm.captureChooserOptions == [.selectedText, .focusedWindow, .selectedArea, .entireScreen])
    }

    @Test func theChooserNeverOffersFilesLinksOrFinderSelection() {
        let vm = QuickViewModel(settings: settings(), service: MockQuickService())
        let finder = SelectionTarget(processIdentifier: 7, applicationName: QuickViewModel.finderApplicationName)
        vm.rememberSelectionTarget(finder)
        vm.openCaptureChooser()
        // Add Context would add Finder Selection and both of its first two
        // rows here; the chooser lists captures only.
        #expect(vm.addContextRows.contains(.file))
        #expect(vm.addContextRows.contains(.link))
        #expect(vm.addContextRows.contains(.finderSelection))
        #expect(vm.captureChooserOptions == [.selectedText, .focusedWindow, .selectedArea, .entireScreen])
    }

    // MARK: - Preselect

    @Test func selectedTextIsPreselectedWhenTheAppBehindHoldsSome() {
        let selection = ChooserSelectedTextService(text: "A passage worth asking about")
        let vm = QuickViewModel(
            settings: settings(),
            service: MockQuickService(),
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(Self.safari)
        vm.openCaptureChooser()
        #expect(vm.captureChooserHasSelection)
        #expect(vm.preferredCaptureEntry == .selectedText)
        #expect(vm.captureChooserOptions[vm.captureChooserIndex] == .selectedText)
    }

    @Test func focusedWindowIsPreselectedWhenNothingIsSelected() {
        let selection = ChooserSelectedTextService(text: "   \n ")
        let vm = QuickViewModel(
            settings: settings(),
            service: MockQuickService(),
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(Self.safari)
        vm.openCaptureChooser()
        #expect(!vm.captureChooserHasSelection)
        #expect(vm.preferredCaptureEntry == .focusedWindow)
        #expect(vm.captureChooserOptions[vm.captureChooserIndex] == .focusedWindow)
    }

    /// The launch snapshot already holds the selection, so the preselect
    /// answers it without a second Accessibility read.
    @Test func theLaunchSnapshotAnswersWithoutReadingAgain() {
        let selection = ChooserSelectedTextService(text: "unused")
        let vm = QuickViewModel(
            settings: settings(),
            service: MockQuickService(),
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(Self.safari)
        vm.launchSelection = QuickViewModel.LaunchSelection(text: "Launch snapshot", appName: "Safari")
        vm.openCaptureChooser()
        #expect(vm.captureChooserHasSelection)
        #expect(selection.silentReads == 0)
    }

    @Test func availableSelectionIsReadSilentlyOncePerOpen() {
        let selection = ChooserSelectedTextService(text: "A passage")
        let vm = QuickViewModel(
            settings: settings(),
            service: MockQuickService(),
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(Self.safari)
        vm.openCaptureChooser()
        #expect(selection.silentReads == 1)
        #expect(selection.promptingCaptures == 0, "preselecting must never raise the permission prompt")
    }

    // MARK: - Return attaches the highlighted choice

    @Test func returnAttachesExactlyTheHighlightedCapture() async {
        let capture = ChooserScreenshotService()
        let selection = ChooserSelectedTextService(text: "")
        let vm = QuickViewModel(
            settings: settings(),
            service: MockQuickService(),
            selectedTextService: selection,
            screenshotService: capture
        )
        vm.rememberSelectionTarget(Self.safari)
        vm.openCaptureChooser()
        // Nothing selected: Focused Window is the row, at index 1 of four.
        #expect(vm.captureChooserOptions[vm.captureChooserIndex] == .focusedWindow)

        vm.moveCaptureChooserSelection(1)
        #expect(vm.captureChooserOptions[vm.captureChooserIndex] == .selectedArea)
        vm.moveCaptureChooserSelection(1)
        #expect(vm.captureChooserOptions[vm.captureChooserIndex] == .entireScreen)

        await vm.runCaptureChooserSelection()
        #expect(capture.captured.map(\.kind) == [.display])
        #expect(vm.pendingImage != nil)
        #expect(!vm.isCaptureChooserPresented)
    }

    @Test func returnOnSelectedTextAttachesTheSelectionAndNoImage() async {
        let capture = ChooserScreenshotService()
        let selection = ChooserSelectedTextService(text: "The highlighted passage")
        let vm = QuickViewModel(
            settings: settings(),
            service: MockQuickService(),
            selectedTextService: selection,
            screenshotService: capture
        )
        vm.rememberSelectionTarget(Self.safari)
        vm.openCaptureChooser()
        #expect(vm.captureChooserOptions[vm.captureChooserIndex] == .selectedText)

        await vm.runCaptureChooserSelection()
        #expect(vm.pendingContext?.selectedText == "The highlighted passage")
        #expect(vm.pendingImage == nil)
        #expect(capture.captured.isEmpty)
    }

    // MARK: - The other two keys

    @Test func addContextStaysTheFullMenu() {
        let vm = QuickViewModel(settings: settings(), service: MockQuickService())
        vm.openQuickAI()
        #expect(vm.performShortcut(characters: "a", keyCode: 0, modifiers: [.command, .shift]))
        #expect(vm.isAddContextMenuPresented)
        #expect(vm.topLayer == .addContextMenu)
        #expect(!vm.isCaptureChooserPresented)
        // Files and links are still the first two rows.
        #expect(Array(vm.addContextRows.prefix(2)) == [.file, .link])
    }

    @Test func displayKeyStillCapturesDirectly() async {
        let capture = ChooserScreenshotService()
        let vm = QuickViewModel(
            settings: settings(),
            service: MockQuickService(),
            screenshotService: capture
        )
        vm.openQuickAI()
        #expect(vm.performShortcut(characters: "d", keyCode: 2, modifiers: [.command, .shift]))
        #expect(await eventually { !capture.captured.isEmpty })
        #expect(capture.captured.map(\.kind) == [.display])
        #expect(!vm.isCaptureChooserPresented)
    }

    // MARK: - AI Chat with no app behind

    @Test func aiChatWithNoAppBehindOffersOnlyValidRowsAndNeverNoOps() async throws {
        let capture = ChooserScreenshotService()
        let chat = QuickViewModel(settings: settings(), service: MockQuickService(), screenshotService: capture)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        // `chatWindowHost` is weak; keep the window model alive for the test.
        defer { withExtendedLifetime(window) {} }
        chat.rememberSelectionTarget(nil)
        #expect(chat.isAIChatWindow)
        #expect(chat.canOpenAttachments)

        // The key opens the chooser rather than being swallowed with nothing
        // to do (the old Focused Window guard).
        #expect(chat.performShortcut(characters: "s", keyCode: 1, modifiers: [.command, .shift]))
        #expect(chat.isCaptureChooserPresented)
        #expect(chat.topLayer == .captureChooser)

        // The two rows that read the app behind are gone; both screen
        // captures stay, so the chooser always has something to run.
        #expect(chat.captureChooserOptions == [.selectedArea, .entireScreen])
        #expect(chat.captureChooserOptions[chat.captureChooserIndex] == .selectedArea)

        chat.moveCaptureChooserSelection(1)
        await chat.runCaptureChooserSelection()
        #expect(capture.captured.map(\.kind) == [.display])
        #expect(chat.pendingImage != nil)
        #expect(chat.errorMessage == nil)
    }

    @Test func theComposerNamesTheChoosersAction() {
        let vm = QuickViewModel(settings: settings(), service: MockQuickService())
        vm.openQuickAI()
        vm.openCaptureChooser()
        #expect(vm.quickAIComposerAction.label == QuickViewModel.captureChooserConfirmTitle)
    }

    @Test func escapeClosesTheChooserBeforeTheSurface() {
        let vm = QuickViewModel(settings: settings(), service: MockQuickService())
        vm.openQuickAI()
        vm.openCaptureChooser()
        #expect(vm.handleEscapeKey())
        #expect(!vm.isCaptureChooserPresented)
        #expect(vm.isQuickAIPresented, "Escape closes the chooser, not the surface")
    }
}

/// Waits for a main-actor condition, yielding to the main actor between
/// checks so a pending Task can run.
@MainActor
private func eventually(
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private final class ChooserSelectedTextService: SelectedTextServicing {
    var text: String
    var silentReads = 0
    var promptingCaptures = 0
    var isAccessibilityTrusted: Bool { true }

    init(text: String) { self.text = text }

    func currentExternalTarget() -> SelectionTarget? { nil }

    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        if promptForPermission { promptingCaptures += 1 }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SelectedTextContext(target: target, text: text)
    }

    func hasSelection(from target: SelectionTarget) -> Bool {
        silentReads += 1
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { false }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { false }
    func openAccessibilitySettings() {}
}

@MainActor
private final class ChooserScreenshotService: ScreenshotCapturing {
    struct Call {
        let kind: ScreenshotKind
        let target: SelectionTarget?
        let ownProcess: pid_t
    }

    var isScreenRecordingAuthorized = true
    var failure: Error?
    var captured: [Call] = []

    func capture(
        _ kind: ScreenshotKind,
        target: SelectionTarget?,
        ownProcess: pid_t
    ) async throws -> QuickImageAttachment {
        captured.append(Call(kind: kind, target: target, ownProcess: ownProcess))
        if let failure { throw failure }
        return QuickImageAttachment(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            pixelWidth: 2,
            pixelHeight: 2
        )
    }
}
