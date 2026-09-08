import Foundation

/// Owner-only blob files holding a clipboard entry's raw pasteboard items.
///
/// Each blob is a single `[[ClipboardRawItem]]` (the faithful pasteboard items)
/// written atomically at mode `0600` in a dedicated directory, keyed by the
/// content hash. Blobs are written once per unique content and never rewritten
/// while referenced; orphans are cleaned up on eviction/clear. Reads for the
/// display form are lazy (on demand), so the history store never loads every
/// blob into memory at launch.
///
/// A small bounded in-memory cache holds the most recently written payloads so
/// a restore immediately after a capture does not wait for the queued disk
/// write; disk is the durable fallback once a cache entry is evicted. Writes
/// run on a private serial queue so the main thread never blocks on disk;
/// `flush()` waits for them (tests, shutdown).
final class ClipboardBlobStore: @unchecked Sendable {
    let directory: URL
    private let queue: DispatchQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Bounded read-through cache: blobKey -> items. Holds the most recent
    /// payloads so a restore right after capture does not hit a not-yet-written
    /// blob. Evicted by byte and count limits; disk is the durable fallback.
    private let cacheLock = NSLock()
    private var memoryCache: [String: [[ClipboardRawItem]]] = [:]
    private var memoryOrder: [String] = []
    private var memoryCacheBytes = 0
    private let memoryCacheByteLimit = 32 * 1_024 * 1_024
    private let memoryCacheCountLimit = 8

    /// - Parameter directory: Where blob files live. `nil` uses the app's
    ///   Application Support `ClipboardBlobs` folder.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        self.queue = DispatchQueue(
            label: "com.tristanmcinnis.quick-launch.clipboard-blobs",
            qos: .utility
        )
    }

    // MARK: Paths

    func blobURL(forKey key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("blob")
    }

    // MARK: Reading

    /// Reads a blob asynchronously, checking the in-memory cache first (fast)
    /// and reading disk off the main thread on a miss. Returns nil when
    /// missing, unreadable, or undecodable.
    func load(key: String) async -> [[ClipboardRawItem]]? {
        if let cached = cacheLookup(key) { return cached }
        return await Task.detached(priority: .utility) { self.readFromDisk(key) }.value
    }

    /// Cheap existence check (a stat, not a decode), used to reconcile a
    /// metadata entry whose blob file is gone.
    func exists(key: String) -> Bool {
        FileManager.default.fileExists(atPath: blobURL(forKey: key).path)
    }

    private func readFromDisk(_ key: String) -> [[ClipboardRawItem]]? {
        let url = blobURL(forKey: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode([[ClipboardRawItem]].self, from: data)
        } catch {
            if !AppLog.isMissingFile(error) {
                AppLog.persistence.error(
                    "Could not read clipboard blob \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            return nil
        }
    }

    /// Runs `block` on the blob queue after every already-queued write or
    /// cleanup. Used to write metadata strictly AFTER the blob(s) it references
    /// land on disk, so a metadata JSON never points at a missing blob.
    func afterPendingWrites(_ block: @escaping @Sendable () -> Void) {
        queue.async { block() }
    }

    // MARK: Writing

    /// Caches `items` in memory immediately (so reads before the disk write
    /// finish) and queues an incremental disk write. If the blob already exists
    /// (content hash is idempotent) the disk write is skipped. Returns immediately.
    func write(key: String, items: [[ClipboardRawItem]]) {
        cacheInMemory(key: key, items: items)
        queue.async { [self] in
            let url = blobURL(forKey: key)
            if FileManager.default.fileExists(atPath: url.path) { return }
            do {
                try writeNow(items, to: url)
            } catch {
                AppLog.persistence.error(
                    "Could not write clipboard blob \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func writeNow(_ items: [[ClipboardRawItem]], to url: URL) throws {
        let data = try encoder.encode(items)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // MARK: Cleanup

    /// Evicts referenced keys from the cache and deletes every blob file in the
    /// directory except those whose key is in `referencedKeys`. Queued; used
    /// after evictions and removals.
    func removeOrphans(except referencedKeys: Set<String>) {
        cacheLock.lock()
        for key in Array(memoryCache.keys) where !referencedKeys.contains(key) {
            removeFromCacheLocked(key)
        }
        cacheLock.unlock()
        queue.async { [self] in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            for file in files {
                let key = file.deletingPathExtension().lastPathComponent
                guard !referencedKeys.contains(key) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Removes the whole blob directory and clears the in-memory cache.
    func clear() {
        cacheLock.lock()
        memoryCache.removeAll()
        memoryOrder.removeAll()
        memoryCacheBytes = 0
        cacheLock.unlock()
        queue.async { [self] in
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Blocks until every queued write or cleanup has finished.
    func flush() {
        queue.sync {}
    }

    // MARK: In-memory cache

    private func cacheInMemory(key: String, items: [[ClipboardRawItem]]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        removeFromCacheLocked(key)
        let bytes = Self.byteCount(of: items)
        memoryCache[key] = items
        memoryOrder.append(key)
        memoryCacheBytes += bytes
        while memoryCacheBytes > memoryCacheByteLimit || memoryCache.count > memoryCacheCountLimit {
            guard let oldest = memoryOrder.first else { break }
            removeFromCacheLocked(oldest)
        }
    }

    private func cacheLookup(_ key: String) -> [[ClipboardRawItem]]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return memoryCache[key]
    }

    private func removeFromCacheLocked(_ key: String) {
        guard let items = memoryCache.removeValue(forKey: key) else { return }
        memoryOrder.removeAll { $0 == key }
        memoryCacheBytes -= Self.byteCount(of: items)
    }

    private static func byteCount(of items: [[ClipboardRawItem]]) -> Int {
        var total = 0
        for item in items {
            for rep in item {
                total += rep.data.count
            }
        }
        return total
    }

    private static func defaultDirectory() -> URL {
        AppPaths.directory("ClipboardBlobs")
    }
}

/// Convenience accessors for file URL parsing shared by the store and the UI.
enum ClipboardFileReference {
    /// Image file types we can safely thumbnail via ImageIO (memory-mapped,
    /// downscaled, so a huge or unusual image is never decoded in full). Kept
    /// case-insensitive by comparing the lowercased extension.
    static let imagePathExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff",
    ]

    /// Finds a human-facing display name for a file URL string
    /// ("file:///tmp/a.txt" or a bare path). Any percent-encoding is decoded,
    /// so "Screenshot%202026.png" shows as "Screenshot 2026.png". This is a
    /// display helper only — it never mutates the stored file URL.
    static func fileName(from urlString: String) -> String? {
        guard !urlString.isEmpty else { return nil }
        // URL.lastPathComponent already percent-decodes a real (file) URL.
        if let url = URL(string: urlString) {
            let name = url.lastPathComponent
            if !name.isEmpty { return name }
        }
        // Bare path that URL(string:) could not split into components:
        // take the last component and decode any percent-encoding.
        let raw = (urlString as NSString).lastPathComponent
        guard !raw.isEmpty else { return nil }
        return raw.removingPercentEncoding ?? raw
    }

    /// The on-disk local path for a file URL string, percent-decoded, for
    /// reading the file's bytes (e.g. a thumbnail). Returns nil for a non-file
    /// URL so the caller never tries to read a remote URL as a local file.
    static func localFilePath(from urlString: String) -> String? {
        guard let url = URL(string: urlString), url.isFileURL else { return nil }
        let path = url.path
        return path.isEmpty ? nil : path
    }

    /// True when a local path points at one of the image file types we can
    /// safely thumbnail. Uses the file extension, then lets ImageIO validate
    /// the actual contents (a mismatched extension simply decodes to nil).
    static func isImageFile(atPath path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imagePathExtensions.contains(ext)
    }
}
