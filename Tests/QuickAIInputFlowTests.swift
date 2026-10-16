// QuickAIInputFlowTests: the connected Quick AI input/transformation flow.
// Clipboard History as a typed Add Context source, named transform
// arguments, the explicit `{clipboard}` placeholder, text-only execution, and
// the opt-in Review Changes write-back. All deterministic: injected service,
// attachment reader, clipboard catalog, and selected-text seam; no real
// clipboard, history, network, or UI.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Quick AI input flow", .serialized)
@MainActor
struct QuickAIInputFlowTests {
    // MARK: - Fixtures

    private func settings() -> QuickSettings {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        return settings
    }

    private func target(_ app: String = "TextEdit") -> SelectionTarget {
        SelectionTarget(processIdentifier: 42, applicationName: app)
    }

    private static func tinyPNG() throws -> Data {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )
        let rep = try #require(bitmap)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        return data
    }

    // MARK: - Clipboard History maps to typed attachments

    @Test func clipboardTextBecomesALabelledSelectionSource() {
        let payload = ClipboardPayload(kind: .text, text: "  hello clipboard  ")
        let sources = ClipboardHistoryAttachments.sources(for: payload)
        #expect(sources == [.clipboard("  hello clipboard  ", appName: nil)])
        #expect(sources.first?.provisionalKind == .text)
        #expect(sources.first?.provisionalName == "Clipboard")
    }

    @Test func clipboardFileURLBecomesAFileAttachment() {
        let payload = ClipboardPayload(
            kind: .fileURL,
            text: "",
            fileURLs: ["file:///tmp/Example%20Report.pdf"]
        )
        #expect(ClipboardHistoryAttachments.sources(for: payload) == [
            .file(URL(fileURLWithPath: "/tmp/Example Report.pdf")),
        ])
    }

    @Test func aMultiFileCopyAttachesEveryFileNotJustTheFirst() throws {
        let urls = ["file:///tmp/one.pdf", "file:///tmp/two.docx", "file:///tmp/three.png"]
        let payload = ClipboardPayload(kind: .fileURL, text: "", fileURLs: urls)
        let sources = ClipboardHistoryAttachments.sources(for: payload)
        #expect(sources == urls.map { .file(URL(fileURLWithPath: $0.replacingOccurrences(of: "file://", with: ""))) })
        #expect(sources.count == 3)
        #expect(ClipboardHistoryAttachments.omittedFileCount(for: payload) == 0)
    }

    @Test func excessFilesAreBoundedAndReported() throws {
        let urls = (0..<25).map { "file:///tmp/file\($0).txt" }
        let payload = ClipboardPayload(kind: .fileURL, text: "", fileURLs: urls)
        let sources = ClipboardHistoryAttachments.sources(for: payload)
        #expect(sources.count == ClipboardHistoryAttachments.maximumFiles)
        #expect(ClipboardHistoryAttachments.omittedFileCount(for: payload) == 25 - ClipboardHistoryAttachments.maximumFiles)
    }

    @Test func aFileURLCopyWithNoLocalFileReportsTheOmission() {
        let payload = ClipboardPayload(kind: .fileURL, text: "", fileURLs: ["https://example.com/x.pdf"])
        #expect(ClipboardHistoryAttachments.sources(for: payload).isEmpty)
        #expect(ClipboardHistoryAttachments.omittedFileCount(for: payload) == 1)
    }

    @Test func clipboardImageBecomesATypedImageAttachment() throws {
        let png = try Self.tinyPNG()
        let payload = ClipboardPayload(
            kind: .image,
            text: "",
            imageWidth: 8,
            imageHeight: 8,
            items: [[ClipboardRawItem(type: "public.png", data: png)]]
        )
        let sources = ClipboardHistoryAttachments.sources(for: payload)
        #expect(sources.count == 1)
        guard case .image(let image, let name, let kind) = sources.first else {
            Issue.record("expected an image source, got \(String(describing: sources))")
            return
        }
        #expect(kind == .image)
        #expect(image.mimeType == "image/png")
        #expect(name == "Clipboard image 8×8")
    }

    @Test func anEmptyClipboardPayloadAttachesNothing() {
        let payload = ClipboardPayload(kind: .text, text: "   \n ")
        #expect(ClipboardHistoryAttachments.sources(for: payload).isEmpty)
    }

    @Test func aBinaryDataCopyIsNeverReadAsText() {
        // No image, no file, no real text form: a binary copy attaches
        // nothing rather than inventing a text value.
        let payload = ClipboardPayload(kind: .data, text: "", firstType: "com.example.binary")
        #expect(ClipboardHistoryAttachments.sources(for: payload).isEmpty)
    }

    @Test func clipboardRowsFilterByQueryAndKeepPinnedFirst() {
        let pinned = LauncherCatalogItem(
            kind: .clipboard, itemID: "a", title: "Invoice", detail: "Text · Pinned",
            value: "invoice", keywords: "pinned", isPinned: true
        )
        let plain = LauncherCatalogItem(
            kind: .clipboard, itemID: "b", title: "Address", detail: "Text",
            value: "221B Baker Street", keywords: "", isPinned: false
        )
        let other = LauncherCatalogItem(
            kind: .snippet, itemID: "c", title: "Invoice snippet", detail: "", value: ""
        )
        let all = [plain, pinned, other]
        #expect(ClipboardHistoryAttachments.rows(from: all, query: "").map(\.id) == [pinned.id, plain.id])
        #expect(ClipboardHistoryAttachments.rows(from: all, query: "address").map(\.id) == [plain.id])
        #expect(ClipboardHistoryAttachments.rows(from: all, query: "invoice").map(\.id) == [pinned.id])
    }

    // MARK: - Shared grammar: named arguments, defaults, options, clipboard

    @Test func argumentSlotsCarryNameDefaultAndOptions() {
        let prompt = """
        Write for {argument name="audience" default="Editorial"} \
        in {argument name="tone" options="Formal,Casual"}.
        """
        let slots = SavedPromptResolver.argumentSlots(in: prompt)
        #expect(slots.map(\.name) == ["audience", "tone"])
        #expect(slots[0].defaultValue == "Editorial")
        #expect(slots[0].options.isEmpty)
        #expect(slots[1].options == ["Formal", "Casual"])
        #expect(slots[1].offersOptions)
    }

    @Test func optionsAreTrimmedFilteredAndCappedAtFive() {
        #expect(SnippetPlaceholders.parseOptions(" Form , ,Casual , Bold , Quiet , Sixth , Seventh ")
            == ["Form", "Casual", "Bold", "Quiet", "Sixth"])
        #expect(SnippetPlaceholders.parseOptions(nil) == [])
    }

    @Test func legacySelectionAndAppendBehaviourIsPreserved() {
        let withPlaceholder = SavedPrompt(alias: "a", prompt: "Rewrite: {selection}")
        #expect(
            SavedPromptResolver.prompt(for: withPlaceholder, source: "Hello")
                == "Rewrite: Hello"
        )
        let appending = SavedPrompt(alias: "b", prompt: "Summarize this")
        #expect(
            SavedPromptResolver.prompt(for: appending, source: "Hello")
                == "Summarize this\n\nHello"
        )
        let emptyPrompt = SavedPrompt(alias: "c", prompt: "")
        #expect(SavedPromptResolver.prompt(for: emptyPrompt, source: "Hello") == "Hello")
    }

    @Test func argumentsAndClipboardFillThroughTheSharedGrammar() {
        let action = SavedPrompt(
            alias: "draft",
            prompt: "For {argument name=\"audience\" default=\"Editorial\"}: {selection}\n\nClipboard: {clipboard | raw}"
        )
        let text = SavedPromptResolver.prompt(
            for: action,
            source: "Body text",
            arguments: [],
            clipboard: "copied value"
        )
        #expect(text.contains("For Editorial: Body text"))
        #expect(text.contains("Clipboard: copied value"))
    }

    @Test func anExplicitClipboardPlaceholderWithNoValueFillsBlank() {
        let action = SavedPrompt(alias: "x", prompt: "Clipboard: [{clipboard}]")
        #expect(SavedPromptResolver.prompt(for: action, source: "", clipboard: nil) == "Clipboard: []")
        #expect(SavedPromptResolver.readsClipboard(action.prompt))
    }

    // MARK: - SavedPrompt coding for the new policies

    @Test func textOnlyAndReviewChangesRoundTripThroughTheFile() throws {
        let action = SavedPrompt(
            alias: "z", prompt: "do it",
            outputBehavior: .reviewChanges,
            textOnly: true
        )
        let data = try JSONEncoder().encode(action)
        let back = try JSONDecoder().decode(SavedPrompt.self, from: data)
        #expect(back.outputBehavior == .reviewChanges)
        #expect(back.textOnly)
    }

    @Test func legacySavedPromptDecodesWithTextOnlyOff() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000010","alias":"old","prompt":"p","outputBehavior":"replaceSelection"}"#
        let decoded = try JSONDecoder().decode(SavedPrompt.self, from: Data(json.utf8))
        #expect(decoded.textOnly == false)
        #expect(decoded.outputBehavior == .replaceSelection)
    }

    // MARK: - The review model is bounded and honest

    @Test func reviewBoundsLongTextAndCountsChanges() {
        let long = String(repeating: "字", count: 5_000)
        let bounded = TransformReview.bounded(long)
        #expect(bounded.text.count == TransformReview.shownCharacters)
        #expect(bounded.omittedCharacters == 5_000 - TransformReview.shownCharacters)
        #expect(bounded.isTruncated)
        #expect(TransformReview.bounded("short").isTruncated == false)

        #expect(TransformReview.changedLineCount(original: "a\nb\nc", proposed: "a\nB\nc") == 1)
        #expect(TransformReview.summary(original: "same", proposed: "same") == "No change")
    }

    // MARK: - Attaching from Clipboard History never sends

    @Test func attachingAMultiFileCopyAddsEveryChip() async {
        let urls = ["file:///tmp/one.pdf", "file:///tmp/two.docx"]
        let payload = ClipboardPayload(kind: .fileURL, text: "", fileURLs: urls)
        let item = LauncherCatalogItem(
            kind: .clipboard, itemID: "m1", title: "2 files", detail: "File",
            value: urls.joined(separator: " "), keywords: "file"
        )
        let mock = MockQuickService()
        let vm = QuickViewModel(
            settings: settings(),
            service: mock,
            clipboardHistory: FakeClipboard(entries: [item], payloads: [item.id: payload]),
            pasteboard: FakePasteboard(),
            attachmentExtractor: FakeAttachmentExtractor()
        )

        await vm.attachClipboardHistoryItem(item)
        await vm.attachmentTray.waitUntilRead()

        #expect(await mock.sendCallCount == 0)
        #expect(vm.attachmentTray.items.count == 2)
        #expect(Set(vm.attachmentTray.items.map(\.name)) == ["one.pdf", "two.docx"])
        #expect(vm.errorMessage == nil)
    }

    @Test func attachingAClipboardTextNeverSendsAndPreservesTheDraft() async {
        let payload = ClipboardPayload(kind: .text, text: "copied words")
        let item = LauncherCatalogItem(
            kind: .clipboard, itemID: "c1", title: "copied words", detail: "Text",
            value: "copied words", keywords: ""
        )
        let mock = MockQuickService()
        let vm = QuickViewModel(
            settings: settings(),
            service: mock,
            clipboardHistory: FakeClipboard(entries: [item], payloads: [item.id: payload]),
            pasteboard: FakePasteboard(),
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.input = "half-typed question"
        vm.isAddContextMenuPresented = true
        vm.openClipboardHistory()

        await vm.attachClipboardHistoryItem(item)
        await vm.attachmentTray.waitUntilRead()

        #expect(await mock.sendCallCount == 0)
        #expect(vm.input == "half-typed question")
        #expect(vm.attachmentTray.items.count == 1)
        #expect(vm.attachmentTray.items.first?.kind == .text)
        #expect(vm.isClipboardHistoryOpen == false)
        // The chosen source is now the transform's source, so the keyboard
        // Transform chooser is reachable from it.
        #expect(vm.selectionTransformSource == "copied words")
        #expect(!vm.chipTransformOptions.isEmpty)
    }

    // MARK: - Named arguments through the existing chooser

    @Test func aTransformWithOptionsAsksThroughTheChooserThenRuns() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Rewritten.", finishReason: "stop")])
        let selection = FakeSelection(liveText: "Hello world")
        var settings = self.settings()
        settings.savedPrompts = [
            SavedPrompt(
                alias: "pick",
                prompt: "For {argument name=\"audience\" default=\"\" options=\"Editorial,Casual\"}: {selection}"
            ),
        ]
        let vm = QuickViewModel(
            settings: settings, service: mock,
            selectedTextService: selection,
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()

        let action = try! #require(settings.savedPrompts.first)
        await vm.performTransform(action: action)

        // The chooser is up and nothing has been sent yet.
        #expect(vm.pendingTransformArguments != nil)
        #expect(vm.isTransformChooserPresented)
        #expect(await mock.sendCallCount == 0)
        #expect(vm.transformChooserOptions.map(\.title) == ["Editorial", "Casual"])
        #expect(vm.transformChooserTitle == "Choose audience")

        await vm.chooseTransformArgument(index: 1)

        #expect(vm.pendingTransformArguments == nil)
        #expect(vm.isTransformChooserPresented == false)
        #expect(await mock.sendCallCount == 1)
        #expect(await mock.lastPrompt?.contains("For Casual: Hello world") == true)
    }

    @Test func aTransformWithOnlyDefaultsRunsWithoutAsking() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "ok", finishReason: "stop")])
        let selection = FakeSelection(liveText: "Body")
        var settings = self.settings()
        settings.savedPrompts = [
            SavedPrompt(alias: "defaults", prompt: "{argument name=\"audience\" default=\"Editorial\"}: {selection}"),
        ]
        let vm = QuickViewModel(
            settings: settings, service: mock,
            selectedTextService: selection,
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()

        await vm.performTransform(action: settings.savedPrompts[0])

        #expect(vm.pendingTransformArguments == nil)
        #expect(await mock.sendCallCount == 1)
        #expect(await mock.lastPrompt?.contains("Editorial: Body") == true)
    }

    // MARK: - Explicit clipboard placeholder reads only on user action

    @Test func theClipboardPlaceholderReadsTheInjectedPasteboard() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "ok", finishReason: "stop")])
        let pasteboard = FakePasteboard(string: "clipboard value")
        var settings = self.settings()
        settings.savedPrompts = [
            SavedPrompt(alias: "usepaste", prompt: "Apply to this: {clipboard}"),
        ]
        let vm = QuickViewModel(
            settings: settings, service: mock,
            pasteboard: pasteboard,
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.pendingActionSource = "the source"
        vm.input = "/usepaste"
        await vm.submit()

        #expect(await mock.lastPrompt?.contains("clipboard value") == true)
    }

    @Test func aPromptWithoutThePlaceholderNeverReadsTheClipboard() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "ok", finishReason: "stop")])
        let pasteboard = FakePasteboard(string: "should not appear")
        var settings = self.settings()
        settings.savedPrompts = [SavedPrompt(alias: "plain", prompt: "Just: {selection}")]
        let vm = QuickViewModel(
            settings: settings, service: mock,
            selectedTextService: FakeSelection(liveText: "Hello world"),
            pasteboard: pasteboard,
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()
        vm.input = "/plain"
        await vm.submit()

        #expect(await mock.lastPrompt == "Just: Hello world")
        #expect(await mock.lastPrompt?.contains("should not appear") == false)
    }

    // MARK: - Text-only execution

    /// The `search` alias's trailing text is what would go to the web, so the
    /// same invocation proves both halves: text-only skips it, the ordinary
    /// action does not.
    private func searchAction(textOnly: Bool) -> SavedPrompt {
        SavedPrompt(alias: "search", prompt: "Rewrite: {selection}", textOnly: textOnly)
    }

    @Test func aTextOnlyTransformOffersNoToolsAndSkipsEnrichment() async {
        var settings = self.settings()
        settings.savedPrompts = [searchAction(textOnly: true)]
        let vm = QuickViewModel(
            settings: settings, service: MockQuickService(),
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()
        let search = CountingWebSearchService()
        vm.webSearchService = search
        vm.pendingActionSource = "text"
        vm.input = "/search latest swift news"

        let request = await vm.prepareRequest()
        #expect(request?.actionDefinition?.textOnly == true)
        #expect(request?.contextEvaluation?.gatedTools.isEmpty == true)

        var enrichable = try! #require(request)
        #expect(await vm.enrich(&enrichable))
        #expect(await search.callCount == 0)
    }

    @Test func anOrdinaryPromptStillAllowsEnrichment() async {
        // The gate is specific to an explicit per-action choice: an ordinary
        // action's request is unchanged and enrichment still runs.
        var settings = self.settings()
        settings.savedPrompts = [searchAction(textOnly: false)]
        let vm = QuickViewModel(
            settings: settings, service: MockQuickService(),
            attachmentExtractor: FakeAttachmentExtractor()
        )
        let search = CountingWebSearchService()
        vm.webSearchService = search
        vm.input = "/search latest swift news"

        var request = try! #require(await vm.prepareRequest())
        #expect(request.actionDefinition?.textOnly != true)
        #expect(await vm.enrich(&request))
        #expect(await search.callCount == 1)
    }

    // MARK: - Review Changes: opt-in, fail-closed replacement

    @Test func aReviewTransformShowsOriginalAndProposedThenAccepts() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Improved text.", finishReason: "stop")])
        let selection = FakeSelection(liveText: "Hello world")
        var settings = self.settings()
        settings.savedPrompts = [
            SavedPrompt(alias: "review", prompt: "Improve:\n{selection}", outputBehavior: .reviewChanges),
        ]
        let vm = QuickViewModel(
            settings: settings, service: mock,
            selectedTextService: selection,
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()

        await vm.performTransform(action: settings.savedPrompts[0])

        let review = try! #require(vm.pendingTransformReview)
        #expect(review.original == "Hello world")
        #expect(review.proposed == "Improved text.")
        #expect(review.sourceApp == "TextEdit")
        #expect(selection.replaced.isEmpty)

        let accepted = await vm.acceptTransformReview()
        #expect(accepted)
        #expect(selection.replaced == ["Improved text."])
        #expect(vm.pendingTransformReview == nil)
    }

    @Test func aChangedSelectionMakesAcceptCopyInsteadOfReplacing() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Improved text.", finishReason: "stop")])
        let selection = FakeSelection(liveText: "Hello world")
        var settings = self.settings()
        settings.savedPrompts = [
            SavedPrompt(alias: "review", prompt: "Improve:\n{selection}", outputBehavior: .reviewChanges),
        ]
        let vm = QuickViewModel(
            settings: settings, service: mock,
            selectedTextService: selection,
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()

        await vm.performTransform(action: settings.savedPrompts[0])
        try! #require(vm.pendingTransformReview != nil)

        // The live selection moved on: the check must fail closed.
        selection.liveText = "Something else entirely"
        let accepted = await vm.acceptTransformReview()
        #expect(accepted == false)
        #expect(selection.replaced.isEmpty)
        #expect(vm.pendingTransformReview == nil)
        #expect(vm.errorMessage?.contains("selection changed") == true)
    }

    @Test func aClosedTargetMakesAcceptCopyInsteadOfReplacing() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Improved text.", finishReason: "stop")])
        let selection = FakeSelection(liveText: "Hello world")
        var settings = self.settings()
        settings.savedPrompts = [
            SavedPrompt(alias: "review", prompt: "Improve:\n{selection}", outputBehavior: .reviewChanges),
        ]
        let vm = QuickViewModel(
            settings: settings, service: mock,
            selectedTextService: selection,
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()
        await vm.performTransform(action: settings.savedPrompts[0])
        try! #require(vm.pendingTransformReview != nil)

        // The target app is gone: the live re-read cannot confirm the text.
        selection.captureAvailable = false
        let accepted = await vm.acceptTransformReview()
        #expect(accepted == false)
        #expect(selection.replaced.isEmpty)
        #expect(vm.pendingTransformReview == nil)
    }

    @Test func aLongResultIsWrittenInFullEvenThoughTheCardBoundsDisplay() async {
        let long = String(repeating: "x", count: TransformReview.shownCharacters + 500)
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: long, finishReason: "stop")])
        let selection = FakeSelection(liveText: "Short source")
        var settings = self.settings()
        settings.savedPrompts = [
            SavedPrompt(alias: "review", prompt: "Improve:\n{selection}", outputBehavior: .reviewChanges),
        ]
        let vm = QuickViewModel(
            settings: settings, service: mock,
            selectedTextService: selection,
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()
        await vm.performTransform(action: settings.savedPrompts[0])

        let review = try! #require(vm.pendingTransformReview)
        #expect(review.proposed.count > TransformReview.shownCharacters)
        #expect(TransformReview.bounded(review.proposed).isTruncated, "the display is bounded")

        let accepted = await vm.acceptTransformReview()
        #expect(accepted)
        #expect(selection.replaced == [long], "the full untruncated result is written back")
    }

    // MARK: - Critical source binding: clipboard B never writes into launch A

    @Test func aClipboardReviewNeverWritesIntoTheLaunchSelection() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Rewritten B.", finishReason: "stop")])
        let selection = FakeSelection(liveText: "AAA")
        var settings = self.settings()
        settings.savedPrompts = [
            SavedPrompt(alias: "review", prompt: "Improve:\n{selection}", outputBehavior: .reviewChanges),
        ]
        let pasteboard = FakePasteboard()
        let payload = ClipboardPayload(kind: .text, text: "BBB")
        let item = LauncherCatalogItem(
            kind: .clipboard, itemID: "b1", title: "BBB", detail: "Text", value: "BBB", keywords: ""
        )
        let vm = QuickViewModel(
            settings: settings, service: mock,
            selectedTextService: selection,
            clipboardHistory: FakeClipboard(entries: [item], payloads: [item.id: payload]),
            pasteboard: pasteboard,
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()

        await vm.attachClipboardHistoryItem(item)
        await vm.attachmentTray.waitUntilRead()

        await vm.performTransform(action: settings.savedPrompts[0])
        let review = try! #require(vm.pendingTransformReview)
        #expect(review.original == "BBB", "the transform acted on the chosen clipboard source")
        #expect(review.target == nil, "a clipboard source has no live-selection target")
        #expect(review.sourceApp == "Clipboard", "never attributed to the live app")

        let accepted = await vm.acceptTransformReview()
        #expect(accepted == false)
        #expect(selection.replaced.isEmpty, "launch selection A must never be written")
        #expect(pasteboard.string == "Rewritten B.", "the result copies instead")
    }

    // MARK: - Required free-text arguments

    @Test func aRequiredFreeTextArgumentBlocksUntilTyped() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "ok", finishReason: "stop")])
        let selection = FakeSelection(liveText: "Body text")
        var settings = self.settings()
        settings.savedPrompts = [
            SavedPrompt(alias: "who", prompt: "For {argument name=\"audience\"}: {selection}"),
        ]
        let vm = QuickViewModel(
            settings: settings, service: mock,
            selectedTextService: selection,
            pasteboard: FakePasteboard(),
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()
        vm.input = "my draft"

        await vm.performTransform(action: settings.savedPrompts[0])

        // The field is up, nothing is sent, and the draft and source are kept.
        #expect(vm.isTransformArgumentFieldPresented)
        #expect(vm.transformArgumentPrompt == "audience")
        #expect(await mock.sendCallCount == 0)
        #expect(vm.input == "my draft")
        #expect(vm.launchSelection?.text == "Body text")

        // An empty Return is refused, never substituted.
        await vm.submitTransformArgument()
        #expect(vm.isTransformArgumentFieldPresented)
        #expect(await mock.sendCallCount == 0)
        #expect(vm.errorMessage?.contains("audience") == true)

        // A typed value runs the transform with the selected source.
        vm.transformArgumentInput = "Editorial"
        await vm.submitTransformArgument()
        #expect(vm.isTransformArgumentFieldPresented == false)
        #expect(await mock.sendCallCount == 1)
        #expect(await mock.lastPrompt?.contains("For Editorial: Body text") == true)
    }

    @Test func escapeCancelsARequiredArgumentWithoutSending() async {
        let mock = MockQuickService()
        let selection = FakeSelection(liveText: "Body text")
        var settings = self.settings()
        settings.savedPrompts = [
            SavedPrompt(alias: "who", prompt: "For {argument name=\"audience\"}: {selection}"),
        ]
        let vm = QuickViewModel(
            settings: settings, service: mock,
            selectedTextService: selection,
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.rememberSelectionTarget(target())
        vm.captureLaunchSelection()

        await vm.performTransform(action: settings.savedPrompts[0])
        #expect(vm.isTransformArgumentFieldPresented)
        #expect(vm.handleEscapeKey())
        #expect(vm.isTransformArgumentFieldPresented == false)
        #expect(vm.pendingTransformArguments == nil)
        #expect(await mock.sendCallCount == 0)
        #expect(vm.launchSelection?.text == "Body text", "the source is kept")
    }
}

// MARK: - Fakes

@MainActor
private final class FakeClipboard: ClipboardHistoryServicing {
    var entries: [LauncherCatalogItem]
    private var payloads: [String: ClipboardPayload]

    init(entries: [LauncherCatalogItem], payloads: [String: ClipboardPayload]) {
        self.entries = entries
        self.payloads = payloads
    }

    func startMonitoring(limit: Int) {}
    func stopMonitoring() {}
    func record(_ text: String, limit: Int) {}
    func remove(_ item: LauncherCatalogItem) { entries.removeAll { $0.id == item.id } }
    func clear() { entries = [] }
    func payload(for item: LauncherCatalogItem) async -> ClipboardPayload? { payloads[item.id] }
}

@MainActor
private final class FakeSelection: SelectedTextServicing {
    var isAccessibilityTrusted = true
    var liveText: String
    /// False models a closed target: the live re-read returns nothing.
    var captureAvailable = true
    private(set) var replaced: [String] = []
    private let target = SelectionTarget(processIdentifier: 42, applicationName: "TextEdit")

    init(liveText: String) { self.liveText = liveText }

    func currentExternalTarget() -> SelectionTarget? { target }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        guard captureAvailable else { return nil }
        return SelectedTextContext(target: self.target, text: liveText)
    }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool {
        replaced.append(text)
        return true
    }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { true }
    func openAccessibilitySettings() {}
}

private actor CountingWebSearchService: WebSearchServicing {
    private(set) var callCount = 0

    func search(_ query: String) async throws -> String {
        callCount += 1
        return "result"
    }
}
