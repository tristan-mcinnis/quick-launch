import AppKit
import Foundation

/// One pasteboard item as raw data per type, in the order the item listed
/// them. Restoring writes the same bytes back, so a rich copy, an image, a
/// file list or a concealed password returns exactly as it was.
struct PasteboardSnapshot: Equatable, Sendable {
    struct Representation: Equatable, Sendable {
        var type: String
        var data: Data
    }

    var items: [[Representation]]
}

/// What the screenshot hold needs from the clipboard. Only
/// `SystemScreenshotClipboard` touches the real one; tests use a fake.
@MainActor
protocol ScreenshotClipboard: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    /// Replaces the clipboard with one item per screenshot. False when none
    /// of the files is a readable image; the clipboard is then untouched.
    func writeScreenshots(_ urls: [URL]) -> Bool
    func restore(_ snapshot: PasteboardSnapshot)
}

/// Puts each new screenshot on the clipboard for `holdDuration`, then gives
/// the clipboard back. Captures that land while a hold is running join it,
/// so three quick shots paste as three images. The clipboard is restored
/// only if it still holds the screenshots: a copy made during the hold wins.
@MainActor
final class ScreenshotClipboardHold {
    static let defaultHoldDuration: TimeInterval = 5

    private let clipboard: ScreenshotClipboard
    private let holdDuration: TimeInterval
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    private(set) var chain: [URL] = []
    private(set) var deadline: Date?
    private var saved: PasteboardSnapshot?
    private var writtenChangeCount: Int?
    private var expiryTask: Task<Void, Never>?

    init(
        clipboard: ScreenshotClipboard,
        holdDuration: TimeInterval = ScreenshotClipboardHold.defaultHoldDuration,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.clipboard = clipboard
        self.holdDuration = holdDuration
        self.now = now
        self.sleep = sleep
    }

    var isHolding: Bool { deadline != nil }

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let time = now()
        if let deadline, time >= deadline { expireIfDue() }
        let clipboardIsOurs = writtenChangeCount.map { $0 == clipboard.changeCount } ?? false
        if !clipboardIsOurs {
            // No hold, or the user copied something during it: what is on
            // the clipboard now is what comes back afterwards.
            chain = []
            saved = clipboard.snapshot()
        }
        let next = chain + urls.filter { !chain.contains($0) }
        guard clipboard.writeScreenshots(next) else {
            if chain.isEmpty { reset() }
            return
        }
        chain = next
        writtenChangeCount = clipboard.changeCount
        deadline = time.addingTimeInterval(holdDuration)
        scheduleExpiry()
    }

    /// Ends the hold once its deadline has passed.
    func expireIfDue() {
        guard let deadline, now() >= deadline else { return }
        finish()
    }

    /// Ends the hold now (setting turned off, app quitting).
    func finish() {
        if let saved, let writtenChangeCount, clipboard.changeCount == writtenChangeCount {
            clipboard.restore(saved)
        }
        reset()
    }

    private func reset() {
        expiryTask?.cancel()
        expiryTask = nil
        chain = []
        deadline = nil
        saved = nil
        writtenChangeCount = nil
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        let sleep = sleep
        let delay = Duration.milliseconds(Int(holdDuration * 1_000))
        expiryTask = Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.expireIfDue()
        }
    }
}

/// The real clipboard for the hold.
@MainActor
final class SystemScreenshotClipboard: ScreenshotClipboard {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { PasteboardSnapshot.Representation(type: type.rawValue, data: $0) }
            }
        }
        return PasteboardSnapshot(items: items.filter { !$0.isEmpty })
    }

    func writeScreenshots(_ urls: [URL]) -> Bool {
        let items = urls.compactMap(Self.item(for:))
        guard let first = items.first else { return false }
        // Screenshots are on loan: clipboard managers, our own history
        // included, skip transient content (nspasteboard.org).
        for marker in SystemPasteboard.transientMarkers {
            first.setData(Data(), forType: marker)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        // Never offer our own write as a fresh image to attach.
        ClipboardImageReader.suppressAutoOffer(for: pasteboard)
        return true
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { representations in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        ClipboardImageReader.suppressAutoOffer(for: pasteboard)
    }

    /// The image bytes plus the file URL: inline in chat apps, a file in
    /// Finder.
    private static func item(for url: URL) -> NSPasteboardItem? {
        guard let data = try? Data(contentsOf: url),
              data.count <= ClipboardImageReader.maximumBytes,
              let image = NSImage(data: data) else { return nil }
        let item = NSPasteboardItem()
        if url.pathExtension.lowercased() == "png" {
            item.setData(data, forType: .png)
        } else if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        item.setString(url.absoluteString, forType: .fileURL)
        return item
    }
}

/// Screenshot files Quick Launch wrote itself ("Save to Screenshots"). The
/// folder watcher ignores them: an explicit save is not a new capture.
@MainActor
enum OwnScreenshotWrites {
    private(set) static var paths: Set<String> = []

    static func note(_ url: URL) {
        paths.insert(url.standardizedFileURL.path)
    }

    static func contains(_ url: URL) -> Bool {
        paths.contains(url.standardizedFileURL.path)
    }
}

/// Watches the system screenshot folder and reports captures that appear
/// after it started. macOS writes a capture under a hidden name and renames
/// it into place, so a visible screenshot file is complete.
@MainActor
final class ScreenshotFolderWatcher {
    let folder: URL
    private let onNew: @MainActor ([URL]) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var seen: Set<String> = []
    private var scanTask: Task<Void, Never>?
    private var unreadable: [String: Int] = [:]

    init(folder: URL, onNew: @escaping @MainActor ([URL]) -> Void) {
        self.folder = folder
        self.onNew = onNew
    }

    func start() {
        stop()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            AppLog.persistence.error("Watch screenshot folder: open failed")
            return
        }
        seen = Set(Self.screenshotFiles(in: folder).map(\.path))
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        source?.cancel()
        source = nil
    }

    /// Screenshot images in `folder`, oldest capture first.
    nonisolated static func screenshotFiles(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter(isScreenshot)
            .sorted { LatestScreenshotFinder.captureDate(for: $0) < LatestScreenshotFinder.captureDate(for: $1) }
    }

    nonisolated static func isScreenshot(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return LatestScreenshotFinder.imageExtensions.contains(url.pathExtension.lowercased())
            && LatestScreenshotFinder.namePrefixes.contains { name.hasPrefix($0) }
    }

    private func scheduleScan() {
        scanTask?.cancel()
        let folder = folder
        scanTask = Task { @MainActor [weak self] in
            // Several events arrive per capture; read the folder once.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let files = await Task.detached { Self.screenshotFiles(in: folder) }.value
            guard !Task.isCancelled else { return }
            self?.deliver(files)
        }
    }

    private func deliver(_ files: [URL]) {
        var fresh: [URL] = []
        var retry = false
        for url in files where !seen.contains(url.path) {
            if OwnScreenshotWrites.contains(url) {
                seen.insert(url.path)
                continue
            }
            guard NSImage(contentsOf: url) != nil else {
                // Not readable yet (a tool that writes in place): look again
                // shortly, a few times, then give up on it.
                let attempts = unreadable[url.path, default: 0] + 1
                unreadable[url.path] = attempts
                if attempts < 5 { retry = true } else { seen.insert(url.path) }
                continue
            }
            unreadable[url.path] = nil
            seen.insert(url.path)
            fresh.append(url)
        }
        if !fresh.isEmpty { onNew(fresh) }
        if retry {
            scanTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.scheduleScan()
            }
        }
    }
}
