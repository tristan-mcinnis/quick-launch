import AppKit
import Foundation

enum ClipboardImageReader {
    static let maximumBytes = 20 * 1_024 * 1_024

    /// The general pasteboard is read on every overlay open. Decoding a
    /// TIFF screenshot costs tens of milliseconds, so the result is kept
    /// until the pasteboard's change count moves.
    @MainActor private static var cache: (changeCount: Int, attachment: QuickImageAttachment?)?

    /// The pasteboard state last auto-offered on overlay open. One clipboard
    /// image is offered once; reopening the overlay with the same clipboard
    /// contents must not re-attach it.
    @MainActor private static var lastAutoOffered: (name: NSPasteboard.Name, changeCount: Int)?

    /// Auto-attach path for overlay open: returns the clipboard image only
    /// if the pasteboard changed since the last offer. Explicit paste keeps
    /// using `attachment(from:)` and is never suppressed.
    @MainActor static func attachmentIfFresh(
        from pasteboard: NSPasteboard = .general
    ) -> QuickImageAttachment? {
        let name = pasteboard.name
        let changeCount = pasteboard.changeCount
        if let last = lastAutoOffered, last.name == name, last.changeCount == changeCount {
            return nil
        }
        guard let result = attachment(from: pasteboard) else { return nil }
        lastAutoOffered = (name, changeCount)
        return result
    }

    /// Call after the app itself writes an image to the pasteboard (Paste
    /// Image, Copy Image). Self-made clipboard content must never come back
    /// as an auto-attachment on the next overlay open.
    @MainActor static func suppressAutoOffer(for pasteboard: NSPasteboard = .general) {
        lastAutoOffered = (pasteboard.name, pasteboard.changeCount)
    }

    @MainActor static func attachment(
        from pasteboard: NSPasteboard = .general
    ) -> QuickImageAttachment? {
        let isGeneral = pasteboard === NSPasteboard.general
        let changeCount = pasteboard.changeCount
        if isGeneral, let cache, cache.changeCount == changeCount { return cache.attachment }
        let result = read(from: pasteboard)
        if isGeneral { cache = (changeCount, result) }
        return result
    }

    private static func read(from pasteboard: NSPasteboard) -> QuickImageAttachment? {
        if let png = pasteboard.data(forType: .png),
           let attachment = makeAttachment(data: png, mimeType: "image/png") {
            return attachment
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return makeAttachment(data: png, mimeType: "image/png")
    }

    static func attachment(data: Data, mimeType: String) -> QuickImageAttachment? {
        makeAttachment(data: data, mimeType: mimeType)
    }

    private static func makeAttachment(
        data: Data,
        mimeType: String
    ) -> QuickImageAttachment? {
        guard !data.isEmpty,
              data.count <= maximumBytes,
              let image = NSImage(data: data),
              let representation = image.representations.first
        else { return nil }
        return QuickImageAttachment(
            data: data,
            mimeType: mimeType,
            pixelWidth: representation.pixelsWide,
            pixelHeight: representation.pixelsHigh
        )
    }
}
