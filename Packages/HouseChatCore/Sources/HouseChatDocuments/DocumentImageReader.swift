import CoreGraphics
import Foundation
import HouseChatCore
import ImageIO
import UniformTypeIdentifiers

/// Decodes an attached picture and re-encodes it for a model: long side at
/// most `imageLongSidePixels`, PNG, or JPEG when the PNG is over
/// `imagePNGBytes`. Re-encoding also drops the file's metadata (location,
/// camera, EXIF), so the transmitted copy carries no source metadata. The
/// original bytes are never touched.
enum DocumentImageReader {
    static func normalizedImage(
        from data: Data,
        configuration: DocumentExtractionConfiguration
    ) throws -> DocumentImageBytes {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw DocumentExtractionError.wrongContent(.image) }

        let longSide = min(max(width, height), configuration.imageLongSidePixels)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw DocumentExtractionError.damaged }

        guard let png = encode(image, as: .png, quality: nil) else {
            throw DocumentExtractionError.damaged
        }
        if png.count <= configuration.imagePNGBytes {
            return DocumentImageBytes(
                data: png,
                mimeType: "image/png",
                pixelWidth: image.width,
                pixelHeight: image.height
            )
        }
        guard let jpeg = encode(image, as: .jpeg, quality: 0.85) else {
            throw DocumentExtractionError.damaged
        }
        return DocumentImageBytes(
            data: jpeg,
            mimeType: "image/jpeg",
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
