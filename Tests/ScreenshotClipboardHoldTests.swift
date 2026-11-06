import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@MainActor
private final class FakeScreenshotClipboard: ScreenshotClipboard {
    var changeCount = 0
    var contents: PasteboardSnapshot
    var written: [[URL]] = []
    var restored: [PasteboardSnapshot] = []
    var unreadable: Set<URL> = []

    init(text: String) {
        contents = Self.text(text)
    }

    static func text(_ value: String) -> PasteboardSnapshot {
        PasteboardSnapshot(items: [[.init(type: "public.utf8-plain-text", data: Data(value.utf8))]])
    }

    func snapshot() -> PasteboardSnapshot { contents }

    func writeScreenshots(_ urls: [URL]) -> Bool {
        let readable = urls.filter { !unreadable.contains($0) }
        guard !readable.isEmpty else { return false }
        written.append(readable)
        contents = PasteboardSnapshot(items: readable.map { [.init(type: "public.file-url", data: Data($0.path.utf8))] })
        changeCount += 1
        return true
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        restored.append(snapshot)
        contents = snapshot
        changeCount += 1
    }

    /// The user copies something themselves.
    func userCopies(_ value: String) {
        contents = Self.text(value)
        changeCount += 1
    }
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@Suite("Screenshot clipboard hold")
@MainActor
struct ScreenshotClipboardHoldTests {
    private let shot1 = URL(fileURLWithPath: "/tmp/Screenshot 1.png")
    private let shot2 = URL(fileURLWithPath: "/tmp/Screenshot 2.png")
    private let shot3 = URL(fileURLWithPath: "/tmp/Screenshot 3.png")

    /// The real timer never fires in tests; the clock is moved by hand.
    private func makeHold(_ clipboard: FakeScreenshotClipboard, _ clock: Clock) -> ScreenshotClipboardHold {
        ScreenshotClipboardHold(
            clipboard: clipboard,
            holdDuration: 5,
            now: { clock.now },
            sleep: { _ in throw CancellationError() }
        )
    }

    @Test func aScreenshotIsHeldThenTheOldClipboardReturns() {
        let clipboard = FakeScreenshotClipboard(text: "my copy")
        let clock = Clock()
        let hold = makeHold(clipboard, clock)

        hold.add([shot1])
        #expect(clipboard.written == [[shot1]])

        clock.advance(4.9)
        hold.expireIfDue()
        #expect(clipboard.restored.isEmpty)

        clock.advance(0.2)
        hold.expireIfDue()
        #expect(clipboard.contents == FakeScreenshotClipboard.text("my copy"))
        #expect(!hold.isHolding)
    }

    @Test func quickCapturesChainAndExtendTheHold() {
        let clipboard = FakeScreenshotClipboard(text: "my copy")
        let clock = Clock()
        let hold = makeHold(clipboard, clock)

        hold.add([shot1])
        clock.advance(2)
        hold.add([shot2])
        clock.advance(2)
        hold.add([shot3])
        #expect(clipboard.written.last == [shot1, shot2, shot3])

        // Five seconds from the first shot is not the end: the last one counts.
        clock.advance(2)
        hold.expireIfDue()
        #expect(hold.isHolding)

        clock.advance(3.1)
        hold.expireIfDue()
        #expect(clipboard.contents == FakeScreenshotClipboard.text("my copy"))
        #expect(clipboard.restored.count == 1)
    }

    @Test func aCaptureAfterTheHoldStartsAFreshChain() {
        let clipboard = FakeScreenshotClipboard(text: "my copy")
        let clock = Clock()
        let hold = makeHold(clipboard, clock)

        hold.add([shot1])
        clock.advance(6)
        // The expiry timer is late; the next capture settles the old hold first.
        hold.add([shot2])
        #expect(clipboard.written.last == [shot2])
        clock.advance(5)
        hold.expireIfDue()
        #expect(clipboard.contents == FakeScreenshotClipboard.text("my copy"))
    }

    @Test func aCopyDuringTheHoldIsNeverOverwritten() {
        let clipboard = FakeScreenshotClipboard(text: "my copy")
        let clock = Clock()
        let hold = makeHold(clipboard, clock)

        hold.add([shot1])
        clock.advance(1)
        clipboard.userCopies("new copy")
        clock.advance(5)
        hold.expireIfDue()
        #expect(clipboard.restored.isEmpty)
        #expect(clipboard.contents == FakeScreenshotClipboard.text("new copy"))
    }

    @Test func aCaptureAfterACopyRestoresThatCopy() {
        let clipboard = FakeScreenshotClipboard(text: "my copy")
        let clock = Clock()
        let hold = makeHold(clipboard, clock)

        hold.add([shot1])
        clock.advance(1)
        clipboard.userCopies("new copy")
        clock.advance(1)
        hold.add([shot2])
        #expect(clipboard.written.last == [shot2])
        clock.advance(5)
        hold.expireIfDue()
        #expect(clipboard.contents == FakeScreenshotClipboard.text("new copy"))
    }

    @Test func finishingEarlyRestoresAtOnce() {
        let clipboard = FakeScreenshotClipboard(text: "my copy")
        let clock = Clock()
        let hold = makeHold(clipboard, clock)

        hold.add([shot1])
        hold.finish()
        #expect(clipboard.contents == FakeScreenshotClipboard.text("my copy"))
        #expect(!hold.isHolding)
    }

    @Test func anUnreadableCaptureLeavesTheClipboardAlone() {
        let clipboard = FakeScreenshotClipboard(text: "my copy")
        clipboard.unreadable = [shot1]
        let hold = makeHold(clipboard, Clock())

        hold.add([shot1])
        #expect(clipboard.written.isEmpty)
        #expect(!hold.isHolding)
        #expect(clipboard.changeCount == 0)
    }

    @Test func onlyScreenshotImagesCount() {
        #expect(ScreenshotFolderWatcher.isScreenshot(URL(fileURLWithPath: "/d/Screenshot 2026-11-06 at 10.00.00.png")))
        #expect(ScreenshotFolderWatcher.isScreenshot(URL(fileURLWithPath: "/d/CleanShot 2026-11-06.jpg")))
        #expect(!ScreenshotFolderWatcher.isScreenshot(URL(fileURLWithPath: "/d/Screen Recording 2026-11-06.mov")))
        #expect(!ScreenshotFolderWatcher.isScreenshot(URL(fileURLWithPath: "/d/holiday.png")))
    }

    /// The real pasteboard path, on a private named pasteboard: several
    /// screenshots become several items, marked transient, and the old
    /// contents come back byte for byte.
    @Test func systemClipboardWritesOneItemPerScreenshotAndRestores() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-hold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try (1...3).map { index -> URL in
            let url = folder.appendingPathComponent("Screenshot \(index).png")
            try Self.pngData().write(to: url)
            return url
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-launch-hold-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let clipboard = SystemScreenshotClipboard(pasteboard: pasteboard)

        let saved = clipboard.snapshot()
        #expect(clipboard.writeScreenshots(urls))
        let items = pasteboard.pasteboardItems ?? []
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.data(forType: .png) != nil && $0.string(forType: .fileURL) != nil })
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)

        clipboard.restore(saved)
        #expect(pasteboard.string(forType: .string) == "before")
        #expect(pasteboard.pasteboardItems?.count == 1)
    }

    private static func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }
}
