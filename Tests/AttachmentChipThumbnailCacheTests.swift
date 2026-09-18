import AppKit
import Testing
@testable import QuickLaunch

/// A picture chip draws a 20 pt thumbnail. Building the `NSImage` from the
/// full PNG inside the body meant a screenshot (several megabytes) was
/// decoded again on every layout pass, and `ChipFlowLayout` asks each chip
/// for its size several times per pass. The cache decodes once per
/// attachment.
@Suite("Attachment chip thumbnails", .serialized)
@MainActor
struct AttachmentChipThumbnailCacheTests {

    private func png() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func thumbnailIsDecodedOncePerAttachment() throws {
        let data = try png()
        let first = try #require(AttachmentThumbnailCache.thumbnail(for: data, key: "attachment-a"))
        let second = try #require(AttachmentThumbnailCache.thumbnail(for: data, key: "attachment-a"))
        #expect(first === second, "the same attachment must not decode again")
        let other = try #require(AttachmentThumbnailCache.thumbnail(for: data, key: "attachment-b"))
        #expect(other !== first, "a different attachment is its own thumbnail")
    }

    @Test func thumbnailFitsTheChip() throws {
        let image = try #require(AttachmentThumbnailCache.thumbnail(for: try png(), key: "size-check"))
        #expect(image.size.width <= 48)
        #expect(image.size.height <= 48)
    }
}
