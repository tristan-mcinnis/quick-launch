import CoreGraphics
import Foundation
import HouseChatCore
import Testing
@testable import HouseChatDocuments

@Suite("HouseChatDocuments images")
struct DocumentImageTests {
    @Test("An image is scaled to the long-side cap and normalized")
    func scaling() async throws {
        let picture = Fixtures.textImage("Chart", width: 3_000, height: 1_000)
        let bytes = Fixtures.png(picture)
        let result = try await DocumentExtractor().extract(data: bytes, name: "chart.png")

        let normalized = try #require(result.normalizedImage)
        #expect(normalized.pixelWidth == 2_048)
        #expect(normalized.pixelHeight == 683)
        #expect(normalized.mimeType == "image/png")
        #expect(result.document.kind == .image)
        #expect(result.document.text == nil)
        #expect(result.document.sections.isEmpty)
        #expect(result.document.pixelWidth == 2_048)
        #expect(result.document.normalizedImageMimeType == "image/png")
        // The original bytes are returned byte for byte.
        #expect(result.originalBytes == bytes)
        #expect(result.document.contentHash != nil)
    }

    @Test("A noisy image over the PNG size goes as JPEG")
    func jpegFallback() async throws {
        let side = 1_200
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in pixels.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            pixels[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        let noise = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )!.makeImage()!
        }
        let result = try await DocumentExtractor().extract(data: Fixtures.png(noise), name: "noise.png")
        #expect(result.normalizedImage?.mimeType == "image/jpeg")
        #expect(result.document.normalizedImageMimeType == "image/jpeg")
    }

    @Test("The original keeps EXIF and GPS; the normalized copy strips them")
    func metadata() async throws {
        let bytes = Fixtures.jpegWithMetadata(Fixtures.textImage("EXIF", width: 800, height: 300))
        #expect(Fixtures.exifUserComment(bytes) == Fixtures.exifComment)
        #expect(Fixtures.hasGPS(bytes))

        let result = try await DocumentExtractor().extract(data: bytes, name: "photo.jpg")
        let normalized = try #require(result.normalizedImage)

        // Original bytes are immutable and keep their metadata.
        #expect(result.originalBytes == bytes)
        #expect(Fixtures.exifUserComment(result.originalBytes) == Fixtures.exifComment)
        #expect(Fixtures.hasGPS(result.originalBytes))

        // The transmitted copy carries no metadata.
        #expect(normalized.data != bytes)
        #expect(Fixtures.exifUserComment(normalized.data) == nil)
        #expect(Fixtures.hasGPS(normalized.data) == false)
    }

    @Test("Bytes that are not an image are refused by name")
    func wrongImage() async throws {
        do {
            _ = try await DocumentExtractor().extract(data: Data("no pixels".utf8), name: "fake.png")
            Issue.record("Expected a failure")
        } catch let error as DocumentExtractionError {
            #expect(error == .wrongContent(.image))
        }
    }

    @Test("A file image keeps its path and source metadata")
    func fileImage() async throws {
        let folder = Fixtures.folder("image")
        let url = Fixtures.write(Fixtures.png(Fixtures.textImage("File", width: 600, height: 400)), named: "shot.png", in: folder)
        let result = try await DocumentExtractor().extract(fileURL: url)
        #expect(result.source.kind == .file)
        #expect(result.document.path == url.resolvingSymlinksInPath().path)
        #expect(result.normalizedImage != nil)
    }
}
