import AppKit
import Foundation

enum ClipboardImageReader {
    static let maximumBytes = 20 * 1_024 * 1_024

    static func attachment(
        from pasteboard: NSPasteboard = .general
    ) -> QuickImageAttachment? {
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
