import AppKit
import Foundation
import ImageIO
import Vision

/// On-device text recognition for the screenshots folder, cached on disk so
/// the Screenshots catalog can search words that only exist inside images.
/// Nothing leaves the Mac: Apple's Vision framework does the reading and the
/// index is one JSON file in Application Support.
@MainActor
final class ScreenshotTextIndex {
    struct Entry: Codable, Equatable {
        let text: String
        let modifiedAt: Double
        let byteCount: Int
    }

    struct Progress: Equatable, Sendable {
        var completed = 0
        var total = 0
        var isRunning: Bool { total > 0 && completed < total }
    }

    nonisolated static let languages = ["en-US", "zh-Hans", "zh-Hant"]
    nonisolated static let maximumPixels = 2_000

    private(set) var progress = Progress()
    var onProgress: ((Progress) -> Void)?

    private var entries: [String: Entry]
    private var normalizedCache: [String: String] = [:]
    private var indexingTask: Task<Void, Never>?
    private let storeURL: URL?

    static func defaultStoreURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quick Launch")
            .appendingPathComponent("screenshot-text-index.json")
    }

    /// Pass `nil` for an in-memory index (tests, previews).
    init(storeURL: URL?) {
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            entries = (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        } else {
            entries = [:]
        }
    }

    var indexedCount: Int { entries.count }

    /// Recognized text for a screenshot item, when the file is unchanged.
    func text(for item: LauncherCatalogItem) -> String? {
        guard let entry = entries[item.value], entry.matches(item) else { return nil }
        return entry.text
    }

    /// Lower-cased, whitespace-flattened text for literal matching, memoized.
    func normalizedText(for item: LauncherCatalogItem) -> String? {
        guard let entry = entries[item.value], entry.matches(item) else { return nil }
        if let cached = normalizedCache[item.value] { return cached }
        let normalized = Self.normalize(entry.text)
        normalizedCache[item.value] = normalized
        return normalized
    }

    nonisolated static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Reads anything new or changed, newest first, and drops entries for
    /// files that are gone. Safe to call on every catalog open.
    func refresh(for items: [LauncherCatalogItem]) {
        let known = Set(items.map(\.value))
        if entries.keys.contains(where: { !known.contains($0) }) {
            entries = entries.filter { known.contains($0.key) }
            normalizedCache = normalizedCache.filter { known.contains($0.key) }
            persist()
        }
        let pending = items.filter { entries[$0.value]?.matches($0) != true }
        guard !pending.isEmpty, indexingTask == nil else { return }

        progress = Progress(completed: 0, total: pending.count)
        onProgress?(progress)
        indexingTask = Task { @MainActor [weak self] in
            defer { self?.indexingTask = nil }
            var sinceSave = 0
            for item in pending {
                if Task.isCancelled { break }
                let path = item.value
                let text = await Task.detached(priority: .utility) {
                    await Self.recognizeText(atPath: path)
                }.value
                guard let self else { return }
                self.entries[path] = Entry(
                    text: text,
                    modifiedAt: item.capturedAt?.timeIntervalSince1970 ?? 0,
                    byteCount: Self.byteCount(of: path)
                )
                self.normalizedCache[path] = nil
                self.progress.completed += 1
                self.onProgress?(self.progress)
                sinceSave += 1
                if sinceSave >= 20 {
                    sinceSave = 0
                    self.persist()
                }
            }
            self?.persist()
            if let self { self.onProgress?(self.progress) }
        }
    }

    /// Waits for the current indexing pass, for tests.
    func waitForIndexing() async {
        await indexingTask?.value
    }

    func cancel() {
        indexingTask?.cancel()
        indexingTask = nil
        persist()
    }

    private func persist() {
        guard let storeURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }

    nonisolated static func byteCount(of path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    /// Runs off the main actor; only plain text crosses back.
    nonisolated static func recognizeText(atPath path: String) async -> String {
        guard let image = downsampledImage(atPath: path, maximumPixels: maximumPixels) else { return "" }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        guard let observations = try? await request.perform(on: image) else { return "" }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    nonisolated static func downsampledImage(atPath path: String, maximumPixels: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

extension ScreenshotTextIndex.Entry {
    func matches(_ item: LauncherCatalogItem) -> Bool {
        guard let capturedAt = item.capturedAt else { return false }
        return abs(modifiedAt - capturedAt.timeIntervalSince1970) < 1
            && byteCount == ScreenshotTextIndex.byteCount(of: item.value)
    }
}

/// Small thumbnails for rows and the detail pane, decoded once per file.
@MainActor
enum ScreenshotThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

    static func thumbnail(forPath path: String, maximumPixels: Int = 640) -> NSImage? {
        let key = "\(maximumPixels):\(path)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = ScreenshotTextIndex.downsampledImage(atPath: path, maximumPixels: maximumPixels) else {
            return nil
        }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache.setObject(result, forKey: key)
        return result
    }

    static func pixelSize(forPath path: String) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
