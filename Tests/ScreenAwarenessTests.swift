import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screen Awareness, OCR search, emoji grid, detail pane", .serialized)
@MainActor
struct ScreenAwarenessTests {
    private static let safari = SelectionTarget(processIdentifier: 4242, applicationName: "Safari")

    // MARK: Capture context

    @Test func captureContextDescribesItselfAndBuildsAPreamble() {
        var context = CaptureContext(appName: "Safari")
        #expect(context.includedSources.isEmpty)
        #expect(context.captureTypeTitle == "Window Metadata")
        context.windowTitle = "Raycast Manual"
        context.selectedText = "Screen Awareness"
        context.appText = "Get Started\nRun Send Focused Window to AI"
        context.pageURL = "https://manual.raycast.com/screen-awareness"
        context.hasScreenshot = true
        #expect(context.includedSources == ["Screenshot", "Page", "App content", "Selection"])
        #expect(context.captureTypeTitle == "Screenshot + App Content")
        let preamble = context.promptPreamble()
        #expect(preamble.hasPrefix("Context from Safari (window: Raycast Manual), page: https://manual.raycast.com/screen-awareness."))
        #expect(preamble.contains("Selected text:\nScreen Awareness"))
        #expect(preamble.contains("Readable text in the window:\nGet Started"))
        let long = CaptureContext(appName: "A", appText: String(repeating: "x", count: 10_000))
        #expect(long.promptPreamble(limit: 500).count <= 501)
    }

    @Test func finderSelectionJoinsTheContextCardAndPreamble() {
        let context = CaptureContext(
            appName: "Finder",
            selectedFilePaths: ["/tmp/brief.pdf", "/tmp/invoice.png"],
            hasScreenshot: true
        )
        #expect(context.includedSources == ["Screenshot", "Files"])
        #expect(context.captureTypeTitle == "Screenshot + App Content")
        let preamble = context.promptPreamble()
        #expect(preamble.contains("Selected files:\n/tmp/brief.pdf\n/tmp/invoice.png"))
    }

    @Test func pasteResolvesAFreshTargetWhenNothingWasCaptured() async {
        let service = FallbackPasteSelection(fallbackTarget: Self.safari)
        let vm = QuickViewModel(selectedTextService: service)
        let item = LauncherCatalogItem(kind: .clipboard, itemID: "entry", title: "Entry", detail: "", value: "quarterly numbers")
        // No target was captured when the overlay opened; the window stack
        // still knows what sits behind, and Return must paste there.
        #expect(await vm.pasteLauncherItem(item))
        #expect(service.pastedText == "quarterly numbers")
        #expect(service.pastedTo == Self.safari)
        #expect(vm.errorMessage == nil)
        #expect(vm.selectionTarget == Self.safari)

        // With no window behind at all, the copy fallback still explains itself.
        let empty = QuickViewModel(selectedTextService: FallbackPasteSelection(fallbackTarget: nil))
        #expect(await empty.pasteLauncherItem(item) == false)
        #expect(empty.errorMessage?.contains("copied") == true)
    }

    @Test func screenshotsCatalogOffersCaptureCommandsBehindCommandK() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-cmdk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.writeImage(to: folder.appendingPathComponent("Screenshot 2026-08-22 at 10.00.00.png"), text: "x")

        let vm = QuickViewModel(screenshotTextIndex: ScreenshotTextIndex(storeURL: nil))
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)
        // The list holds only the file; the capture and AI commands do not.
        #expect(vm.catalogItems.allSatisfy { $0.kind == .screenshot })

        vm.handleCommandK()
        #expect(vm.isCatalogActionPanePresented)
        let titles = vm.focusedItemActions.map(\.title)
        for expected in ["Send Focused Window to AI", "Send Screen to AI", "Attach Latest Screenshot", "Paste Latest Screenshot"] {
            #expect(titles.contains(expected), "\(expected) belongs in ⌘K")
        }
        // None of them steal a keyboard shortcut from the file's own actions.
        #expect(vm.focusedItemActions.filter { $0.kind == .runCommand }.allSatisfy { $0.shortcut == nil })

        // Running one dispatches the real command: Attach Latest Screenshot
        // pulls the newest file in as a pending attachment.
        let attach = vm.focusedItemActions.first {
            $0.kind == .runCommand && $0.commandValue == LatestScreenshotFinder.commandID
        }!
        vm.rememberSelectionTarget(Self.safari)
        await vm.perform(attach, on: vm.focusedLauncherResult!)
        #expect(vm.pendingImage != nil)
        #expect(vm.pendingContext?.hasScreenshot == true)
    }

    @Test func focusedWindowCaptureAttachesImageAndContextAndPrefixesTheQuestion() async {
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "It is the Raycast manual.", finishReason: "stop")])
        let awareness = FakeAwareness()
        let vm = QuickViewModel(service: mock, screenshotService: FakeShots(), screenAwareness: awareness)
        vm.settings.autoCopy = false
        vm.rememberSelectionTarget(Self.safari)

        #expect(await vm.attachScreenshot(.window, clearingInput: true))
        #expect(vm.pendingImage != nil)
        #expect(vm.pendingContext?.appName == "Safari")
        #expect(vm.pendingContext?.hasScreenshot == true)
        #expect(vm.attachmentTitle == "Screen Awareness · Safari")
        #expect(vm.attachmentSubtitle.contains("Screenshot, App content, Selection"))
        #expect(vm.launcherMatches.isEmpty)
        #expect(vm.footerHints.map(\.label) == ["Ask", "Remove", "Retake"])

        vm.input = "what page is this"
        await vm.submit()
        let sent = await mock.lastPrompt ?? ""
        #expect(sent.hasPrefix("Context from Safari (window: Manual)"))
        #expect(sent.contains("Selected text:\nhello"))
        #expect(sent.hasSuffix("Question: what page is this"))
        #expect(await mock.lastImage != nil)
        #expect(vm.pendingContext == nil)
        #expect(vm.lastQuestion == "what page is this")
    }

    @Test func selectedTextOnlyCaptureHasNoImageAndBackspaceRemovesIt() {
        let vm = QuickViewModel(selectedTextService: StubSelection(text: "  quarterly numbers  "), screenAwareness: FakeAwareness())
        vm.rememberSelectionTarget(Self.safari)
        #expect(vm.attachSelectedText())
        #expect(vm.pendingImage == nil)
        #expect(vm.pendingContext?.selectedText == "quarterly numbers")
        #expect(vm.pendingContext?.appText == nil)
        #expect(vm.attachmentTitle == "Screen Awareness · Safari")
        #expect(vm.attachmentSubtitle.hasSuffix("Sent as text"))
        #expect(vm.hasPendingAttachment)
        #expect(vm.popLayerForEmptyBackspace())
        #expect(!vm.hasPendingAttachment)

        let empty = QuickViewModel(selectedTextService: StubSelection(text: ""), screenAwareness: FakeAwareness())
        empty.rememberSelectionTarget(Self.safari)
        #expect(!empty.attachSelectedText())
        #expect(empty.errorMessage?.contains("Nothing is selected") == true)
    }

    @Test func screenAreaCaptureUsesTheAreaPicker() async {
        let awareness = FakeAwareness()
        let vm = QuickViewModel(screenAwareness: awareness)
        #expect(await vm.attachScreenArea())
        #expect(vm.pendingImage?.pixelWidth == 2)
        awareness.areaResult = nil
        let cancelled = QuickViewModel(screenAwareness: awareness)
        #expect(await !cancelled.attachScreenArea())
        #expect(cancelled.pendingImage == nil)
    }

    @Test func awarenessCommandsAreSearchable() {
        let vm = QuickViewModel()
        let ids = Set(vm.systemCommands.map(\.itemID))
        for id in ["screenshot.window", "screenshot.display", "awareness.area", "awareness.selection", "screenshot.pasteLatest", LatestScreenshotFinder.commandID] {
            #expect(ids.contains(id), "\(id) missing")
        }
        vm.input = "focused window"
        #expect(vm.launcherMatches.contains { if case .item(let item) = $0 { return item.itemID == "screenshot.window" }; return false })
        #expect(vm.systemCommands.first { $0.itemID == "screenshot.window" }?.title == "Send Focused Window to AI")
    }

    @Test func doubleTapDetectorNeedsTwoCleanTapsWithinTheWindow() {
        var detector = ModifierDoubleTapDetector(keyCode: 54, window: 0.35)
        func tap(_ key: UInt16, _ down: Bool, _ time: TimeInterval) -> Bool {
            detector.handleFlagsChanged(keyCode: key, isDown: down, at: time)
        }
        func keyDown() { detector.handleKeyDown() }

        let first = [tap(54, true, 0), tap(54, false, 0.1), tap(54, true, 0.2)]
        #expect(first == [false, false, false])
        #expect(tap(54, false, 0.3), "second clean release within the window completes the double tap")

        // Too slow between taps.
        let slow = [tap(54, true, 1), tap(54, false, 1.1), tap(54, true, 1.6), tap(54, false, 1.7)]
        #expect(slow == [false, false, false, false])

        // A key pressed while ⌘ is held is a shortcut, not a tap.
        let pressed = tap(54, true, 2)
        keyDown()
        let shortcut = [pressed, tap(54, false, 2.1), tap(54, true, 2.2), tap(54, false, 2.3)]
        #expect(shortcut == [false, false, false, false])

        // The left ⌘ key does not count.
        let left = [tap(55, true, 3), tap(55, false, 3.1)]
        #expect(left == [false, false])
    }

    // MARK: Paste latest screenshot

    @Test func pasteLatestScreenshotCopiesTheImageAndPastesIntoThePreviousApp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-paste-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.writeImage(to: folder.appendingPathComponent("Screenshot 2026-08-22 at 12.00.00.png"), text: "x")
        let selection = StubSelection(text: "")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.screenshotsFolder = folder
        vm.rememberSelectionTarget(Self.safari)
        let command = vm.systemCommands.first { $0.itemID == "screenshot.pasteLatest" }!
        await vm.performLauncherItem(command)
        #expect(selection.pastedTo == Self.safari)
        #expect(vm.errorMessage == nil)
    }

    // MARK: OCR search

    @Test func screenshotsAreSearchableByTextInsideTheImage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-ocr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Screenshot 2026-08-22 at 10.00.00.png")
        try Self.writeImage(to: url, text: "INVOICE 4471 ACME")
        try Self.writeImage(to: folder.appendingPathComponent("Screenshot 2026-08-22 at 11.00.00.png"), text: "Meeting notes")

        let index = ScreenshotTextIndex(storeURL: folder.appendingPathComponent("index.json"))
        let vm = QuickViewModel(screenshotTextIndex: index)
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)
        await index.waitForIndexing()
        #expect(index.indexedCount == 2)
        let invoice = vm.screenshotFiles.first { $0.value == url.path || ($0.value as NSString).lastPathComponent == url.lastPathComponent }!
        #expect(vm.screenshotText(for: invoice)?.uppercased().contains("INVOICE") == true)

        vm.input = "acme"
        let hits = vm.catalogMatches
        #expect(hits.count == 1)
        #expect((hits.first?.value as NSString?)?.lastPathComponent == url.lastPathComponent)
        #expect(hits.first?.detail.hasPrefix("Text match") == true)
        vm.input = "invoice 4471"
        #expect(vm.catalogMatches.count == 1)
        vm.input = "nothing-here-xyz"
        #expect(vm.catalogMatches.isEmpty)

        // The index survives a relaunch and is not re-read.
        let reopened = ScreenshotTextIndex(storeURL: folder.appendingPathComponent("index.json"))
        #expect(reopened.indexedCount == 2)
        #expect(reopened.text(for: invoice)?.isEmpty == false)

        vm.settings.screenshotTextSearch = false
        vm.input = "acme"
        #expect(vm.catalogMatches.isEmpty)
    }

    // MARK: Grid and detail pane

    @Test func emojiCatalogIsAGridWithFrequentlyUsedFirst() {
        let store = LauncherUsageStore(fileURL: nil)
        let vm = QuickViewModel(launcherUsage: store)
        vm.enterCatalog(.emoji)
        #expect(vm.isGridCatalog)
        #expect(vm.launcherMatches.count == QuickViewModel.maxGridCells)
        #expect(vm.gridSections.map(\.title) == ["All"])
        #expect(!vm.showsDetailPane)
        #expect(vm.currentPanelWidth == QuickViewModel.panelWidth)

        vm.applicationSelectionIndex = 0
        vm.moveSelectionVertically(1)
        #expect(vm.applicationSelectionIndex == QuickViewModel.gridColumns)
        vm.moveApplicationSelection(1)
        #expect(vm.applicationSelectionIndex == QuickViewModel.gridColumns + 1)

        vm.input = "rocket"
        let rocket = vm.launcherMatches.first!
        vm.learn(rocket)
        vm.input = ""
        #expect(vm.gridSections.map(\.title) == ["Frequently Used", "All"])
        #expect(vm.gridSections.first?.range == 0..<1)
        #expect(vm.launcherMatches.first == rocket)
    }

    @Test func screenshotsAndClipboardShowADetailPaneAndWidenThePanel() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-detail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.writeImage(to: folder.appendingPathComponent("Screenshot 2026-08-22 at 09.00.00.png"), text: "hi")
        let store = ClipboardHistoryStore(fileURL: folder.appendingPathComponent("clipboard-history.json"))
        store.record("some text", limit: 10)

        let vm = QuickViewModel(clipboardHistory: store, screenshotTextIndex: ScreenshotTextIndex(storeURL: nil))
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)
        // The newest file is highlighted straight away; the detail pane opens with it.
        #expect(vm.showsDetailPane, "the newest screenshot leads the list and carries the preview")
        #expect(vm.detailItem?.kind == .screenshot)
        #expect(ScreenshotThumbnailCache.thumbnail(forPath: vm.detailItem!.value) != nil)
        #expect(ScreenshotThumbnailCache.pixelSize(forPath: vm.detailItem!.value) == CGSize(width: 400, height: 120))

        vm.enterCatalog(.clipboard)
        #expect(vm.showsDetailPane)
        #expect(vm.detailItem?.value == "some text")
        vm.handleCommandK()
        // The preview and the wide layout stay put while ⌘K floats over
        // them; collapsing them made the whole window jump.
        #expect(vm.showsDetailPane)
        #expect(vm.currentPanelWidth == QuickViewModel.panelWidthWithDetail)
        vm.closeItemActionPane()
        vm.leaveCatalog()
        #expect(vm.currentPanelWidth == QuickViewModel.panelWidth)
    }

    // MARK: Helpers

    static func writeImage(to url: URL, text: String) throws {
        let size = NSSize(width: 400, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 40),
            .foregroundColor: NSColor.black,
        ]
        NSString(string: text).draw(at: NSPoint(x: 16, y: 36), withAttributes: attributes)
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        // Force 1x pixels so the dimensions test is deterministic.
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSImage(data: rep.representation(using: .png, properties: [:])!)!.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}

@MainActor
private final class FakeAwareness: ScreenAwarenessReading {
    var areaResult: QuickImageAttachment? = QuickImageAttachment(
        data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png", pixelWidth: 2, pixelHeight: 2
    )
    func readContext(for target: SelectionTarget) -> CaptureContext {
        CaptureContext(
            appName: target.applicationName,
            windowTitle: "Manual",
            selectedText: "hello",
            appText: "Get Started\nPermissions",
            pageURL: nil
        )
    }
    func captureArea() async -> QuickImageAttachment? { areaResult }
}

@MainActor
private final class FakeShots: ScreenshotCapturing {
    var isScreenRecordingAuthorized = true
    func capture(_ kind: ScreenshotKind, target: SelectionTarget?, ownProcess: pid_t) async throws -> QuickImageAttachment {
        QuickImageAttachment(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png", pixelWidth: 2, pixelHeight: 2)
    }
}

@MainActor
private final class StubSelection: SelectedTextServicing {
    let text: String
    private(set) var pastedTo: SelectionTarget?
    var isAccessibilityTrusted: Bool { true }
    init(text: String) { self.text = text }
    func currentExternalTarget() -> SelectionTarget? { nil }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : SelectedTextContext(target: target, text: text)
    }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { true }
    func pastePasteboard(to target: SelectionTarget) async -> Bool {
        pastedTo = target
        return true
    }
    func openAccessibilitySettings() {}
}

/// Answers `currentExternalTarget` with a fixed app (or nil) and records the
/// last text paste, so tests can pin the clipboard Return flow.
@MainActor
private final class FallbackPasteSelection: SelectedTextServicing {
    let fallbackTarget: SelectionTarget?
    private(set) var pastedTo: SelectionTarget?
    private(set) var pastedText: String?
    var isAccessibilityTrusted: Bool { true }
    init(fallbackTarget: SelectionTarget?) { self.fallbackTarget = fallbackTarget }
    func currentExternalTarget() -> SelectionTarget? { fallbackTarget }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? { nil }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        pastedText = text
        pastedTo = target
        return true
    }
    func pastePasteboard(to target: SelectionTarget) async -> Bool { true }
    func openAccessibilitySettings() {}
}
