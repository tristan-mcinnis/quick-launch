import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// One clipboard image is offered once. Reopening the overlay with the same
/// clipboard contents must not re-attach the image the user already saw,
/// submitted, or dismissed.
@Suite("Clipboard auto-attach", .serialized)
@MainActor
struct ClipboardAutoAttachTests {

    private func makePasteboardWithImage() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-launch-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        writeImage(to: pasteboard)
        return pasteboard
    }

    private func writeImage(to pasteboard: NSPasteboard) {
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        pasteboard.declareTypes([.png], owner: nil)
        pasteboard.setData(png, forType: .png)
    }

    @Test func sameClipboardIsOfferedOnlyOnce() {
        let pasteboard = makePasteboardWithImage()
        #expect(ClipboardImageReader.attachmentIfFresh(from: pasteboard) != nil)
        #expect(ClipboardImageReader.attachmentIfFresh(from: pasteboard) == nil,
                "an unchanged clipboard must not re-attach on the next open")
        #expect(ClipboardImageReader.attachment(from: pasteboard) != nil,
                "explicit reads keep working regardless of the offer state")
    }

    @Test func aNewCopyIsOfferedAgain() {
        let pasteboard = makePasteboardWithImage()
        #expect(ClipboardImageReader.attachmentIfFresh(from: pasteboard) != nil)
        pasteboard.clearContents()
        writeImage(to: pasteboard)
        #expect(ClipboardImageReader.attachmentIfFresh(from: pasteboard) != nil,
                "a fresh copy bumps the change count and is offered again")
    }

    @Test func nonImageClipboardKeepsARetainedAttachment() {
        let vm = QuickViewModel()
        let retained = QuickImageAttachment(data: Data([1]), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1)
        vm.pendingImage = retained
        // General pasteboard contents are unknown in CI; whatever they are,
        // a stale (already offered) or non-image clipboard must not clear
        // the attachment retained for follow-ups.
        vm.captureImageFromClipboard()
        vm.captureImageFromClipboard()
        #expect(vm.pendingImage != nil)
    }
}
