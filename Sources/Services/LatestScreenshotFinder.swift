import AppKit
import Foundation

/// Finds the newest screenshot macOS saved to disk, for "Attach Latest
/// Screenshot". Reads the same folder the system screenshot tool writes to.
enum LatestScreenshotFinder {
    static let commandID = "screenshot.latest"
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]

    /// `com.apple.screencapture location`, falling back to the Desktop.
    static func screenshotsFolder(fileManager: FileManager = .default) -> URL {
        if let location = CFPreferencesCopyAppValue(
            "location" as CFString,
            "com.apple.screencapture" as CFString
        ) as? String, !location.isEmpty {
            let expanded = (location as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Newest image whose name starts with the screenshot prefix.
    static func newestScreenshot(in folder: URL, fileManager: FileManager = .default) -> URL? {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return urls
            .filter { url in
                imageExtensions.contains(url.pathExtension.lowercased())
                    && url.lastPathComponent.lowercased().hasPrefix("screenshot")
            }
            .max { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left < right
            }
    }

    static func attachment(for url: URL) -> QuickImageAttachment? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() == "png" {
            return ClipboardImageReader.attachment(data: data, mimeType: "image/png")
        }
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return ClipboardImageReader.attachment(data: png, mimeType: "image/png")
    }
}
