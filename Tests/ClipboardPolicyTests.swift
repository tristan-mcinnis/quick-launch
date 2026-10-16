import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Clipboard capture policy: source attribution and exclusions, opt-in age
/// retention that always keeps pins, OCR gating and mode, Universal Clipboard
/// opt-in that never bypasses the privacy markers, rename, and catalog
/// filtering. Everything is deterministic: a stub source resolver and an
/// injected clock, no real window server and no waiting.
@Suite("Clipboard capture policy", .serialized)
@MainActor
struct ClipboardPolicyTests {

    @MainActor
    private final class StubSourceResolver: ClipboardSourceResolving {
        var source: ClipboardSourceInfo?
        init(_ source: ClipboardSourceInfo? = nil) { self.source = source }
        func currentClipboardSource() -> ClipboardSourceInfo? { source }
    }

    private final class TestClock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private func makeFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-clip-policy-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeStore(
        in folder: URL,
        resolver: StubSourceResolver? = nil,
        clock: TestClock? = nil,
        ocr: (@Sendable (Data, ClipboardOCRMode) async -> String)? = nil
    ) -> ClipboardHistoryStore {
        ClipboardHistoryStore(
            fileURL: folder.appendingPathComponent("clipboard-history.json"),
            sourceResolver: resolver,
            now: { clock?.now ?? Date() },
            ocr: ocr
        )
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ql-clip-policy-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func makePNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: Source attribution and exclusions

    @Test func sourceIsAttributedAndTagsFollowTheToggle() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let resolver = StubSourceResolver(ClipboardSourceInfo(bundleIdentifier: "com.example.notes", name: "Notes"))
        let store = makeStore(in: folder, resolver: resolver)

        #expect(store.record(ClipboardPayload(kind: .text, text: "hello"), limit: 10))
        #expect(store.entries.first?.clipboardSource?.name == "Notes")
        #expect(store.entries.first?.clipboardTags == ["Notes"])
        #expect(store.entries.first?.keywords.contains("Notes") == true)

        store.setPolicy(ClipboardCapturePolicy(sourceTagsEnabled: false))
        #expect(store.record(ClipboardPayload(kind: .text, text: "untagged"), limit: 10))
        let untagged = store.entries.first { $0.value == "untagged" }
        #expect(untagged?.clipboardSource?.name == "Notes", "attribution stays even when tags are off")
        #expect(untagged?.clipboardTags == [])
    }

    @Test func disabledSourceIsNeverRecorded() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let resolver = StubSourceResolver(ClipboardSourceInfo(bundleIdentifier: "com.example.secret", name: "Secrets"))
        let store = makeStore(in: folder, resolver: resolver)
        store.setPolicy(ClipboardCapturePolicy(disabledSourceBundleIDs: ["com.example.secret"]))

        #expect(store.record(ClipboardPayload(kind: .text, text: "nope"), limit: 10) == false)
        #expect(store.entries.isEmpty)

        // A capture path is excluded too.
        let pasteboard = makePasteboard()
        pasteboard.setString("also nope", forType: .string)
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.isEmpty)

        // Another app records normally.
        resolver.source = ClipboardSourceInfo(bundleIdentifier: "com.example.notes", name: "Notes")
        #expect(store.record(ClipboardPayload(kind: .text, text: "yes"), limit: 10))
        #expect(store.entries.map(\.value) == ["yes"])
    }

    @Test func excludingASourceDoesNotPurgeExistingHistory() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let resolver = StubSourceResolver(ClipboardSourceInfo(bundleIdentifier: "com.example.notes", name: "Notes"))
        let store = makeStore(in: folder, resolver: resolver)
        #expect(store.record(ClipboardPayload(kind: .text, text: "already saved"), limit: 10))
        #expect(store.entries.count == 1)

        // Adding the app to the skip list stops future captures only: the
        // existing entry is kept, never silently purged.
        store.setPolicy(ClipboardCapturePolicy(disabledSourceBundleIDs: ["com.example.notes"]))
        #expect(store.entries.count == 1)
        #expect(store.entries.first?.value == "already saved")
        #expect(store.record(ClipboardPayload(kind: .text, text: "new copy"), limit: 10) == false)
    }

    // MARK: Privacy markers and Universal Clipboard

    @Test func concealedContentIsStillSkippedWithRemoteEnabled() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let resolver = StubSourceResolver(ClipboardSourceInfo(bundleIdentifier: "com.example.notes", name: "Notes"))
        let store = makeStore(in: folder, resolver: resolver)
        store.setPolicy(ClipboardCapturePolicy(captureRemote: true))

        let pasteboard = makePasteboard()
        pasteboard.declareTypes(
            [.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")],
            owner: nil
        )
        pasteboard.setString("hunter2", forType: .string)
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.isEmpty, "the privacy marker is never bypassed, remote or not")
    }

    @Test func universalClipboardIsOptIn() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let resolver = StubSourceResolver(ClipboardSourceInfo(bundleIdentifier: "com.example.notes", name: "Notes"))
        let store = makeStore(in: folder, resolver: resolver)
        let remote = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.string, remote], owner: nil)
        pasteboard.setString("from the phone", forType: .string)
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.isEmpty, "remote continuity is off by default")

        store.setPolicy(ClipboardCapturePolicy(captureRemote: true))
        let second = makePasteboard()
        second.declareTypes([.string, remote], owner: nil)
        second.setString("from the phone", forType: .string)
        store.capture(from: second, limit: 10)
        #expect(store.entries.map(\.value) == ["from the phone"])
    }

    @Test func universalClipboardMarkerIsMetadataAndNeverStored() async {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, resolver: StubSourceResolver())
        store.setPolicy(ClipboardCapturePolicy(captureRemote: true))

        let remote = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.png, remote], owner: nil)
        pasteboard.setData(makePNG(), forType: .png)
        pasteboard.setData(Data("marker".utf8), forType: remote)
        store.capture(from: pasteboard, limit: 10)

        guard let item = store.entries.first else {
            Issue.record("remote content is allowed, so the copy should be recorded")
            return
        }
        store.waitForPendingWrites()
        let payload = await store.payload(for: item)
        #expect(payload?.kind == .image)
        let types = (payload?.items ?? []).flatMap { $0 }.map(\.type)
        #expect(!types.contains(remote.rawValue), "the marker is metadata, never a stored representation")
    }

    // MARK: Retention

    @Test func retentionExpiresUnpinnedButNeverPins() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 0))
        let resolver = StubSourceResolver(ClipboardSourceInfo(bundleIdentifier: nil, name: "Notes"))
        let store = makeStore(in: folder, resolver: resolver, clock: clock)
        store.setPolicy(ClipboardCapturePolicy(retention: .oneHour))

        store.record(ClipboardPayload(kind: .text, text: "old"), limit: 50)
        guard let old = store.entries.first else {
            Issue.record("first entry should exist")
            return
        }
        store.togglePin(old)

        clock.now = clock.now.addingTimeInterval(2 * 60 * 60)
        store.record(ClipboardPayload(kind: .text, text: "new"), limit: 50)

        #expect(store.entries.count == 2, "the pin is kept and the expired unpinned entry is gone")
        #expect(store.entries.contains { $0.value == "old" && $0.isPinned })
        #expect(store.entries.contains { $0.value == "new" })
    }

    @Test func retentionExpiresUnpinnedOnReload() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 0))
        let store = makeStore(in: folder, resolver: StubSourceResolver(), clock: clock)
        store.record(ClipboardPayload(kind: .text, text: "kept"), limit: 50)
        store.waitForPendingWrites()

        clock.now = clock.now.addingTimeInterval(10 * 24 * 60 * 60)
        let reloaded = makeStore(in: folder, resolver: StubSourceResolver(), clock: clock)
        reloaded.setPolicy(ClipboardCapturePolicy(retention: .oneDay))
        #expect(reloaded.entries.isEmpty, "an opt-in retention expires stale unpinned entries on load")
    }

    @Test func foreverRetentionKeepsEverything() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 0))
        let store = makeStore(in: folder, resolver: StubSourceResolver(), clock: clock)
        store.record(ClipboardPayload(kind: .text, text: "old"), limit: 50)
        clock.now = clock.now.addingTimeInterval(365 * 24 * 60 * 60)
        store.record(ClipboardPayload(kind: .text, text: "new"), limit: 50)
        #expect(store.entries.count == 2, "the default policy never expires an existing history")
    }

    // MARK: OCR gating and mode

    @Test func ocrIsSkippedWhenDisabledAndModeIsPassed() async {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var modes: [ClipboardOCRMode] = []
            func record(_ mode: ClipboardOCRMode) { lock.lock(); modes.append(mode); lock.unlock() }
        }
        let recorder = Recorder()

        let offFolder = makeFolder()
        defer { try? FileManager.default.removeItem(at: offFolder) }
        let off = makeStore(in: offFolder, resolver: StubSourceResolver(), ocr: { _, mode in
            recorder.record(mode)
            return "text"
        })
        off.setPolicy(ClipboardCapturePolicy(ocrEnabled: false, ocrMode: .fast))
        off.record(ClipboardPayload(kind: .image, text: "", items: [[ClipboardRawItem(type: "public.png", data: makePNG())]]), limit: 10)
        await off.waitForOCR()
        #expect(recorder.modes.isEmpty, "OCR does not run when it is off")

        let onFolder = makeFolder()
        defer { try? FileManager.default.removeItem(at: onFolder) }
        let on = makeStore(in: onFolder, resolver: StubSourceResolver(), ocr: { _, mode in
            recorder.record(mode)
            return "text"
        })
        on.setPolicy(ClipboardCapturePolicy(ocrEnabled: true, ocrMode: .fast))
        on.record(ClipboardPayload(kind: .image, text: "", items: [[ClipboardRawItem(type: "public.png", data: makePNG())]]), limit: 10)
        await on.waitForOCR()
        #expect(recorder.modes == [.fast], "the chosen recognition mode reaches recognition")
    }

    // MARK: Rename

    @Test func renameSurvivesReload() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, resolver: StubSourceResolver())
        store.record(ClipboardPayload(kind: .text, text: "the actual clipboard text"), limit: 10)
        guard let item = store.entries.first else {
            Issue.record("entry should exist")
            return
        }
        #expect(store.rename(item, to: "My label"))
        #expect(store.entries.first?.title == "My label")

        store.waitForPendingWrites()
        let reloaded = makeStore(in: folder, resolver: StubSourceResolver())
        #expect(reloaded.entries.first?.title == "My label")
        #expect(reloaded.entries.first?.value == "the actual clipboard text", "renaming never changes the content")
    }

    // MARK: Filtering

    @Test func catalogFilterNarrowsByKindAndPin() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, resolver: StubSourceResolver())
        store.record(ClipboardPayload(kind: .text, text: "alpha"), limit: 20)
        store.record(ClipboardPayload(kind: .image, text: "", items: [[ClipboardRawItem(type: "public.png", data: makePNG())]]), limit: 20)

        let texts = store.entries(matching: ClipboardCatalogFilter(kinds: [.text]))
        #expect(texts.count == 1 && texts.first?.value == "alpha")
        let images = store.entries(matching: ClipboardCatalogFilter(kinds: [.image]))
        #expect(images.count == 1 && images.first?.clipboardPayload?.kind == .image)
        #expect(store.entries(matching: ClipboardCatalogFilter()).count == store.entries.count, "an empty filter matches everything")
        #expect(store.entries(matching: ClipboardCatalogFilter(pinnedOnly: true)).isEmpty)
    }

    // MARK: Attach to the question draft

    @Test func attachTextEntryAddsAChipWithoutSending() async {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, resolver: StubSourceResolver(ClipboardSourceInfo(bundleIdentifier: nil, name: "Notes")))
        store.record(ClipboardPayload(kind: .text, text: "attach me"), limit: 10)
        guard let item = store.entries.first else {
            Issue.record("entry should exist")
            return
        }
        let vm = QuickViewModel(clipboardHistory: store)
        vm.input = "keep this draft"
        let attached = await vm.attachClipboardEntryToQuestion(item)
        #expect(attached)
        #expect(vm.input == "keep this draft", "attaching never clears the draft")
        #expect(vm.attachmentTray.items.count == 1, "the entry becomes one attachment chip")
        #expect(vm.errorMessage == nil)
    }

    @Test func attachImageEntryUsesTheImageBytes() async {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, resolver: StubSourceResolver())
        let png = makePNG()
        store.record(
            ClipboardPayload(kind: .image, text: "", imageWidth: 4, imageHeight: 4, items: [[ClipboardRawItem(type: "public.png", data: png)]]),
            limit: 10
        )
        guard let item = store.entries.first else {
            Issue.record("image entry should exist")
            return
        }
        let vm = QuickViewModel(clipboardHistory: store)
        #expect(await vm.attachClipboardEntryToQuestion(item))
        #expect(vm.attachmentTray.items.first?.kind.isImage == true)
        #expect(vm.pendingImage == nil, "a clipboard image rides the tray, not the screenshot slot")
    }

    @Test func copyTextFromImageFailsCleanlyForANonImage() async {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, resolver: StubSourceResolver())
        store.record(ClipboardPayload(kind: .text, text: "just text"), limit: 10)
        let vm = QuickViewModel(clipboardHistory: store)
        let item = store.entries.first!
        #expect(await vm.copyTextFromImage(item) == false)
        #expect(vm.errorMessage != nil)
    }

    // MARK: Settings

    @Test func legacySettingsDecodeToOptInDefaults() throws {
        let legacy: [String: Any] = [
            "configurationVersion": 26,
            "clipboardHistoryEnabled": true,
            "clipboardHistoryLimit": 50,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let settings = try JSONDecoder().decode(QuickSettings.self, from: data)
        #expect(settings.clipboardHistoryRetention == .forever)
        #expect(settings.clipboardHistoryDisabledSourceBundleIDs.isEmpty)
        #expect(settings.clipboardHistoryCaptureRemote == false)
        #expect(settings.clipboardHistoryOCR == true)
        #expect(settings.clipboardHistorySourceTags == true)
        #expect(settings.screenshotFolders.isEmpty)
        #expect(settings.screenshotIncludeAllMedia == false)
        #expect(settings.screenshotColumns == 3)
        #expect(settings.screenshotUseGrid == false)
        #expect(settings.clipboardCapturePolicy.retention == .forever)
    }

    @Test func newSettingsRoundTrip() throws {
        var settings = QuickSettings()
        settings.clipboardHistoryRetention = .oneWeek
        settings.clipboardHistoryDisabledSourceBundleIDs = ["com.apple.Passwords"]
        settings.clipboardHistoryCaptureRemote = true
        settings.clipboardHistoryOCR = false
        settings.clipboardHistoryOCRMode = .fast
        settings.screenshotFolders = ["~/Pictures/Captures"]
        settings.screenshotIncludeAllMedia = true
        settings.screenshotColumns = 4
        settings.screenshotUseGrid = true

        let back = try JSONDecoder().decode(QuickSettings.self, from: JSONEncoder().encode(settings))
        #expect(back.clipboardHistoryRetention == .oneWeek)
        #expect(back.clipboardHistoryDisabledSourceBundleIDs == ["com.apple.Passwords"])
        #expect(back.clipboardHistoryCaptureRemote == true)
        #expect(back.clipboardHistoryOCR == false)
        #expect(back.clipboardHistoryOCRMode == .fast)
        #expect(back.screenshotFolders == ["~/Pictures/Captures"])
        #expect(back.screenshotIncludeAllMedia == true)
        #expect(back.screenshotColumns == 4)
        #expect(back.screenshotUseGrid == true)
        #expect(back.clipboardCapturePolicy.disabledSourceBundleIDs == ["com.apple.Passwords"])
    }

    // MARK: Paste-as-plain-text end to end

    @Test func pasteAsPlainTextUsesTransientPlainTextAndRoutesToTheTarget() async {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, resolver: StubSourceResolver())
        let rtf = Data("{\\rtf1\\ansi bold}".utf8)
        store.record(ClipboardPayload(kind: .richText, text: "bold text", items: [[
            ClipboardRawItem(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf),
            ClipboardRawItem(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("bold text".utf8)),
        ]]), limit: 10)
        guard let item = store.entries.first else {
            Issue.record("rich entry should exist")
            return
        }

        let pasteboard = RecordingPasteboard()
        let target = SelectionTarget(processIdentifier: 4242, applicationName: "TextEdit")
        let selection = RecordingSelectionService()
        selection.externalTarget = target

        let vm = QuickViewModel(
            selectedTextService: selection,
            clipboardHistory: store,
            pasteboard: pasteboard
        )
        vm.rememberSelectionTarget(target)

        #expect(await vm.pasteClipboardEntryAsPlainText(item))
        #expect(pasteboard.transientWrites == ["bold text"], "delivery writes the plain text, marked transient")
        #expect(pasteboard.plainWrites.isEmpty, "the delivery is transient, so the history skips it")
        #expect(selection.pastePasteboardTargets == [target], "the paste is routed to the captured target")

        // The stored entry keeps its full representation and is not mutated.
        let payload = await store.payload(for: store.entries.first!)
        #expect(payload?.rtf == rtf, "the original rich representation is left intact")
        #expect(store.entries.first?.isPinned == false)
    }

    @Test func transientDeliveryNeverReentersHistory() {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, resolver: StubSourceResolver())
        let pasteboard = makePasteboard()
        pasteboard.declareTypes(
            [.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")],
            owner: nil
        )
        pasteboard.setString("text the app delivered", forType: .string)
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.isEmpty, "an app-delivered transient paste never becomes a history item")
    }

    // MARK: Image MIME and wire bytes

    @Test func imageAttachmentValidatesMIMEAndKeepsWireBytes() throws {
        let jpeg = try makeJPEG()
        let fromJPEG = QuickViewModel.imageAttachment(from: jpeg, mimeType: "image/jpeg")
        #expect(fromJPEG?.mimeType == "image/jpeg", "a JPEG is not relabelled PNG")
        #expect(fromJPEG?.data == jpeg, "the wire bytes are preserved exactly")
        #expect(fromJPEG?.pixelWidth == 4)

        let png = makePNG()
        #expect(QuickViewModel.imageAttachment(from: png, mimeType: "image/png")?.mimeType == "image/png")
        #expect(QuickViewModel.imageAttachment(from: png, mimeType: nil)?.mimeType == "image/png")

        #expect(
            QuickViewModel.imageAttachment(from: Data([0x00, 0x01, 0x02]), mimeType: "image/jpeg") == nil,
            "corrupt bytes are refused, not relabelled"
        )
    }

    // MARK: Clipboard provenance on the attachment chip

    @Test func attachingClipboardTextIsLabelledClipboardNotSelection() async {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, resolver: StubSourceResolver(ClipboardSourceInfo(bundleIdentifier: "com.example.notes", name: "Notes")))
        store.record(ClipboardPayload(kind: .text, text: "attach me"), limit: 10)
        let vm = QuickViewModel(clipboardHistory: store)
        _ = await vm.attachClipboardEntryToQuestion(store.entries.first!)
        let name = vm.attachmentTray.items.first?.name ?? ""
        #expect(name.contains("Clipboard"), "the chip names Clipboard, not a live selection: \(name)")
        #expect(!name.contains("Selection"))
    }

    // MARK: Query grammar

    @Test func clipboardGrammarParsesAndNarrowsTheCatalog() {
        #expect(ClipboardFilterQuery.parse("kind:img pin:true").pinnedOnly)
        #expect(ClipboardFilterQuery.parse("kind:img pin:true").kinds == [.image])
        #expect(ClipboardFilterQuery.parse("kind:img pinned").needle == "pinned", "an unmarked word stays a search needle")
        #expect(ClipboardFilterQuery.parse("source:Notes invoice").source == "Notes")
        #expect(ClipboardFilterQuery.parse("source:Notes invoice").needle == "invoice")
        #expect(ClipboardFilterQuery.parse("notes").needle == "notes")

        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let resolver = StubSourceResolver(ClipboardSourceInfo(bundleIdentifier: "com.example.notes", name: "Notes"))
        let store = makeStore(in: folder, resolver: resolver)
        store.record(ClipboardPayload(kind: .text, text: "alpha note"), limit: 20)
        store.record(ClipboardPayload(kind: .image, text: "", imageWidth: 4, imageHeight: 4, items: [[ClipboardRawItem(type: "public.png", data: makePNG())]]), limit: 20)

        let vm = QuickViewModel(clipboardHistory: store)
        vm.enterCatalog(.clipboard)
        vm.input = "kind:image"
        #expect(vm.catalogMatches.count == 1 && vm.catalogMatches.allSatisfy { $0.clipboardPayload?.kind == .image })
        vm.input = "source:Notes"
        #expect(vm.catalogMatches.count == 2, "both entries were observed from Notes")
        vm.input = "tag:notes alpha"
        #expect(vm.catalogMatches.map(\.value) == ["alpha note"])
        #expect(vm.clipboardFilterHint?.contains("tag:notes") == true)
        vm.input = ""
        #expect(vm.clipboardFilterHint == nil)
    }

    private func makeJPEG() throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .jpeg, properties: [:])!
    }
}

/// A pasteboard that records which write method a delivery used, so a test
/// can prove the transient route.
@MainActor
private final class RecordingPasteboard: PasteboardWriting {
    private(set) var plainWrites: [String] = []
    private(set) var transientWrites: [String] = []
    private var string: String?

    func readString() -> String? { string }
    func writeString(_ text: String) { plainWrites.append(text); string = text }
    func writeTransientString(_ text: String) { transientWrites.append(text); string = text }
    func writeImageFile(at url: URL) -> Bool { true }
}

/// A selection service that records the paste route without touching a real
/// app or the real pasteboard.
@MainActor
private final class RecordingSelectionService: SelectedTextServicing {
    var isAccessibilityTrusted = true
    var externalTarget: SelectionTarget?
    private(set) var pastePasteboardTargets: [SelectionTarget] = []
    private(set) var pastedTexts: [String] = []

    func currentExternalTarget() -> SelectionTarget? { externalTarget }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? { nil }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { false }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        pastedTexts.append(text)
        return true
    }
    func pastePasteboard(to target: SelectionTarget) async -> Bool {
        pastePasteboardTargets.append(target)
        return true
    }
    func openAccessibilitySettings() {}
}
