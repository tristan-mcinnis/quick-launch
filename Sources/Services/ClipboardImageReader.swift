import AppKit
import Foundation

enum ClipboardImageReader {
    static let maximumBytes = 20 * 1_024 * 1_024

    /// The general pasteboard is read on every overlay open. Decoding a
    /// TIFF screenshot costs tens of milliseconds, so the result is kept
    /// until the pasteboard's change count moves.
    @MainActor private static var cache: (changeCount: Int, attachment: QuickImageAttachment?)?

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
