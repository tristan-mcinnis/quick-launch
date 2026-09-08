import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Multi-type clipboard history: images and rich content must be captured,
/// shown, and restored, not silently dropped because only the string type is
/// read. These tests reproduce the "images aren't captured/shown" bug before
/// the fix, and pin the privacy exclusions, storage bounds, faithful
/// preservation of every pasteboard item and representation, and the blob-back
/// persistence path.
@Suite("Clipboard multi-type history", .serialized)
@MainActor
struct ClipboardImageHistoryTests {

    private func makeStore() -> (ClipboardHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-clipimg-\(UUID().uuidString)")
            .appendingPathComponent("clipboard-history.json")
        return (ClipboardHistoryStore(fileURL: url), url)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-launch-clipimg-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// A tiny real PNG so extraction must decode it as an image.
    private func makePNG(width: Int = 4, height: Int = 4) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func imagePayload(png: Data, width: Int = 4, height: Int = 4) -> ClipboardPayload {
        ClipboardPayload(
            kind: .image,
            text: "",
            imageWidth: width,
            imageHeight: height,
            items: [[ClipboardRawItem(type: NSPasteboard.PasteboardType.png.rawValue, data: png)]]
        )
    }

    private func richPayload(rtf: Data, text: String) -> ClipboardPayload {
        ClipboardPayload(
            kind: .richText,
            text: text,
            items: [[
                ClipboardRawItem(type: NSPasteboard.PasteboardType.rtf.rawValue, data: rtf),
                ClipboardRawItem(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8)),
            ]]
        )
    }

    /// Full (items-loaded) payload for a stored entry, waiting for blob writes.
    private func fullPayload(_ store: ClipboardHistoryStore, _ item: LauncherCatalogItem) async -> ClipboardPayload? {
        store.waitForPendingWrites()
        return await store.payload(for: item)
    }

    // MARK: Reproduction: an image copy must be captured, not dropped.

    @Test func imageOnlyCopyIsCapturedWithImagePayload() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let png = makePNG()

        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(png, forType: .png)
        store.capture(from: pasteboard, limit: 10)

        #expect(store.entries.count == 1, "an image copy must be captured, not dropped")
        guard let entry = store.entries.first, let payload = await fullPayload(store, entry) else {
            Issue.record("image entry must carry a clipboard payload")
            return
        }
        #expect(payload.kind == .image)
        #expect(payload.imageData == png)
        #expect(payload.imageWidth == 4)
        #expect(payload.imageHeight == 4)
    }

    @Test func imageWithTextKeepsBothRepresentations() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let png = makePNG()

        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setData(png, forType: .png)
        pasteboard.setString("https://example.com/a.png", forType: .string)
        store.capture(from: pasteboard, limit: 10)

        guard let entry = store.entries.first, let payload = await fullPayload(store, entry) else {
            Issue.record("image+text copy must be captured")
            return
        }
        #expect(payload.kind == .image, "an image copy restores as an image")
        #expect(payload.imageData == png)
        #expect(payload.text == "https://example.com/a.png", "text is kept for search and preview")
    }

    @Test func richTextCopyIsCapturedAsRichText() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let rtf = Data("{\\rtf1\\ansi hello}".utf8)

        pasteboard.declareTypes([.rtf, .string], owner: nil)
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString("hello", forType: .string)
        store.capture(from: pasteboard, limit: 10)

        guard let entry = store.entries.first, let payload = await fullPayload(store, entry) else {
            Issue.record("rich text copy must be captured")
            return
        }
        #expect(payload.kind == .richText)
        #expect(payload.rtf == rtf)
        #expect(payload.text == "hello")
    }

    // MARK: Multiple items and other representations are preserved faithfully.

    @Test func fileURLCopyIsCapturedAsFileURL() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let fileURL = URL(fileURLWithPath: "/tmp/some file.txt").absoluteString

        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.setString(fileURL, forType: .fileURL)
        store.capture(from: pasteboard, limit: 10)

        guard let entry = store.entries.first, let payload = await fullPayload(store, entry) else {
            Issue.record("file URL copy must be captured")
            return
        }
        #expect(payload.kind == .fileURL)
        #expect(payload.fileURLs == [fileURL])
    }

    @Test func multipleFileItemsAreKeptAndRestored() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let first = URL(fileURLWithPath: "/tmp/a.txt").absoluteString
        let second = URL(fileURLWithPath: "/tmp/b.txt").absoluteString

        let firstItem = NSPasteboardItem()
        firstItem.setString(first, forType: .fileURL)
        let secondItem = NSPasteboardItem()
        secondItem.setString(second, forType: .fileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects([firstItem, secondItem])
        store.capture(from: pasteboard, limit: 10)

        guard let entry = store.entries.first, let payload = await fullPayload(store, entry) else {
            Issue.record("multi-file copy must be captured")
            return
        }
        #expect(payload.kind == .fileURL)
        #expect(payload.fileURLs.sorted() == [first, second].sorted(), "every file URL is kept")

        let target = makePasteboard()
        payload.write(to: target)
        let restoredPaths = (target.readObjects(forClasses: [NSURL.self], options: nil) as? [NSURL])?.map(\.path) ?? []
        #expect(Set(restoredPaths) == Set(["/tmp/a.txt", "/tmp/b.txt"]), "each file URL is restored as its own item")
    }

    @Test func pdfOnlyCopyIsRetained() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let pdf = Data("%PDF-1.4 fake".utf8)

        pasteboard.declareTypes([.pdf], owner: nil)
        pasteboard.setData(pdf, forType: .pdf)
        store.capture(from: pasteboard, limit: 10)

        guard let entry = store.entries.first, let payload = await fullPayload(store, entry) else {
            Issue.record("PDF-only copy must be captured, not dropped")
            return
        }
        #expect(payload.kind == .data)
        let types = payload.items?.flatMap { $0 }.map(\.type) ?? []
        #expect(types.contains(NSPasteboard.PasteboardType.pdf.rawValue))
    }

    @Test func customPlusTextRoundTripKeepsBoth() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let customType = NSPasteboard.PasteboardType("com.example.widget.serialized")
        let custom = Data([0x01, 0x02, 0x03])

        pasteboard.declareTypes([.string, customType], owner: nil)
        pasteboard.setString("hello", forType: .string)
        pasteboard.setData(custom, forType: customType)
        store.capture(from: pasteboard, limit: 10)

        guard let entry = store.entries.first, let payload = await fullPayload(store, entry) else {
            Issue.record("custom+text copy must be captured")
            return
        }
        #expect(payload.kind == .text)
        #expect(payload.text == "hello")
        let reps = payload.items?.flatMap { $0 } ?? []
        #expect(reps.contains { $0.type == customType.rawValue && $0.data == custom }, "custom format survives alongside text")
        #expect(payload.isPlainTextOnly == false, "text with a custom format is not plain text")

        let target = makePasteboard()
        payload.write(to: target)
        #expect(target.data(forType: customType) == custom)
        #expect(target.string(forType: .string) == "hello")
    }

    @Test func opaqueOnlyCopyIsCapturedBounded() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let opaqueType = NSPasteboard.PasteboardType("com.example.widget.serialized")
        pasteboard.declareTypes([opaqueType], owner: nil)
        pasteboard.setData(Data([0x01, 0x02, 0x03]), forType: opaqueType)
        store.capture(from: pasteboard, limit: 10)

        guard let entry = store.entries.first, let payload = await fullPayload(store, entry) else {
            Issue.record("opaque-only copy must be captured")
            return
        }
        #expect(payload.kind == .data)
        #expect(payload.items?.flatMap { $0 }.contains { $0.type == opaqueType.rawValue } == true)
    }

    @Test func plainTextCopyIsNotMisclassifiedAsData() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        // A normal text copy also carries a UTF-16 plain-text public type; that
        // must never make the entry "data" instead of "text".
        let utf16Type = NSPasteboard.PasteboardType("public.utf16-external-plain-text")
        pasteboard.declareTypes([.string, utf16Type], owner: nil)
        pasteboard.setString("hello", forType: .string)
        pasteboard.setData(Data("hello".utf8), forType: utf16Type)
        store.capture(from: pasteboard, limit: 10)

        guard let entry = store.entries.first, let payload = await fullPayload(store, entry) else {
            Issue.record("plain text copy must be captured")
            return
        }
        #expect(payload.kind == .text)
        #expect(payload.text == "hello")
        #expect(payload.imageData == nil)
        #expect(payload.isPlainTextOnly, "a plain text copy needs no blob")
    }

    // MARK: Restore must reproduce the original representation.

    @Test func restoreWritesImageBackToThePasteboard() {
        let pasteboard = makePasteboard()
        let png = makePNG(width: 8, height: 8)
        imagePayload(png: png, width: 8, height: 8).write(to: pasteboard)
        #expect(pasteboard.data(forType: .png) == png, "restoring an image must reproduce the image data")
        #expect(pasteboard.availableType(from: [.png]) != nil)
    }

    @Test func restoreWritesRichTextAndTextBack() {
        let pasteboard = makePasteboard()
        let rtf = Data("{\\rtf1\\ansi bold}".utf8)
        richPayload(rtf: rtf, text: "bold").write(to: pasteboard)
        #expect(pasteboard.data(forType: .rtf) == rtf)
        #expect(pasteboard.string(forType: .string) == "bold")
    }

    // MARK: Privacy exclusions still hold for non-text content.

    @Test func concealedImageCopyIsNeverRecorded() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let png = makePNG()

        pasteboard.declareTypes([.png, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setData(png, forType: .png)
        store.capture(from: pasteboard, limit: 10)

        #expect(store.entries.isEmpty, "concealed image content must never be stored")
    }

    // MARK: Bounded storage still applies to payload entries.

    @Test func entryLimitStillBoundsPayloadEntriesAndKeepsPins() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let png = makePNG()

        store.record(imagePayload(png: png), limit: 10)
        store.record(ClipboardPayload(kind: .text, text: "one"), limit: 10)
        store.record(ClipboardPayload(kind: .text, text: "two"), limit: 10)
        #expect(store.entries.count == 3, "entries within the limit are all kept")

        // Pin the image so a tight limit still keeps it.
        guard let imageItem = store.entries.first(where: { $0.clipboardPayload?.kind == .image }) else {
            Issue.record("image entry should exist to pin")
            return
        }
        store.togglePin(imageItem)
        store.record(ClipboardPayload(kind: .text, text: "three"), limit: 1)
        store.record(ClipboardPayload(kind: .text, text: "four"), limit: 1)

        // The pinned image survives plus the single newest unpinned entry.
        #expect(store.entries.count == 2)
        #expect(store.entries.contains { $0.isPinned })
    }

    @Test func newCaptureAndPinRespectTheHardByteBound() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-clip-pin-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("clipboard-history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        // Small budget so the policy is exercised cheaply: fits 3 small image
        // pins (3000 bytes) and a 4th capture is refused.
        let budget = 3 * 1000 + 1
        let store = ClipboardHistoryStore(fileURL: url, maximumTotalPayloadBytes: budget)

        var accepted = 0
        for i in 0..<5 {
            let img = imagePayload(png: Data(repeating: UInt8(i + 1), count: 1000))
            if store.record(img, limit: 50),
               let item = store.entries.first(where: { $0.clipboardPayload?.kind == .image && !$0.isPinned }) {
                store.togglePin(item)
                accepted += 1
            }
        }

        #expect(accepted == 3, "only captures that fit beside the pins are kept")
        #expect(store.entries.filter(\.isPinned).count == 3, "the three fits are pinned and none are dropped")
    }

    @Test func capRejectsOversizedTIFFAndImage() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        // A TIFF over the per-image cap must be rejected (the same path that
        // used to bypass the cap by converting to PNG).
        let hugeTIFF = Data(repeating: 0, count: ClipboardPayload.maximumImageBytes + 1)
        pasteboard.declareTypes([.tiff], owner: nil)
        pasteboard.setData(hugeTIFF, forType: .tiff)
        store.capture(from: pasteboard, limit: 10)

        #expect(store.entries.isEmpty, "an oversized TIFF image must be rejected, not stored")
    }

    @Test func payloadByteAccountingIsDeterministic() {
        let image = imagePayload(
            png: Data(repeating: 0xAB, count: 512),
            width: 4,
            height: 4
        )
        let text = ClipboardPayload(kind: .text, text: "hello")
        #expect(image.estimatedByteSize == 512)
        #expect(text.estimatedByteSize == "hello".utf8.count)
        #expect(image.isPlainTextOnly == false, "an image payload is not plain text")
        #expect(image.hasImageRepresentation)
        #expect(text.isPlainTextOnly, "plain text needs no blob")
    }

    @Test func persistenceReloadPreservesMultiTypePayload() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        store.record(ClipboardPayload(
            kind: .text,
            text: "hello",
            items: [[
                ClipboardRawItem(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("hello".utf8)),
                ClipboardRawItem(type: "com.example.custom", data: Data([0x9, 0x8, 0x7])),
            ]]
        ), limit: 10)
        store.waitForPendingWrites()

        let reloaded = ClipboardHistoryStore(fileURL: url)
        reloaded.waitForPendingWrites()
        guard let entry = reloaded.entries.first, let payload = await reloaded.payload(for: entry) else {
            Issue.record("reloaded history must keep the payload")
            return
        }
        #expect(payload.text == "hello")
        let reps = payload.items?.flatMap { $0 } ?? []
        #expect(reps.contains { $0.type == "com.example.custom" && $0.data == Data([0x9, 0x8, 0x7]) })
    }

    @Test func clearedHistoryRemovesBlobs() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let png = makePNG()
        store.record(imagePayload(png: png), limit: 10)
        store.waitForPendingWrites()
        let blobURL = url.deletingLastPathComponent().appendingPathComponent("ClipboardBlobs", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: blobURL.path))

        store.clear()
        store.waitForPendingWrites()
        #expect(!FileManager.default.fileExists(atPath: blobURL.path), "clearing history removes blob files")
    }

    // MARK: Regression: blob read-before-flush and pin-reservation

    @Test func immediateRestoreDoesNotWaitForBlobFlush() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-clip-immediate-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("clipboard-history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardHistoryStore(fileURL: url, ocr: { _ in "" })
        let png = makePNG()
        // Record, then restore immediately — no waitForPendingWrites().
        store.record(imagePayload(png: png), limit: 10)
        guard let entry = store.entries.first, let payload = await store.payload(for: entry) else {
            Issue.record("restore right after capture must read the cached blob")
            return
        }
        #expect(payload.imageData == png, "the blob is served from the pending cache, not an empty disk")
    }

    @Test func olderPinsReserveBudgetBeforeUnpinned() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-clip-pinreserve-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("clipboard-history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let budget = 1_000
        let store = ClipboardHistoryStore(fileURL: url, maximumTotalPayloadBytes: budget, ocr: { _ in "" })

        for i in 0..<2 {
            let img = imagePayload(png: Data(repeating: UInt8(i + 1), count: 200))
            _ = store.record(img, limit: 50)
            if let item = store.entries.first(where: { $0.clipboardPayload?.kind == .image && !$0.isPinned }) {
                store.togglePin(item)
            }
        }
        #expect(store.entries.filter(\.isPinned).count == 2)

        // A new unpinned entry that fits beside the pins (1000 - 400 = 600) is kept.
        let fits = imagePayload(png: Data(repeating: 0x40, count: 200))
        #expect(store.record(fits, limit: 50) == true)
        #expect(store.entries.filter(\.isPinned).count == 2, "pins are preserved and reserved first")

        // A new unpinned entry that would push past the bound is rejected.
        let tooBig = imagePayload(png: Data(repeating: 0x50, count: 700))
        #expect(store.record(tooBig, limit: 50) == false)
        #expect(store.entries.filter(\.isPinned).count == 2, "rejecting a capture never drops a pin")
    }

    @Test func recopyingAPinnedEntryMoreThanHalfBudgetIsAllowed() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-clip-recappin-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("clipboard-history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let budget = 1_000
        let store = ClipboardHistoryStore(fileURL: url, maximumTotalPayloadBytes: budget, ocr: { _ in "" })

        let big = imagePayload(png: Data(repeating: 0x60, count: 600)) // 600 > half of 1000
        #expect(store.record(big, limit: 50))
        if let item = store.entries.first(where: { $0.clipboardPayload?.kind == .image && !$0.isPinned }) {
            store.togglePin(item)
        }
        #expect(store.entries.filter(\.isPinned).count == 1)

        // Re-copying the same pinned content must not double-count its bytes.
        #expect(store.record(big, limit: 50) == true, "a pinned duplicate is admitted without double-counting")
        #expect(store.entries.filter(\.isPinned).count == 1)
    }

    // MARK: Missing-blob safety, blob-then-metadata ordering, read-through async

    @Test func writeGuardDoesNotClearPasteboardForMissingBlob() {
        let pasteboard = makePasteboard()
        pasteboard.setString("sentinel", forType: .string)
        // A display-form payload with a blobKey but no loaded items and no text
        // (an image whose blob is missing).
        let payload = ClipboardPayload(kind: .image, text: "", blobKey: "deadbeef")
        #expect(payload.write(to: pasteboard) == false)
        #expect(pasteboard.string(forType: .string) == "sentinel", "a write with nothing to write must not clear the pasteboard")
    }

    @Test func reconcilesMissingBlobOnReload() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-clip-reconciling-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("clipboard-history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardHistoryStore(fileURL: url, ocr: { _ in "" })
        let png = makePNG()
        store.record(imagePayload(png: png), limit: 10)
        store.waitForPendingWrites()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("ClipboardBlobs", isDirectory: true))

        let reloaded = ClipboardHistoryStore(fileURL: url, ocr: { _ in "" })
        let target = makePasteboard()
        target.setString("sentinel", forType: .string)
        guard let entry = reloaded.entries.first, let payload = await reloaded.payload(for: entry) else {
            Issue.record("reloaded entry survives a missing blob")
            return
        }
        #expect(payload.write(to: target) == false, "a degraded missing-blob entry writes nothing")
        #expect(target.string(forType: .string) == "sentinel")
    }

    @Test func blobWrittenBeforeMetadataAndReloadSeesPayload() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-clip-ordered-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("clipboard-history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardHistoryStore(fileURL: url, ocr: { _ in "" })
        let png = makePNG()
        store.record(imagePayload(png: png), limit: 10)
        store.waitForPendingWrites()

        guard let blobKey = store.entries.first?.clipboardPayload?.blobKey else {
            Issue.record("an image entry has a blob key")
            return
        }
        let blobURL = url.deletingLastPathComponent().appendingPathComponent("ClipboardBlobs").appendingPathComponent(blobKey + ".blob")
        #expect(FileManager.default.fileExists(atPath: blobURL.path), "the blob is written, so metadata never points at a missing blob")

        let reloaded = ClipboardHistoryStore(fileURL: url, ocr: { _ in "" })
        guard let entry = reloaded.entries.first, let payload = await reloaded.payload(for: entry) else {
            Issue.record("reload restores the payload")
            return
        }
        #expect(payload.imageData == png)
    }

    @Test func asyncPayloadLoadIsReadThroughCacheOrDisk() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-clip-async-\(UUID().uuidString)", isDirectory: true)
        let url = folder.appendingPathComponent("clipboard-history.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ClipboardHistoryStore(fileURL: url, ocr: { _ in "" })
        let png = makePNG()
        store.record(imagePayload(png: png), limit: 10)
        // No flush: an immediate async load is served by the read-through cache.
        let cached = await store.payload(for: store.entries.first!)
        #expect(cached?.imageData == png, "an immediate async load is served by the in-memory cache")

        store.waitForPendingWrites()
        // A fresh store reads from disk.
        let reloaded = ClipboardHistoryStore(fileURL: url, ocr: { _ in "" })
        let fromDisk = await reloaded.payload(for: reloaded.entries.first!)
        #expect(fromDisk?.imageData == png, "a reloaded entry loads its blob from disk")
    }
}
