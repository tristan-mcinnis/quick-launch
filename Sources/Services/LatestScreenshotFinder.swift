import AppKit
import Foundation

/// Finds the newest screenshot macOS saved to disk, for "Attach Latest
/// Screenshot". Reads the same folder the system screenshot tool writes to.
enum LatestScreenshotFinder {
    static let commandID = "screenshot.latest"
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
    /// Filename prefixes macOS and CleanShot use. One list shared with the
    /// Screenshots catalog, so both agree on what counts as a screenshot.
    static let namePrefixes: Set<String> = ["screenshot", "screen shot", "cleanshot", "scr-"]

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

    /// Newest image whose name starts with a known screenshot prefix.
    static func newestScreenshot(in folder: URL, fileManager: FileManager = .default) -> URL? {
        guard let urls = AppLog.attempt("List screenshots in \(folder.lastPathComponent)", {
            try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        }) else { return nil }
        return urls
            .filter { url in
                imageExtensions.contains(url.pathExtension.lowercased())
                    && namePrefixes.contains { url.lastPathComponent.lowercased().hasPrefix($0) }
            }
            .max { captureDate(for: $0) < captureDate(for: $1) }
    }

    /// When the shot was taken. Touching a file later (tagging, OCR, a sync
    /// pass) moves its modification date, which must not reorder the catalog:
    /// the filename timestamp wins, then the creation date, then modification.
    static func captureDate(for url: URL) -> Date {
        if let parsed = filenameTimestamp(of: url) { return parsed }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }

    /// "Screenshot 2026-08-11 at 14.32.07.png" → that moment, else nil.
    static func filenameTimestamp(of url: URL, calendar: Calendar = .current) -> Date? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let range = stem.range(
            of: #"(\d{4})-(\d{2})-(\d{2}) at (\d{1,2})\.(\d{2})\.(\d{2})"#,
            options: .regularExpression
        ) else { return nil }
        let parts = stem[range]
            .replacingOccurrences(of: " at ", with: "-")
            .split(whereSeparator: { $0 == "-" || $0 == "." })
            .compactMap { Int($0) }
        guard parts.count == 6 else { return nil }
        return calendar.date(from: DateComponents(
            year: parts[0], month: parts[1], day: parts[2],
            hour: parts[3], minute: parts[4], second: parts[5]
        ))
    }

    static func attachment(for url: URL) -> QuickImageAttachment? {
        guard let data = AppLog.attempt("Read screenshot \(url.lastPathComponent)", { try Data(contentsOf: url) }) else { return nil }
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
