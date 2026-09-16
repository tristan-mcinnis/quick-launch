import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Add Context (`⇧⌘A`/`@`) and the Capture chooser (`⇧⌘S`) each carry their
/// own search field, as the `⌘K` palette does: opening focuses it, typing
/// fuzzy-filters the rows and clears the highlight, and the keys operate on
/// the filtered list. The composer draft behind the pane is never touched.
@Suite("Chooser search", .serialized)
@MainActor
struct ChooserSearchTests {
    private static let editor = SelectionTarget(processIdentifier: 42, applicationName: "Editor")
    private static let finder = SelectionTarget(processIdentifier: 7, applicationName: QuickViewModel.finderApplicationName)

    private func settings() -> QuickSettings {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        return settings
    }

    private func viewModel(
        screenshotService: (any ScreenshotCapturing)? = nil,
        selectedTextService: (any SelectedTextServicing)? = nil
    ) -> QuickViewModel {
        QuickViewModel(
            settings: settings(),
            service: MockQuickService(),
            selectedTextService: selectedTextService,
            screenshotService: screenshotService
        )
    }

    // MARK: - Add Context

    @Test func addContextSearchNarrowsTheRowsAndClearsTheHighlight() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.openAddContextMenu()
        #expect(vm.addContextRows == vm.addContextAllRows)

        vm.addContextIndex = vm.addContextRows.count - 1
        vm.addContextQuery = "link"
        #expect(vm.addContextRows == [.link])
        #expect(vm.addContextIndex == 0, "typing clears the highlight")
    }

    @Test func addContextSearchRanksTheBestMatchFirst() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.finder)
        vm.openAddContextMenu()
        // "finder" reaches Finder Selection and nothing else.
        vm.addContextQuery = "finder"
        #expect(vm.addContextRows == [.finderSelection])
        // A shorter prefix reaches the capture whose title holds it.
        vm.addContextQuery = "screen"
        #expect(vm.addContextRows == [.capture(.entireScreen)])
    }

    @Test func addContextSearchLeavesTheHalfTypedQuestionAlone() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.input = "summarize this"
        vm.openAddContextMenu()
        vm.addContextQuery = "files"
        #expect(vm.input == "summarize this", "the draft is the composer's, not the search's")
        #expect(vm.addContextRows == [.file])
    }

    @Test func returnRunsTheFilteredHighlightedRow() async {
        let capture = ChooserSearchScreenshotService()
        let vm = viewModel(screenshotService: capture)
        vm.rememberSelectionTarget(Self.editor)
        vm.openAddContextMenu()
        vm.addContextQuery = "window"
        #expect(vm.addContextRows == [.capture(.focusedWindow)])

        await vm.runAddContextSelection()
        #expect(capture.captured.map(\.kind) == [.window])
        #expect(!vm.isAddContextMenuPresented)
    }

    @Test func theKeysWrapInsideTheFilteredRows() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.finder)
        vm.openAddContextMenu()
        vm.addContextQuery = "e"
        let count = vm.addContextRows.count
        #expect(count > 1, "the fixture needs more than one match to wrap")
        vm.addContextIndex = count - 1
        vm.moveAddContextSelection(1)
        #expect(vm.addContextIndex == 0, "wraps inside the filtered rows")
        vm.moveAddContextSelection(-1)
        #expect(vm.addContextIndex == count - 1)
    }

    @Test func anEmptyMatchFiltersEveryRowAndReturnDoesNothing() async {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.openAddContextMenu()
        vm.addContextQuery = "zzzzzz"
        #expect(vm.addContextRows.isEmpty)
        // The pane shows its empty state; Return is a quiet no-op.
        await vm.runAddContextSelection()
        #expect(vm.isAddContextMenuPresented)
    }

    @Test func addContextStillOffersEveryKindOfContextWhenTheQueryIsEmpty() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.finder)
        vm.openAddContextMenu()
        #expect(vm.addContextRows.contains(.file))
        #expect(vm.addContextRows.contains(.link))
        #expect(vm.addContextRows.contains(.capture(.selectedText)))
        #expect(vm.addContextRows.contains(.capture(.focusedWindow)))
        #expect(vm.addContextRows.contains(.capture(.selectedArea)))
        #expect(vm.addContextRows.contains(.capture(.entireScreen)))
        #expect(vm.addContextRows.contains(.finderSelection))
    }

    // MARK: - Capture chooser

    @Test func captureSearchNarrowsTheOptionsAndClearsTheHighlight() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.openCaptureChooser()
        #expect(vm.captureChooserOptions == vm.captureChooserAllOptions)

        vm.captureChooserIndex = 3
        vm.captureChooserQuery = "selected"
        #expect(vm.captureChooserOptions == [.selectedText, .selectedArea])
        #expect(vm.captureChooserIndex == 0, "typing clears the highlight")
    }

    @Test func captureSearchNeverAddsFilesLinksOrFinderSelection() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.finder)
        vm.openCaptureChooser()
        vm.captureChooserQuery = "e"
        #expect(vm.captureChooserOptions.allSatisfy { AddContextEntry.captureChooserOrder.contains($0) })
        #expect(vm.captureChooserOptions.count <= AddContextEntry.captureChooserOrder.count)
    }

    @Test func theCapturePreselectStillUsesTheUnfilteredOrderWhenTheQueryIsEmpty() {
        let selection = ChooserSearchSelectedTextService(text: "A passage worth asking about")
        let vm = viewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(Self.editor)
        vm.openCaptureChooser()
        #expect(vm.captureChooserQuery.isEmpty)
        #expect(vm.preferredCaptureEntry == .selectedText)
        #expect(vm.captureChooserOptions[vm.captureChooserIndex] == .selectedText)
    }

    @Test func returnAttachesTheFilteredCapture() async {
        let capture = ChooserSearchScreenshotService()
        let vm = viewModel(screenshotService: capture)
        vm.rememberSelectionTarget(Self.editor)
        vm.openCaptureChooser()
        vm.captureChooserQuery = "screen"
        #expect(vm.captureChooserOptions == [.entireScreen])

        await vm.runCaptureChooserSelection()
        #expect(capture.captured.map(\.kind) == [.display])
        #expect(!vm.isCaptureChooserPresented)
    }

    @Test func theCaptureKeysWrapInsideTheFilteredOptions() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.openCaptureChooser()
        vm.captureChooserQuery = "selected"
        #expect(vm.captureChooserOptions == [.selectedText, .selectedArea])
        vm.captureChooserIndex = 1
        vm.moveCaptureChooserSelection(1)
        #expect(vm.captureChooserIndex == 0, "wraps inside the filtered options")
        vm.moveCaptureChooserSelection(-1)
        #expect(vm.captureChooserIndex == 1)
    }

    // MARK: - Boundaries

    @Test func theQueryClearsWhenAPaneOpensOrCloses() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.openAddContextMenu()
        vm.addContextQuery = "link"
        vm.closeAddContextMenu()
        #expect(vm.addContextQuery.isEmpty)
        vm.openAddContextMenu()
        #expect(vm.addContextQuery.isEmpty, "a fresh open starts from every row")
        vm.closeAddContextMenu()

        vm.openCaptureChooser()
        vm.captureChooserQuery = "area"
        vm.closeCaptureChooser()
        #expect(vm.captureChooserQuery.isEmpty)
        vm.openCaptureChooser()
        #expect(vm.captureChooserQuery.isEmpty, "a fresh open starts from every capture")
    }

    @Test func openingOnePaneClearsTheOtherPanesSearch() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.openAddContextMenu()
        vm.addContextQuery = "link"
        vm.openCaptureChooser()
        #expect(vm.addContextQuery.isEmpty)
        #expect(vm.captureChooserQuery.isEmpty)

        vm.captureChooserQuery = "area"
        vm.openAddContextMenu()
        #expect(vm.captureChooserQuery.isEmpty)
    }

    @Test func escapeClosesThePaneAndDropsItsSearch() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.openAddContextMenu()
        vm.addContextQuery = "link"
        #expect(vm.handleEscapeKey())
        #expect(!vm.isAddContextMenuPresented)
        #expect(vm.addContextQuery.isEmpty)

        vm.openCaptureChooser()
        vm.captureChooserQuery = "area"
        #expect(vm.handleEscapeKey())
        #expect(!vm.isCaptureChooserPresented)
        #expect(vm.captureChooserQuery.isEmpty)
    }

    @Test func backspaceInTheSearchEditsTheQueryInsteadOfClosingThePane() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.openAddContextMenu()
        vm.addContextQuery = "lin"
        #expect(!vm.popLayerForEmptyBackspace(), "Backspace belongs to the search field")
        #expect(vm.isAddContextMenuPresented)

        vm.addContextQuery = ""
        #expect(vm.popLayerForEmptyBackspace())
        #expect(!vm.isAddContextMenuPresented)

        vm.openCaptureChooser()
        vm.captureChooserQuery = "are"
        #expect(!vm.popLayerForEmptyBackspace())
        #expect(vm.isCaptureChooserPresented)
        vm.captureChooserQuery = ""
        #expect(vm.popLayerForEmptyBackspace())
        #expect(!vm.isCaptureChooserPresented)
    }

    @Test func clearingCaptureSearchRestoresTheSmartPreselection() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.openCaptureChooser()
        #expect(vm.captureChooserOptions[vm.captureChooserIndex] == .focusedWindow)

        vm.captureChooserQuery = "area"
        #expect(vm.captureChooserOptions[vm.captureChooserIndex] == .selectedArea)
        vm.captureChooserQuery = ""
        #expect(vm.captureChooserOptions[vm.captureChooserIndex] == .focusedWindow)
    }

    @Test func aComposerDraftKeepsItsBackspace() {
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        vm.input = "keep me"
        vm.openAddContextMenu()
        vm.addContextQuery = "lin"
        #expect(!vm.popLayerForEmptyBackspace(), "a draft means Backspace never pops a layer")
        #expect(vm.isAddContextMenuPresented)
        #expect(vm.input == "keep me")
    }

    // MARK: - Sizing

    @Test func theWindowEstimateCountsTheSearchRow() {
        #expect(PanelSizing.searchableChooserBlockHeight(rows: 4)
            == PanelSizing.chooserBlockHeight(rows: 4) + PanelSizing.paneSearchRowHeight)
        let vm = viewModel()
        vm.rememberSelectionTarget(Self.editor)
        let without = vm.estimatedWindowHeight
        vm.openAddContextMenu()
        #expect(vm.estimatedWindowHeight > without)
    }
}

@MainActor
private final class ChooserSearchSelectedTextService: SelectedTextServicing {
    var text: String
    var isAccessibilityTrusted: Bool { true }
    init(text: String) { self.text = text }
    func currentExternalTarget() -> SelectionTarget? { nil }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return SelectedTextContext(target: target, text: text)
    }
    func hasSelection(from target: SelectionTarget) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { false }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { false }
    func openAccessibilitySettings() {}
}

@MainActor
private final class ChooserSearchScreenshotService: ScreenshotCapturing {
    struct Call {
        let kind: ScreenshotKind
    }
    var isScreenRecordingAuthorized = true
    var failure: Error?
    var captured: [Call] = []
    func capture(
        _ kind: ScreenshotKind,
        target: SelectionTarget?,
        ownProcess: pid_t
    ) async throws -> QuickImageAttachment {
        captured.append(Call(kind: kind))
        if let failure { throw failure }
        return QuickImageAttachment(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            mimeType: "image/png",
            pixelWidth: 2,
            pixelHeight: 2
        )
    }
}
