import AppKit
import Foundation

/// The saved-screenshot files on disk, as launcher items. Mirrors the
/// Tuna Companion screenshots browser: newest first, 240 at most, names
/// that macOS and CleanShot use, date words in the query.
enum ScreenshotLibrary {
    static let maximumItems = 240
    static let namePrefixes = ["screenshot", "screen shot", "cleanshot", "scr-"]

    static func items(in folder: URL, fileManager: FileManager = .default, now: Date = Date()) -> [LauncherCatalogItem] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let files: [(url: URL, date: Date, size: Int)] = urls.compactMap { url in
            let name = url.lastPathComponent.lowercased()
            guard LatestScreenshotFinder.imageExtensions.contains(url.pathExtension.lowercased()),
                  namePrefixes.contains(where: { name.hasPrefix($0) }),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
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
                    detail: "\(sizeLabel(file.size)) · \(relativeLabel(file.date, now: now))",
                    value: file.url.path,
                    keywords: file.url.deletingPathExtension().lastPathComponent,
                    capturedAt: file.date
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
    /// it pastes inline in chat apps and as a file in Finder.
    static func copyImage(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image, url as NSURL])
        return true
    }

    static func quickLook(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", url.path]
        try? process.run()
    }
}

/// Date words at the front of a screenshots query: `today acme` means both.
struct ScreenshotQuery: Equatable {
    var interval: DateInterval?
    var needle: String

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> ScreenshotQuery {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
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
        for (phrase, interval) in phrases.sorted(by: { $0.0.count > $1.0.count }) {
            if lowered == phrase || lowered.hasPrefix(phrase + " ") {
                return ScreenshotQuery(interval: interval, needle: String(trimmed.dropFirst(phrase.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        if let match = lowered.range(of: #"^(\d{1,3})d\b"#, options: .regularExpression),
           let count = Int(lowered[match].dropLast()) {
            return ScreenshotQuery(interval: days(max(1, count)), needle: String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        if let match = lowered.range(of: #"^last (\d{1,3}) days?\b"#, options: .regularExpression) {
            let digits = lowered[match].filter(\.isNumber)
            if let count = Int(digits) {
                return ScreenshotQuery(interval: days(max(1, count)), needle: String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        if let match = lowered.range(of: #"^(\d{4})-(\d{2})-(\d{2})\b"#, options: .regularExpression) {
            let parts = lowered[match].split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let day = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
                let start = calendar.startOfDay(for: day)
                return ScreenshotQuery(
                    interval: DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!),
                    needle: String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                )
            }
        }
        return ScreenshotQuery(interval: nil, needle: trimmed)
    }
}
