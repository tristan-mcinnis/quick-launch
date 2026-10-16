import AppKit
import Foundation
import Vision

/// On-device reading of text and machine-readable codes from an image, for the
/// "Copy Text from Image" and "Copy Text from QR Code" actions over clipboard
/// images and saved screenshots. Apple's Vision framework only; nothing leaves
/// the Mac. Thin wrappers over the same seams the clipboard OCR index uses, so
/// recognition is one implementation.
enum ClipboardTextRecognition {
    /// Text in image bytes, at the chosen recognition level.
    nonisolated static func text(inImage data: Data, mode: ClipboardOCRMode) async -> String {
        await ScreenshotTextIndex.recognizeText(in: data, mode: mode)
    }

    /// The first machine-readable code string (QR and the other barcode
    /// symbologies Vision reads) in image bytes, or nil when there is none.
    /// Decodes through a bounded thumbnail, so a huge image is never fully
    /// decoded just to look for a code.
    nonisolated static func codeString(inImage data: Data) async -> String? {
        guard let image = ScreenshotTextIndex.downsampledImage(
            in: data,
            maximumPixels: ScreenshotTextIndex.maximumPixels
        ) else { return nil }
        return await codeString(in: image)
    }

    /// The first code string in a saved image file, or nil.
    nonisolated static func codeString(atPath path: String) async -> String? {
        guard let image = ScreenshotTextIndex.downsampledImage(atPath: path, maximumPixels: ScreenshotTextIndex.maximumPixels) else {
            return nil
        }
        return await codeString(in: image)
    }

    nonisolated static func codeString(in image: CGImage) async -> String? {
        let request = DetectBarcodesRequest()
        guard let observations = await AppLog.attemptAsync(
            "Detect codes in image",
            logger: AppLog.recognition,
            { try await request.perform(on: image) }
        ) else { return nil }
        for observation in observations {
            if let value = observation.payloadString, !value.isEmpty {
                return value
            }
            if let data = observation.payloadData,
               let value = String(data: data, encoding: .utf8),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

/// Writes a fresh owner-only copy of a screenshot for annotation, on an I/O
/// actor so no file work runs on the main actor. There is no built-in editor:
/// the reference delegates annotate-image to an installed external host and
/// otherwise to Preview. The copy belongs to the user to edit and keep; Quick
/// Launch never deletes or overwrites it, and never touches the original.
actor ScreenshotAnnotationStore {
    static let previewBundleIdentifier = "com.apple.Preview"
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? AppPaths.directory("ScreenshotAnnotations")
    }

    /// A new copy of `source`, or nil when the source cannot be read. The copy
    /// keeps the source's extension, is written 0600 inside a 0700 folder, and
    /// is never written over an existing file or over the original. The file
    /// is streamed by the filesystem, never loaded whole into memory.
    func newWorkingCopy(of source: URL) -> URL? {
        guard !Task.isCancelled, !ScreenshotLibrary.isUnavailable(source) else { return nil }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let ext = source.pathExtension
            var destination = directory.appendingPathComponent(
                "Annotate \(source.deletingPathExtension().lastPathComponent) \(UUID().uuidString.prefix(8))"
            )
            if !ext.isEmpty { destination.appendPathExtension(ext) }
            guard !fileManager.fileExists(atPath: destination.path) else { return nil }
            try fileManager.copyItem(at: source, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        } catch {
            return nil
        }
    }
}
