import Foundation

/// Which cached text a reference points at: the SHA-256 of the source and
/// the extractor version that made the text.
struct AttachmentCacheKey: Hashable, Sendable {
    let contentHash: String
    let extractorVersion: Int

    /// Nil unless the hash is 64 lowercase hex digits and the version is
    /// positive. A key comes from a history file, so it is checked before
    /// it names a file: no path can be smuggled in.
    init?(contentHash: String, extractorVersion: Int) {
        guard contentHash.utf8.count == 64,
              contentHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              extractorVersion > 0
        else { return nil }
        self.contentHash = contentHash
        self.extractorVersion = extractorVersion
    }

    /// The key of a reference, or nil for an image or a reference with no
    /// source hash.
    init?(_ ref: ChatAttachmentRef) {
        guard let hash = ref.contentHash, let version = ref.extractorVersion else { return nil }
        self.init(contentHash: hash, extractorVersion: version)
    }

    /// `<sha256>-v<extractor>.json`.
    var fileName: String { "\(contentHash)-v\(extractorVersion).json" }

    /// The key a cache file name stands for, or nil for any other file.
    init?(fileName: String) {
        guard fileName.hasSuffix(".json") else { return nil }
        let stem = fileName.dropLast(".json".count)
        guard let dash = stem.lastIndex(of: "-"),
              stem[stem.index(after: dash)...].hasPrefix("v"),
              let version = Int(stem[stem.index(dash, offsetBy: 2)...])
        else { return nil }
        self.init(contentHash: String(stem[..<dash]), extractorVersion: version)
    }
}

/// One cached text: what the request builder needs to compose the block
/// again without reading the file.
struct AttachmentCacheEntry: Codable, Equatable, Sendable {
    var contentHash: String
    var extractorVersion: Int
    var text: String
    /// Characters before any cut.
    var characterCount: Int
    var truncation: AttachmentTruncation?
    var notes: [AttachmentNote]
    var kindLabel: String
    var lastUsed: Date
}

/// The owner-only cache of extracted attachment text.
///
/// `Application Support/Quick Launch/attachment-cache/`, folder `0700`,
/// one `<sha256>-v<extractor>.json` per text (`0600`), excluded from
/// backups. The same file attached twice shares one entry.
///
/// - **Expiry:** 7 days after last use. Every read that sends the text
///   touches it (at most one write an hour per entry).
/// - **Size:** 100 MB in all; the least recently used go first.
/// - **Deletion:** by reference (a deleted chat's entries that no other
///   chat still uses) and all at once (Clear History, history turned off,
///   Clear Attachment Cache).
///
/// Images and screenshots never enter it: their references have no key.
/// The last-use time is also the file's modification date, so garbage
/// collection reads only the folder listing, never the texts.
actor AttachmentTextCache {
    /// Touching an entry rewrites it at most this often.
    static let touchInterval: TimeInterval = 60 * 60
    static let folderName = "attachment-cache"

    let directory: URL
    private let lifetime: TimeInterval
    private let byteLimit: Int
    private let now: @Sendable () -> Date
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var prepared = false

    init(
        directory: URL = AppPaths.directory(AttachmentTextCache.folderName),
        lifetime: Duration = AttachmentLimits.cacheLifetime,
        byteLimit: Int = AttachmentLimits.cacheBytes,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.lifetime = LinkAttachmentReader.seconds(lifetime)
        self.byteLimit = byteLimit
        self.now = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    // MARK: Store

    /// Keeps the text of an extraction. An image, or text with no key,
    /// stores nothing and returns nil.
    @discardableResult
    func store(_ extraction: ExtractedAttachment) throws -> AttachmentCacheKey? {
        guard !extraction.ref.kind.isImage,
              let text = extraction.text,
              let key = AttachmentCacheKey(extraction.ref)
        else { return nil }
        try store(AttachmentCacheEntry(
            contentHash: key.contentHash,
            extractorVersion: key.extractorVersion,
            text: text,
            characterCount: extraction.ref.characterCount ?? text.count,
            truncation: extraction.ref.truncation,
            notes: extraction.notes,
            kindLabel: extraction.kindLabel,
            lastUsed: now()
        ))
        return key
    }

    func store(_ entry: AttachmentCacheEntry) throws {
        guard let key = AttachmentCacheKey(
            contentHash: entry.contentHash,
            extractorVersion: entry.extractorVersion
        ) else { return }
        try prepare()
        var entry = entry
        entry.lastUsed = now()
        try write(entry, key: key)
        collectGarbage()
    }

    // MARK: Read

    /// The cached text for a key, or nil when missing or expired (an
    /// expired entry is deleted). `touch` marks it used now.
    func entry(for key: AttachmentCacheKey, touch: Bool = true) -> AttachmentCacheEntry? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              var entry = try? decoder.decode(AttachmentCacheEntry.self, from: data),
              entry.contentHash == key.contentHash,
              entry.extractorVersion == key.extractorVersion
        else { return nil }
        let current = now()
        if current.timeIntervalSince(entry.lastUsed) > lifetime {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if touch, current.timeIntervalSince(entry.lastUsed) >= Self.touchInterval {
            entry.lastUsed = current
            AppLog.attempt("Touch attachment cache entry") { try write(entry, key: key) }
        }
        return entry
    }

    /// The cached text for a reference; nil for an image or a miss.
    func entry(for ref: ChatAttachmentRef, touch: Bool = true) -> AttachmentCacheEntry? {
        AttachmentCacheKey(ref).flatMap { entry(for: $0, touch: touch) }
    }

    /// Marks a key used now, as a request that sends it does.
    func touch(_ key: AttachmentCacheKey) {
        _ = entry(for: key, touch: true)
    }

    func contains(_ key: AttachmentCacheKey) -> Bool {
        entry(for: key, touch: false) != nil
    }

    // MARK: Delete

    func remove(_ key: AttachmentCacheKey) {
        AppLog.attempt("Remove attachment cache entry") {
            try FileManager.default.removeItem(at: fileURL(for: key))
        }
    }

    /// For a chat's delete: drops the entries of `deleted` that no
    /// reference in `stillReferenced` (the other chats) points at.
    func remove(references deleted: [ChatAttachmentRef], keeping stillReferenced: [ChatAttachmentRef]) {
        let keep = Set(stillReferenced.compactMap(AttachmentCacheKey.init))
        for key in Set(deleted.compactMap(AttachmentCacheKey.init)) where !keep.contains(key) {
            remove(key)
        }
    }

    /// Empties the cache: Clear History, history turned off, and Clear
    /// Attachment Cache.
    func clear() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in contents {
            AppLog.attempt("Clear attachment cache") { try FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Garbage collection

    /// Deletes expired entries, then the least recently used until the
    /// total fits the byte limit. Reads only the folder listing.
    func collectGarbage() {
        let current = now()
        var live: [(url: URL, lastUsed: Date, bytes: Int)] = []
        for file in cacheFiles() {
            if current.timeIntervalSince(file.lastUsed) > lifetime {
                AppLog.attempt("Expire attachment cache entry") { try FileManager.default.removeItem(at: file.url) }
            } else {
                live.append(file)
            }
        }
        var total = live.reduce(0) { $0 + $1.bytes }
        guard total > byteLimit else { return }
        for file in live.sorted(by: { $0.lastUsed < $1.lastUsed }) where total > byteLimit {
            AppLog.attempt("Evict attachment cache entry") { try FileManager.default.removeItem(at: file.url) }
            total -= file.bytes
        }
    }

    /// Bytes on disk across the cache's entries.
    func totalBytes() -> Int {
        cacheFiles().reduce(0) { $0 + $1.bytes }
    }

    /// Keys of every entry on disk, expired or not.
    func keys() -> Set<AttachmentCacheKey> {
        Set(cacheFiles().compactMap { AttachmentCacheKey(fileName: $0.url.lastPathComponent) })
    }

    // MARK: Files

    private func fileURL(for key: AttachmentCacheKey) -> URL {
        directory.appendingPathComponent(key.fileName, isDirectory: false)
    }

    /// Creates the folder once per run, owner-only and out of backups, and
    /// holds those on an existing folder too.
    private func prepare() throws {
        guard !prepared else { return }
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        prepared = true
    }

    private func write(_ entry: AttachmentCacheEntry, key: AttachmentCacheKey) throws {
        let url = fileURL(for: key)
        let data = try encoder.encode(entry)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .modificationDate: entry.lastUsed],
            ofItemAtPath: url.path
        )
    }

    private func cacheFiles() -> [(url: URL, lastUsed: Date, bytes: Int)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.compactMap { url in
            guard AttachmentCacheKey(fileName: url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
    }
}
