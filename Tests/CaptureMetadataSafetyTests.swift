import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Capture metadata safety", .serialized)
@MainActor
struct CaptureMetadataSafetyTests {
    @Test func pixelMetadataDoesNotFollowAnUnavailableAlias() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let original = folder.appendingPathComponent("image.png")
        try data.write(to: original)
        #expect(ScreenshotThumbnailCache.pixelSize(forPath: original.path) == CGSize(width: 4, height: 4))
        let alias = folder.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        #expect(ScreenshotLibrary.isUnavailable(alias))
        #expect(ScreenshotThumbnailCache.pixelSize(forPath: alias.path) == nil)
    }
}
