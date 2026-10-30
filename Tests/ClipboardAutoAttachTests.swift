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
        vm.settings.attachClipboardImageOnOpen = true
        let retained = QuickImageAttachment(data: Data([1]), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1)
        vm.pendingImage = retained
        let text = NSPasteboard(name: NSPasteboard.Name("quick-launch-test-\(UUID().uuidString)"))
        text.clearContents()
        text.setString("not an image", forType: .string)
        // A stale (already offered) or non-image clipboard must not clear
        // the attachment retained for follow-ups.
        vm.captureImageFromClipboard(from: text)
        vm.captureImageFromClipboard(from: text)
        #expect(vm.pendingImage == retained)
    }

    /// The reported bug: a screenshot copied for somewhere else rode the
    /// next question. Opening never attaches unless the user turned it on.
    @Test func openingAttachesACopiedImageOnlyWhenTurnedOn() throws {
        #expect(!QuickSettings().attachClipboardImageOnOpen)
        let legacy = try JSONDecoder().decode(QuickSettings.self, from: JSONEncoder().encode(QuickSettings()))
        #expect(!legacy.attachClipboardImageOnOpen)

        let vm = QuickViewModel()
        let pasteboard = makePasteboardWithImage()
        vm.captureImageFromClipboard(from: pasteboard)
        #expect(vm.pendingImage == nil, "an image on the clipboard is not context unless asked for")

        vm.settings.attachClipboardImageOnOpen = true
        vm.captureImageFromClipboard(from: pasteboard)
        #expect(vm.pendingImage != nil)
    }
}
