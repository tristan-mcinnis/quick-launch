import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class ClipboardHistoryStore: ClipboardHistoryServicing {
    /// Hard bound on the total payload bytes stored across the whole history
    /// (pinned + unpinned). Pins never exceed it; a capture or pin that would
    /// push the history over it is rejected rather than silently dropping pins.
    static let defaultMaximumTotalPayloadBytes = 200 * 1_024 * 1_024
    /// Cap on recognized text kept per entry, so OCR can't bloat metadata.
    static let maximumOCRTextLength = 2_000

    private struct StoredEntry: Codable, Sendable {
        var id: String
        var value: String
        var capturedAt: Date
        /// Optional so files written before pins existed still decode.
        var pinned: Bool?
        /// Optional so files written before multi-type payloads still decode;
        /// those legacy entries are plain text (`payload == nil`). Only light
        /// metadata is stored here; the heavy bytes live in a blob file.
        var payload: StoredPayloadMeta?
    }

    private(set) var entries: [LauncherCatalogItem] = [] {
        didSet { revision &+= 1 }
    }
    private(set) var revision = 0
    @ObservationIgnored private var storedEntries: [StoredEntry] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var lastPasteboardName = NSPasteboard.general.name
    @ObservationIgnored private var pendingReadCount = 0
    private let fileURL: URL
    /// Metadata JSON: small, so it loads and rewrites cheaply. The heavy bytes
    /// are in `blobs` and are written/read incrementally.
    private let file: JSONFileStore<[StoredEntry]>
    private let blobs: ClipboardBlobStore
    let maximumTotalPayloadBytes: Int
    /// Apple Vision recognition over a copied image; injectable for tests.
    private let ocr: @Sendable (Data) async -> String
    /// In-flight OCR keyed by entry id, so tests can await it and stale results
    /// can be ignored after delete/clear.
    @ObservationIgnored private var ocrTasks: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - fileURL: Where the metadata JSON lives (`clipboard-history.json`).
    ///   - blobDirectory: Where blob files live. Defaults to a `ClipboardBlobs`
    ///     folder beside `fileURL`, so tests get their own isolated blobs too.
    ///   - maximumTotalPayloadBytes: Overrides the hard byte bound (tests).
    ///   - ocr: Recognizes text from image bytes. Defaults to Apple Vision via
    ///     `ScreenshotTextIndex`. Inject a deterministic one in tests.
    init(
        fileURL: URL? = nil,
        blobDirectory: URL? = nil,
        maximumTotalPayloadBytes: Int = ClipboardHistoryStore.defaultMaximumTotalPayloadBytes,
        ocr: (@Sendable (Data) async -> String)? = nil
    ) {
        let url = fileURL ?? Self.defaultFileURL()
        self.fileURL = url
        self.file = JSONFileStore(fileURL: url)
        self.maximumTotalPayloadBytes = maximumTotalPayloadBytes
        self.ocr = ocr ?? { await ScreenshotTextIndex.recognizeText(in: $0) }
        self.blobs = ClipboardBlobStore(
            directory: blobDirectory ?? url.deletingLastPathComponent().appendingPathComponent("ClipboardBlobs", isDirectory: true)
        )
        load()
    }

    func startMonitoring(limit: Int) {
        stopMonitoring()
        lastChangeCount = NSPasteboard.general.changeCount
        lastPasteboardName = NSPasteboard.general.name
        pendingReadCount = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.capturePasteboard(limit: limit) }
        }
        timer?.tolerance = 0.4
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    /// Records a plain-text copy. Kept so existing callers and tests that pass
    /// a string still work; richer copies go through `record(_ payload:)`.
    func record(_ text: String, limit: Int) {
        _ = record(ClipboardPayload(kind: .text, text: text), limit: limit)
    }

    /// Records a copy. Returns false (and stores nothing) when the capture is
    /// rejected: empty/oversized text, an entry over the per-entry bounds, or a
    /// copy that would exceed the history's hard byte bound beside the pins.
    @discardableResult
    func record(_ payload: ClipboardPayload, limit: Int) -> Bool {
        let text = payload.text
        guard text.utf8.count <= ClipboardPayload.maximumTextBytes else { return false }
        // Plain-text copies that are empty or whitespace are not a deliberate copy.
        if payload.kind == .text,
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        let id = StableIdentifier.make(payload)
        let existing = storedEntries.first { $0.id == id }
        let blobKey = payload.blobKey ?? (payload.isPlainTextOnly ? nil : payload.items.flatMap { StableIdentifier.make($0) })
        let byteSize = payload.estimatedByteSize
        let meta = StoredPayloadMeta(
            kind: payload.kind,
            imageWidth: payload.imageWidth,
            imageHeight: payload.imageHeight,
            fileURLs: payload.fileURLs,
            byteSize: byteSize,
            blobKey: blobKey,
            firstType: payload.firstType,
            ocrText: existing?.payload?.ocrText
        )

        // Hard bound: pins never exceed it, and a new capture must fit beside
        // the pins (never by silently evicting a pin). A re-copied pinned
        // duplicate already has its bytes reserved (same content hash), so it
        // is never double-counted against the remaining budget.
        let willBePinned = existing?.pinned == true
        let pinnedBesidesExisting = storedEntries
            .filter { $0.pinned == true && $0.id != id }
            .reduce(0) { $0 + ($1.payload?.byteSize ?? 0) }
        let pinnedAfter = pinnedBesidesExisting + (willBePinned ? byteSize : 0)
        guard pinnedAfter <= maximumTotalPayloadBytes else { return false }
        // Only a brand-new unpinned capture must fit beside the pins.
        if !willBePinned {
            guard byteSize <= (maximumTotalPayloadBytes - pinnedBesidesExisting) else { return false }
        }

        let wasPinned = existing?.pinned ?? false
        storedEntries.removeAll { $0.id == id }
        storedEntries.insert(StoredEntry(id: id, value: text, capturedAt: Date(), pinned: wasPinned, payload: meta), at: 0)
        prune(limit: limit)
        // Write the blob only if the entry survived pruning (incremental: the
        // blob store skips a key that already exists).
        if let blobKey, let items = payload.items, storedEntries.contains(where: { $0.id == id }) {
            blobs.write(key: blobKey, items: items)
        }
        rebuildPublicEntries()
        save()
        // Recognize text from a copied image once, off the main thread. Never
        // touches the payload or the restored image; only fills search keywords.
        if meta.ocrText == nil, let imageData = payload.imageData {
            scheduleOCR(id: id, imageData: imageData)
        }
        return true
    }

    func togglePin(_ item: LauncherCatalogItem) {
        guard let index = storedEntries.firstIndex(where: { $0.id == item.itemID }) else { return }
        let entry = storedEntries[index]
        let willPin = entry.pinned != true
        if willPin {
            // Reject pinning that would push the pinned bytes over the hard
            // bound; never silently drop an existing pin to make room.
            let pinnedBytes = storedEntries
                .filter { $0.pinned == true }
                .reduce(0) { $0 + ($1.payload?.byteSize ?? 0) }
            if pinnedBytes + (entry.payload?.byteSize ?? 0) > maximumTotalPayloadBytes {
                return
            }
        }
        storedEntries[index].pinned = willPin
        rebuildPublicEntries()
        save()
    }

    /// Keeps every pinned entry and the newest `limit` unpinned ones. The hard
    /// byte bound is enforced at record/pin time; this is a safety net that
    /// drops the oldest *unpinned* payload entries (never pins) when a history
    /// loaded from disk already exceeds the bound. Pinned bytes are reserved
    /// first, before any unpinned entry is considered, so a set of old pins can
    /// never push the budget negative and silently evict a newer pin.
    private func prune(limit: Int) {
        let cap = max(1, min(limit, 200))
        var kept: [StoredEntry] = []
        var unpinned = 0
        for entry in storedEntries {
            if entry.pinned == true {
                kept.append(entry)
            } else if unpinned < cap {
                kept.append(entry)
                unpinned += 1
            }
        }
        // Reserve ALL pins first; keep the newest unpinned entries that fit in
        // the remainder of the budget. Older unpinned are dropped first, and a
        // set of old pins can never push the budget negative to evict a newer pin.
        let pinnedBytes = kept
            .filter { $0.pinned == true }
            .reduce(0) { $0 + ($1.payload?.byteSize ?? 0) }
        let budgetForUnpinned = max(0, maximumTotalPayloadBytes - pinnedBytes)
        var used = 0
        var result: [StoredEntry] = []
        for entry in kept {
            let size = entry.payload?.byteSize ?? 0
            if entry.pinned == true {
                result.append(entry)
            } else if entry.payload == nil || used + size <= budgetForUnpinned {
                result.append(entry)
                used += size
            }
            // Otherwise drop this unpinned payload entry (would exceed budget).
        }
        storedEntries = result
    }

    func remove(_ item: LauncherCatalogItem) {
        storedEntries.removeAll { $0.id == item.itemID }
        rebuildPublicEntries()
        save()
    }

    func clear() {
        storedEntries.removeAll()
        entries.removeAll()
        if fileURL.path.hasSuffix("/clipboard-history.json") {
            // The metadata file shares no write ordering with the blob queue,
            // so a save already queued there could otherwise land after a
            // plain delete and recreate pre-clear entries. Delete on the same
            // queue, after those writes.
            let fileStore = file
            blobs.afterPendingWrites { [fileStore] in fileStore.deleteNow() }
        }
        blobs.clear()
    }

    /// Runs Apple Vision once per captured image, off the main thread. The
    /// recognition task is tracked so tests can await it and so a result that
    /// arrives after the entry was deleted or history cleared is dropped.
    private func scheduleOCR(id: String, imageData: Data) {
        guard ocrTasks[id] == nil else { return }
        let ocr = self.ocr
        let task = Task { @MainActor [weak self] in
            let text = await Task.detached(priority: .utility) { await ocr(imageData) }.value
            guard let self else { return }
            self.applyOCR(text, to: id)
            self.ocrTasks[id] = nil
        }
        ocrTasks[id] = task
    }

    private func applyOCR(_ rawText: String, to id: String) {
        // Stale guard: the entry may have been deleted or the history cleared
        // while recognition was running.
        guard let index = storedEntries.firstIndex(where: { $0.id == id }) else { return }
        var meta = storedEntries[index].payload ?? StoredPayloadMeta(kind: .text, byteSize: storedEntries[index].value.utf8.count)
        meta.ocrText = Self.capOCR(rawText)
        storedEntries[index].payload = meta
        rebuildPublicEntries()
        save()
    }

    private static func capOCR(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumOCRTextLength else { return trimmed }
        return String(trimmed.prefix(maximumOCRTextLength))
    }

    /// Blocks until every in-flight OCR pass finishes (tests).
    func waitForOCR() async {
        for task in Array(ocrTasks.values) {
            await task.value
        }
    }

    /// The full payload for a stored item, with its raw items loaded from the
    /// blob (in-memory cache first, disk off-main on a miss). Used by previews
    /// and restore. Returns nil when the entry is gone.
    func payload(for item: LauncherCatalogItem) async -> ClipboardPayload? {
        guard let entry = storedEntries.first(where: { $0.id == item.itemID }) else { return nil }
        guard let meta = entry.payload else {
            return ClipboardPayload(kind: .text, text: entry.value)
        }
        let items: [[ClipboardRawItem]]?
        if let key = meta.blobKey {
            items = await blobs.load(key: key)
        } else {
            items = nil
        }
        return ClipboardPayload(
            kind: meta.kind,
            text: entry.value,
            imageWidth: meta.imageWidth,
            imageHeight: meta.imageHeight,
            fileURLs: meta.fileURLs,
            blobKey: meta.blobKey,
            firstType: meta.firstType,
            items: items
        )
    }

    /// Pasteboard markers that mean "do not record": password managers mark
    /// secrets as concealed, and transient/auto-generated content is not a
    /// deliberate user copy. Honouring them keeps passwords out of the
    /// plain-text history file.
    nonisolated private static let ignoredPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    private func capturePasteboard(limit: Int) {
        capture(from: NSPasteboard.general, limit: limit)
    }

    func capture(from pasteboard: NSPasteboard, limit: Int) {
        let changeCount = pasteboard.changeCount
        if pasteboard.name != lastPasteboardName || changeCount != lastChangeCount {
            lastPasteboardName = pasteboard.name
            lastChangeCount = changeCount
            pendingReadCount = 0
        } else if pendingReadCount == 0 {
            return
        }
        if pasteboard.types?.contains(where: Self.ignoredPasteboardTypes.contains) == true {
            pendingReadCount = 0
            return
        }
        guard let payload = ClipboardPayload.extract(from: pasteboard) else {
            // A declared representation may arrive after its ownership change
            // (including Universal Clipboard). Retry on the next monitor ticks;
            // bound retries so an oversized or unsupported copy cannot keep
            // expensive extraction running forever.
            pendingReadCount += 1
            if pendingReadCount >= 5 { pendingReadCount = 0 }
            return
        }
        // Reading promised data can replace the pasteboard or introduce a
        // privacy marker. Never save a mixture of two copies or concealed data.
        guard pasteboard.changeCount == changeCount else { return }
        pendingReadCount = 0
        guard pasteboard.types?.contains(where: Self.ignoredPasteboardTypes.contains) != true else { return }
        _ = record(payload, limit: limit)
    }

    private func rebuildPublicEntries() {
        let ordered = storedEntries.filter { $0.pinned == true } + storedEntries.filter { $0.pinned != true }
        entries = ordered.map { entry in
            let meta = entry.payload
            let kind = meta?.kind ?? .text
            let text = entry.value
            let payload = ClipboardPayload(
                kind: kind,
                text: text,
                imageWidth: meta?.imageWidth,
                imageHeight: meta?.imageHeight,
                fileURLs: meta?.fileURLs ?? [],
                blobKey: meta?.blobKey,
                firstType: meta?.firstType
            )
            let baseTitle = Self.truncate(Self.title(for: kind, text: text, payload: payload))
            let stamp = entry.capturedAt.formatted(date: .abbreviated, time: .shortened)
            let kindLabel = Self.kindLabel(kind)
            let detail = [kindLabel, entry.pinned == true ? "Pinned" : nil, stamp]
                .compactMap { $0 }
                .joined(separator: " · ")
            return LauncherCatalogItem(
                kind: .clipboard,
                itemID: entry.id,
                title: baseTitle,
                detail: detail,
                value: text,
                keywords: Self.keywords(for: kind, text: text, payload: payload, pinned: entry.pinned == true, ocrText: meta?.ocrText ?? ""),
                isPinned: entry.pinned == true,
                clipboardPayload: payload
            )
        }
    }

    private static func title(for kind: ClipboardPayloadKind, text: String, payload: ClipboardPayload?) -> String {
        if !text.isEmpty { return text }
        switch kind {
        case .text, .richText:
            return "Formatted text"
        case .image:
            let dims = payload.map { "\($0.imageWidth ?? 0)×\($0.imageHeight ?? 0)" } ?? ""
            return dims.isEmpty ? "Image" : "Image · \(dims)"
        case .fileURL:
            let firstFile = payload?.fileURLs.first ?? ""
            guard !firstFile.isEmpty else { return "File" }
            return ClipboardFileReference.fileName(from: firstFile) ?? "File"
        case .data:
            return "Data · \(payload?.firstType ?? "unknown")"
        }
    }

    private static func kindLabel(_ kind: ClipboardPayloadKind) -> String? {
        switch kind {
        case .text: return nil
        case .image: return "Image"
        case .richText: return "Formatted text"
        case .fileURL: return "File"
        case .data: return "Data"
        }
    }

    private static func keywords(for kind: ClipboardPayloadKind, text: String, payload: ClipboardPayload?, pinned: Bool, ocrText: String) -> String {
        var words: [String] = []
        if pinned { words.append("pinned") }
        switch kind {
        case .text:
            let word = pinned ? "pinned" : ""
            return ocrText.isEmpty ? word : (word + " " + ocrText)
        case .image:
            words.append("image")
            words.append("picture")
            words.append("photo")
        case .richText:
            words.append("rich")
            words.append("formatted")
        case .fileURL:
            if let name = payload?.fileURLs.first.flatMap({ ClipboardFileReference.fileName(from: $0) }) {
                words.append(name)
            }
            words.append("file")
        case .data:
            words.append("data")
        }
        if !ocrText.isEmpty { words.append(ocrText) }
        if !text.isEmpty { words.append(text) }
        return words.joined(separator: " ")
    }

    private static func truncate(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > 80 else { return normalized }
        return String(normalized.prefix(77)) + "…"
    }

    private func load() {
        guard var decoded = file.load() else { return }
        // Reconcile: a metadata entry pointing at a blob that is gone (e.g. a
        // crash between the blob write and the metadata write) degrades to its
        // plain-text fallback instead of surfacing an empty restore.
        for index in decoded.indices {
            if let key = decoded[index].payload?.blobKey, !blobs.exists(key: key) {
                decoded[index].payload?.blobKey = nil
            }
        }
        storedEntries = decoded
        rebuildPublicEntries()
    }

    /// Persists the metadata JSON strictly AFTER the queued blob writes on the
    /// blob store's serialized queue (no main-thread flush), then reconciles
    /// orphaned blobs. The heavy bytes are written in `record`; here we just
    /// write the small metadata once its blobs are on disk.
    private func save() {
        let snapshot = storedEntries
        let referencedKeys = Set(snapshot.compactMap { $0.payload?.blobKey })
        let fileStore = file
        blobs.afterPendingWrites { [fileStore, snapshot] in
            try? fileStore.saveNow(snapshot)
        }
        blobs.removeOrphans(except: referencedKeys)
    }

    /// Tests: block until queued writes are on disk.
    func waitForPendingWrites() {
        file.flush()
        blobs.flush()
    }

    private static func defaultFileURL() -> URL {
        AppPaths.file("clipboard-history.json")
    }
}
