import AppKit
import Foundation
import Darwin

/// The saved-screenshot files on disk, as launcher items. Mirrors the
/// Tuna Companion screenshots browser: newest first, 240 at most, names
/// that macOS and CleanShot use, date words in the query.
/// Whether a saved capture is an image or a video. A video is listed and
/// previewed through Quick Look; it is never pasted or attached as an image.
enum ScreenshotMediaKind: String, Codable, Sendable, Equatable {
    case image
    case video
}

enum ScreenshotLibrary {
    /// The catalog lists and indexes the newest 400 captures; older files
    /// stay out so scans, thumbnails, and OCR stay fast.
    static let maximumItems = 400
    /// Shared with `LatestScreenshotFinder` so "Paste Latest Screenshot"
    /// finds everything the catalog lists.
    static let namePrefixes: Set<String> = LatestScreenshotFinder.namePrefixes
    /// Video files an include-all-media folder may hold. A video is listed and
    /// previewed through Quick Look; it is never pasted or attached as an image.
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// Every file type the browser lists.
    static var mediaExtensions: Set<String> {
        LatestScreenshotFinder.imageExtensions.union(videoExtensions)
    }

    /// The media kind for a file, or nil when it is not a listed type.
    static func mediaKind(for url: URL) -> ScreenshotMediaKind? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if LatestScreenshotFinder.imageExtensions.contains(ext) { return .image }
        return nil
    }

    /// A file the browser must skip before any read or OCR: a zero-byte file,
    /// a directory or other non-regular entry, an iCloud placeholder, or a
    /// dataless/offline file-provider stub (iCloud or any other provider).
    /// Nothing is downloaded to satisfy a listing.
    static func isUnavailable(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "icloud" { return true }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              (metadata.st_flags & UInt32(SF_DATALESS)) == 0,
              metadata.st_size > 0 else { return true }
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .isRegularFileKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return true }
        if values.isRegularFile == false { return true }
        if let size = values.fileSize, size <= 0 { return true }
        if values.isUbiquitousItem == true,
           let status = values.ubiquitousItemDownloadingStatus,
           status != .current {
            return true
        }
        return false
    }

    static func items(in folder: URL, fileManager: FileManager = .default, now: Date = Date()) -> [LauncherCatalogItem] {
        items(inFolders: [folder], includeAllMedia: false, fileManager: fileManager, now: now)
    }

    /// The saved files across every selected folder root, newest first. Only
    /// the supplied roots are scanned (never home), a folder that repeats is
    /// de-duplicated by standard path, and a missing root is skipped. When
    /// `includeAllMedia` is false only files whose name looks like a capture
    /// are listed; when true every image and video in the roots is listed.
    static func items(
        inFolders folders: [URL],
        includeAllMedia: Bool = false,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> [LauncherCatalogItem] {
        var seen = Set<String>()
        var files: [(url: URL, date: Date, size: Int, media: ScreenshotMediaKind)] = []
        for folder in folders where !folder.path.isEmpty {
            guard let urls = AppLog.attempt("List screenshots in \(folder.lastPathComponent)", {
                try fileManager.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            }) else { continue }
            for url in urls {
                let name = url.lastPathComponent.lowercased()
                guard let media = mediaKind(for: url) else { continue }
                guard includeAllMedia || namePrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                // Skip anything not readable here: a zero-byte file, an iCloud
                // placeholder, or a dataless/offline file-provider stub. The
                // browser never downloads a file to list or read it.
                guard !isUnavailable(url) else { continue }
                let key = url.standardizedFileURL.path
                guard seen.insert(key).inserted else { continue }
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { continue }
                // Capture date, not modification date: a later touch (tagging,
                // OCR, sync) must not float an old shot to the top of the list.
                files.append((url, LatestScreenshotFinder.captureDate(for: url), values.fileSize ?? 0, media))
            }
        }
        return files
            .sorted { lhs, rhs in
                lhs.date == rhs.date ? lhs.url.lastPathComponent > rhs.url.lastPathComponent : lhs.date > rhs.date
            }
            .prefix(maximumItems)
            .map { file in
                LauncherCatalogItem(
                    kind: .screenshot,
                    itemID: "file-" + StableIdentifier.make(file.url.path),
                    title: shortLabel(for: file.url, date: file.date),
                    detail: "\(file.media == .video ? "Video · " : "")\(sizeLabel(file.size)) · \(relativeLabel(file.date, now: now))",
                    value: file.url.path,
                    keywords: file.url.deletingPathExtension().lastPathComponent
                        + (file.media == .video ? " video movie" : ""),
                    capturedAt: file.date,
                    screenshotMediaKind: file.media
                )
            }
    }

    /// "Aug 11, 14:32:07" from "Screenshot 2026-08-11 at 14.32.07.png", else the stem.
    static func shortLabel(for url: URL, date: Date) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let range = stem.range(of: #"(\d{4})-(\d{2})-(\d{2}) at (\d{1,2})\.(\d{2})\.(\d{2})"#, options: .regularExpression) {
            let parts = stem[range].replacingOccurrences(of: " at ", with: "-").split(whereSeparator: { $0 == "-" || $0 == "." })
            if parts.count == 6, let month = Int(parts[1]), let day = Int(parts[2]) {
                let monthName = Calendar.current.shortMonthSymbols[max(0, min(11, month - 1))]
                return "\(monthName) \(day), \(parts[3]):\(parts[4]):\(parts[5])"
            }
        }
        return stem
    }

    static func sizeLabel(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func relativeLabel(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Writes the image to the pasteboard as image data plus a file URL, so
    /// it pastes inline in chat apps and as a file in Finder. The write is
    /// marked as self-made: the next overlay open must not offer the app's
    /// own paste buffer back as an attachment.
    @MainActor static func copyImage(at url: URL, pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = AppLog.attempt("Read screenshot \(url.lastPathComponent)", { try Data(contentsOf: url) }),
              let image = NSImage(data: data) else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects([image, url as NSURL])
        ClipboardImageReader.suppressAutoOffer(for: pasteboard)
        return true
    }

    static func quickLook(_ url: URL) {
        ProcessRunner.launch(
            executable: URL(fileURLWithPath: "/usr/bin/qlmanage"),
            arguments: ["-p", url.path]
        )
    }
}

/// Date words anywhere in a screenshots query: `today acme` and
/// `acme today` both mean today plus the word acme.
struct ScreenshotQuery: Equatable {
    var interval: DateInterval?
    var needle: String

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> ScreenshotQuery {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ScreenshotQuery(interval: nil, needle: trimmed) }
        let startOfToday = calendar.startOfDay(for: now)
        func days(_ count: Int) -> DateInterval {
            DateInterval(start: calendar.date(byAdding: .day, value: -(count - 1), to: startOfToday)!, end: now.addingTimeInterval(1))
        }
        let phrases: [(String, DateInterval)] = [
            ("today", DateInterval(start: startOfToday, end: now.addingTimeInterval(1))),
            ("yesterday", DateInterval(start: calendar.date(byAdding: .day, value: -1, to: startOfToday)!, end: startOfToday)),
            ("this week", DateInterval(start: calendar.dateInterval(of: .weekOfYear, for: now)!.start, end: now.addingTimeInterval(1))),
            ("last week", {
                let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)!
                return DateInterval(start: calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start)!, end: thisWeek.start)
            }()),
            ("this month", DateInterval(start: calendar.dateInterval(of: .month, for: now)!.start, end: now.addingTimeInterval(1))),
        ]
        var working = trimmed
        var intervals: [DateInterval] = []

        /// Removes the first match of `pattern` from `working` and hands it back.
        func takeFirstMatch(_ pattern: String) -> Substring? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            let full = NSRange(working.startIndex..., in: working)
            guard let match = regex.firstMatch(in: working, range: full),
                  let range = Range(match.range, in: working)
            else { return nil }
            let taken = working[range]
            working.removeSubrange(range)
            return taken
        }

        // Longest phrase first so "this month" wins before "this".
        for (phrase, interval) in phrases.sorted(by: { $0.0.count > $1.0.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            if takeFirstMatch(pattern) != nil { intervals.append(interval) }
        }
        // `7d`, `last 30 days`, and a bare ISO date work wherever they sit.
        if let taken = takeFirstMatch(#"\b(\d{1,3})d\b"#), let count = Int(taken.filter(\.isNumber)), count >= 1 {
            intervals.append(days(count))
        }
        if let taken = takeFirstMatch(#"\blast (\d{1,3}) days?\b"#), let count = Int(taken.filter(\.isNumber)), count >= 1 {
            intervals.append(days(count))
        }
        if let taken = takeFirstMatch(#"\b(\d{4})-(\d{2})-(\d{2})\b"#) {
            let parts = taken.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
                let start = calendar.startOfDay(for: day)
                intervals.append(DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!))
            }
        }

        let needle = working.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        var combined = intervals.first
        for interval in intervals.dropFirst() {
            guard let current = combined,
                  let merged = current.intersection(with: interval),
                  // Touching-but-empty overlaps (today + yesterday) filter nothing.
                  merged.duration > 0
            else {
                combined = nil
                break
            }
            combined = merged
        }
        return ScreenshotQuery(interval: combined, needle: needle)
    }
}
