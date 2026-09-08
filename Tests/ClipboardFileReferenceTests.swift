import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Regression tests for clipboard file references. A Finder/screenshot copy is
/// classified as a File; its filename must be shown decoded (not percent-
/// encoded), an image file reference must be thumbnailable at rest, and the raw
/// file URL must be preserved so a paste still restores the same file. These
/// pin the "blank detail preview + percent-encoded name" bug before the fix.
@Suite("Clipboard file reference display", .serialized)
@MainActor
struct ClipboardFileReferenceTests {

    private func makeStore() -> (ClipboardHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-clipref-\(UUID().uuidString)")
            .appendingPathComponent("clipboard-history.json")
        return (ClipboardHistoryStore(fileURL: url), url)
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-launch-clipref-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    /// A tiny real PNG so the thumbnail path must decode it as an image.
    private func makePNG(width: Int = 8, height: Int = 8) throws -> Data {
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

    // MARK: Filename display must be percent-decoded

    @Test func fileNameDecodesPercentEncoding() {
        // The exact shape from the reported bug: a screenshot copied from
        // Finder carries a percent-encoded file URL.
        #expect(
            ClipboardFileReference.fileName(
                from: "file:///tmp/Screenshot%202026-09-08%20at%2016.09.08.png"
            ) == "Screenshot 2026-09-08 at 16.09.08.png"
        )
    }

    @Test func fileNameDoesNotDoubleDecodeALiteralPercent() {
        // A name that legitimately contains "%25" decodes to a single "%" once;
        // re-decoding the already-decoded component must not break it.
        #expect(ClipboardFileReference.fileName(from: "file:///tmp/100%25.png") == "100%.png")
    }

    @Test func fileNameHandlesABarePath() {
        #expect(ClipboardFileReference.fileName(from: "/tmp/some%20file.txt") == "some file.txt")
    }

    @Test func fileNameLeavesAPlainNameAlone() {
        #expect(ClipboardFileReference.fileName(from: "file:///tmp/plain.png") == "plain.png")
        #expect(ClipboardFileReference.fileName(from: "") == nil)
    }

    // MARK: Local path for reading the file

    @Test func localFilePathDecodesAFileURL() {
        #expect(
            ClipboardFileReference.localFilePath(from: "file:///tmp/Screenshot%202026.png")
                == "/tmp/Screenshot 2026.png"
        )
    }

    @Test func localFilePathRejectsANonFileURL() {
        #expect(ClipboardFileReference.localFilePath(from: "https://example.com/a.png") == nil)
    }

    // MARK: Supported image types

    @Test func isImageFileRecognisesSupportedTypesCaseInsensitively() {
        for ext in ["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff"] {
            #expect(ClipboardFileReference.isImageFile(atPath: "/tmp/photo.\(ext)"))
            #expect(ClipboardFileReference.isImageFile(atPath: "/tmp/photo.\(ext.uppercased())"))
        }
    }

    @Test func isImageFileRejectsNonImages() {
        #expect(!ClipboardFileReference.isImageFile(atPath: "/tmp/notes.txt"))
        #expect(!ClipboardFileReference.isImageFile(atPath: "/tmp/report.pdf"))
        #expect(!ClipboardFileReference.isImageFile(atPath: "/tmp/README"))
    }

    // MARK: The thumbnail decode path (ImageIO) for a real image file

    @Test func imageFileReferenceDecodesToAThumbnail() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-clipref-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try makePNG().write(to: folder.appendingPathComponent("shot.png"))

        let cgImage = ScreenshotTextIndex.downsampledImage(
            atPath: folder.appendingPathComponent("shot.png").path,
            maximumPixels: 640
        )
        #expect(cgImage != nil, "a PNG file reference must be thumbnailable via ImageIO")
        #expect(cgImage?.width == 8)
        #expect(cgImage?.height == 8)
    }

    @Test func nonImageFileReferenceHasNoThumbnail() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-clipref-nonthumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("hello".utf8).write(to: folder.appendingPathComponent("note.txt"))

        #expect(
            ScreenshotTextIndex.downsampledImage(
                atPath: folder.appendingPathComponent("note.txt").path,
                maximumPixels: 640
            ) == nil
        )
    }

    // MARK: Store/capture: raw URL preserved for paste, decoded filename for display

    @Test func storedFileURLKeepsTheEncodedURLButShowsDecodedTitle() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let encoded = "file:///tmp/Screenshot%202026-09-08%20at%2016.09.08.png"

        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.setString(encoded, forType: .fileURL)
        store.capture(from: pasteboard, limit: 10)

        guard let entry = store.entries.first else {
            Issue.record("a file URL copy must be captured")
            return
        }
        #expect(entry.title == "Screenshot 2026-09-08 at 16.09.08.png", "the public row title is the decoded filename")
        #expect(
            entry.clipboardPayload?.fileURLs.first == encoded,
            "the stored file URL is unchanged so a paste restores the same file"
        )

        // The full payload keeps the raw URL too (display decode never mutates it).
        let full = await store.payload(for: entry)
        #expect(full?.fileURLs.first == encoded)
        #expect(full?.kind == .fileURL)
    }

    @Test func capturedPlainFileNameIsNotChanged() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pasteboard = makePasteboard()
        let encoded = "file:///tmp/no spaces.png"

        pasteboard.declareTypes([.fileURL], owner: nil)
        pasteboard.setString(encoded, forType: .fileURL)
        store.capture(from: pasteboard, limit: 10)

        #expect(store.entries.first?.title == "no spaces.png")
    }
}
