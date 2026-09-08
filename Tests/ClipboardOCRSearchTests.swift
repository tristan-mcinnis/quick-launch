import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// OCR of copied images, reusing the screenshot Apple Vision seam. Recognized
/// text is indexed into clipboard search keywords without ever altering the
/// payload or the restored image. The OCR is injected so every case is
/// deterministic.
@Suite("Clipboard OCR search", .serialized)
@MainActor
struct ClipboardOCRSearchTests {

    private func makeFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-clip-ocr-\(UUID().uuidString)", isDirectory: true)
        return folder
    }

    private func makeStore(
        in folder: URL,
        ocr: (@Sendable (Data) async -> String)? = nil
    ) -> ClipboardHistoryStore {
        ClipboardHistoryStore(
            fileURL: folder.appendingPathComponent("clipboard-history.json"),
            ocr: ocr
        )
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ql-clip-ocr-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

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
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func captureImage(store: ClipboardHistoryStore) -> Data {
        let png = makePNG()
        let pasteboard = makePasteboard()
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(png, forType: .png)
        store.capture(from: pasteboard, limit: 20)
        return png
    }

    private func fullPayload(_ store: ClipboardHistoryStore, _ item: LauncherCatalogItem) async -> ClipboardPayload? {
        store.waitForPendingWrites()
        return await store.payload(for: item)
    }

    @Test func recognizedTextIsIndexedForClipboardSearch() async {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, ocr: { _ in "invoice total 42" })
        _ = captureImage(store: store)
        await store.waitForOCR()

        let vm = QuickViewModel(clipboardHistory: store)
        vm.enterCatalog(.clipboard)
        vm.input = "invoice"
        let matches = vm.catalogMatches
        #expect(matches.contains { $0.clipboardPayload?.kind == .image }, "an image whose OCR contains the query appears in search")
        #expect(matches.contains { $0.keywords.localizedCaseInsensitiveContains("invoice") })
    }

    @Test func ocrTextIsPersistedAndNotRecomputedOnReload() async {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Count OCR invocations to prove reload does not re-run recognition.
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            private(set) var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
        }
        let counter = Counter()
        let store = makeStore(in: folder, ocr: { _ in
            counter.increment()
            return "recognized-phrase"
        })
        _ = captureImage(store: store)
        await store.waitForOCR()
        store.waitForPendingWrites()
        #expect(counter.count == 1)
        #expect(store.entries.first?.keywords.contains("recognized-phrase") == true)

        // Reload: the OCR text is read back from metadata; OCR is NOT re-run.
        let reloaded = makeStore(in: folder, ocr: { _ in
            counter.increment()
            return "different"
        })
        let before = counter.count
        #expect(reloaded.entries.first?.keywords.contains("recognized-phrase") == true)
        #expect(counter.count == before, "reloading already-recognized entries does not re-OCR")
    }

    @Test func ocrNeverAltersTheStoredImage() async {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = makeStore(in: folder, ocr: { _ in "text extracted" })
        let png = captureImage(store: store)
        await store.waitForOCR()
        store.waitForPendingWrites()

        guard let entry = store.entries.first, let payload = await fullPayload(store, entry) else {
            Issue.record("image entry must survive OCR")
            return
        }
        #expect(payload.imageData == png, "recognizing text does not change the image bytes")
        #expect(payload.blobKey != nil)
    }

    @Test func clearDuringOCRDoesNotResurrectAnEntry() async {
        let folder = makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = OCRGate()
        let store = makeStore(in: folder, ocr: { _ in
            await gate.wait()
            return "late result"
        })
        _ = captureImage(store: store)

        // Clear while recognition is still in flight, then release it.
        store.clear()
        await gate.release()
        await store.waitForOCR()

        #expect(store.entries.isEmpty, "a stale OCR result must not recreate a cleared entry")
    }
}

/// A one-shot async gate so a test can hold OCR open, clear history, then release.
actor OCRGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
