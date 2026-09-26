import Foundation
import CryptoKit
import Security

/// What happened in one launcher or AI interaction.
///
/// The journal records *outcomes*, never input. It exists so the user can
/// review how the launcher actually gets used: which choices stuck, which
/// searches were typed and dropped, which retries followed, and which actions
/// or answers failed or were cancelled.
enum InteractionJournalEventKind: String, Codable, Sendable, CaseIterable {
    /// A launcher row was chosen and acted on.
    case selectionAccepted
    /// A query was typed, nothing was chosen, and nothing was answered.
    case searchAbandoned
    /// The same query was abandoned again inside the retry window.
    case searchRetried
    /// An action (app, item, folder, write-back) reported a failure.
    case actionFailed
    /// A command action completed and produced output.
    case actionSucceeded
    /// A running command action was stopped.
    case actionCancelled
    /// A model request failed before or during streaming.
    case aiFailed
    /// A streaming model request was cancelled.
    case aiCancelled
    /// A model request produced an answer.
    case aiSucceeded
    /// A hotkey ran an item without the launcher being used.
    case directHotkeyUse
    /// A row this build does not know about, kept so an older journal file
    /// still loads. Never written by this build.
    case unknown

    /// Group heading used by the Markdown export and the review list.
    var reviewTitle: String {
        switch self {
        case .selectionAccepted: "Choices"
        case .searchAbandoned: "Abandoned searches"
        case .searchRetried: "Retries"
        case .actionFailed: "Action failures"
        case .actionSucceeded: "Command actions"
        case .actionCancelled: "Action cancellations"
        case .aiFailed: "AI failures"
        case .aiCancelled: "AI cancellations"
        case .aiSucceeded: "AI answers"
        case .directHotkeyUse: "Direct hotkey uses"
        case .unknown: "Other"
        }
    }

    /// Short label for one row in the settings review list.
    var shortTitle: String {
        switch self {
        case .selectionAccepted: "Chose"
        case .searchAbandoned: "Abandoned"
        case .searchRetried: "Retried"
        case .actionFailed: "Action failed"
        case .actionSucceeded: "Command ran"
        case .actionCancelled: "Action stopped"
        case .aiFailed: "AI failed"
        case .aiCancelled: "AI stopped"
        case .aiSucceeded: "AI answered"
        case .directHotkeyUse: "Hotkey"
        case .unknown: "Other"
        }
    }
}

/// One journal row. Every field is an identifier, a category code, a coarse
/// band, or a keyed digest — never clipboard, snippet, chat, selection, file,
/// query, or answer text.
struct InteractionJournalEvent: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var date: Date = Date()
    var kind: InteractionJournalEventKind = .unknown
    /// Catalog scope the interaction happened in ("root" outside a catalog).
    var scope: String = LauncherUsageStore.rootScope
    /// Sanitized launcher item identifier (bundle id, command id, action id).
    /// Never the item's value; dynamic or content-bearing identifiers are
    /// replaced by a keyed digest (see `InteractionJournalStore.sanitizedItemID`).
    var itemID: String?
    /// Keyed digest of the folded, length-bounded query, prefixed with the
    /// digest version. The query text is never written and the digest cannot
    /// be recomputed without this Mac's journal key.
    var queryFingerprint: String?
    /// Coarse size of the folded query ("1-3", "8-15", "32+"). Deliberately a
    /// band, not an exact character count.
    var queryLengthBucket: String?
    /// Short machine-readable category ("missing-model", "provider-error").
    var detail: String?
    /// True once the user marked this interaction as the wrong choice. Set by
    /// an explicit, reversible action in Settings; never inferred, and never
    /// fed back into ranking.
    var markedAccidental: Bool = false

    /// Digest scheme that produced `queryFingerprint`. `1` was the unkeyed
    /// SHA-256 of the first build of this feature; `2` is the keyed HMAC.
    /// Rows of different versions are never correlated with each other.
    var fingerprintVersion: Int = InteractionJournalStore.fingerprintVersion

    /// True only for a row that was normalized while loading an older file.
    /// In memory only: never encoded, and the store rewrites the file when any
    /// row sets it, so the discarded keyless digest does not stay on disk.
    var wasMigrated: Bool = false

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: InteractionJournalEventKind,
        scope: String = LauncherUsageStore.rootScope,
        itemID: String? = nil,
        queryFingerprint: String? = nil,
        queryLengthBucket: String? = nil,
        detail: String? = nil,
        markedAccidental: Bool = false,
        fingerprintVersion: Int = InteractionJournalStore.fingerprintVersion
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.scope = scope
        self.itemID = itemID
        self.queryFingerprint = queryFingerprint
        self.queryLengthBucket = queryLengthBucket
        self.detail = detail
        self.markedAccidental = markedAccidental
        self.fingerprintVersion = fingerprintVersion
    }

    /// Tolerant decode: a file written by an earlier build, or by a later one
    /// with a kind this build does not know, still loads. Unknown kinds become
    /// `.unknown` and an old exact `queryLength` is folded into a band; the
    /// keyless fingerprint of the first build is dropped, because the whole
    /// point of the keyed digest is that it cannot be recomputed or reversed
    /// outside this Mac. The row keeps its kind, scope, item, detail, and time.
    init(from decoder: Decoder) throws {        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        let rawKind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        kind = InteractionJournalEventKind(rawValue: rawKind) ?? .unknown
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? LauncherUsageStore.rootScope
        itemID = try c.decodeIfPresent(String.self, forKey: .itemID)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        markedAccidental = try c.decodeIfPresent(Bool.self, forKey: .markedAccidental) ?? false

        let legacyLength = try c.decodeIfPresent(Int.self, forKey: .queryLength)
        let bucket = try c.decodeIfPresent(String.self, forKey: .queryLengthBucket)
        queryLengthBucket = bucket ?? legacyLength.flatMap(InteractionJournalStore.lengthBucket(forFoldedLength:))

        let version = try c.decodeIfPresent(Int.self, forKey: .fingerprintVersion) ?? 1
        let fingerprint = try c.decodeIfPresent(String.self, forKey: .queryFingerprint)
        if version >= InteractionJournalStore.fingerprintVersion {
            queryFingerprint = fingerprint
            fingerprintVersion = InteractionJournalStore.fingerprintVersion
        } else {
            queryFingerprint = nil
            fingerprintVersion = InteractionJournalStore.fingerprintVersion
            wasMigrated = true
        }
        if bucket == nil, legacyLength != nil { wasMigrated = true }
    }

    /// Explicit so the retired `queryLength` and the in-memory `wasMigrated`
    /// never reach the file. `queryLength` is still accepted on read.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(date, forKey: .date)
        try c.encode(kind, forKey: .kind)
        try c.encode(scope, forKey: .scope)
        try c.encodeIfPresent(itemID, forKey: .itemID)
        try c.encodeIfPresent(queryFingerprint, forKey: .queryFingerprint)
        try c.encodeIfPresent(queryLengthBucket, forKey: .queryLengthBucket)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encode(markedAccidental, forKey: .markedAccidental)
        try c.encode(fingerprintVersion, forKey: .fingerprintVersion)
    }

    /// Includes the retired `queryLength` key so an older file still decodes.
    enum CodingKeys: String, CodingKey {
        case id, date, kind, scope, itemID, queryFingerprint, queryLength,
             queryLengthBucket, detail, markedAccidental, fingerprintVersion
    }
}

/// A bounded, local-only, owner-only log of launcher and AI outcomes.
///
/// Design rules:
/// - **Content-free.** Events carry identifiers, category codes, a coarse
///   query-size band, and a *keyed* digest of the query — never the text. The
///   launcher input field doubles as the AI prompt box, so no typed text is
///   ever written to this file. Dynamic or content-bearing item identifiers
///   (a typed URL, a window title) are replaced by a keyed digest too.
/// - **Keyed.** The digest is HMAC-SHA256 under a random 32-byte key generated
///   on first use and stored owner-only beside the journal. Repeats still
///   correlate on this Mac; the digest means nothing anywhere else, and cannot
///   be brute-forced from a short query without the key file.
/// - **Bounded.** Events older than `retentionDays` are dropped on every
///   record, and the log is trimmed to `eventCap` newest events.
/// - **Atomic and owner-only.** Persistence goes through `JSONFileStore`
///   (temp file + rename, `0600`); the key file is written the same way.
/// - **Not a ranking input.** Nothing here feeds `LauncherUsageStore` or
///   `LauncherRanker`. The accidental marker is review metadata only.
/// - **No duplicates.** An identical event (kind + scope + item + query
///   digest) inside `dedupeWindow` is dropped, so one user action that passes
///   several choke points is one row.
@MainActor
final class InteractionJournalStore {
    private struct Snapshot: Codable, Sendable {
        var version: Int = 2
        var events: [InteractionJournalEvent]
    }

    nonisolated static let defaultRetentionDays = 30
    nonisolated static let defaultEventCap = 2000
    nonisolated static let minimumEventCap = 100
    nonisolated static let maximumEventCap = 20_000
    nonisolated static let minimumRetentionDays = 1
    nonisolated static let maximumRetentionDays = 365
    /// Two identical events this close together are one user action.
    nonisolated static let dedupeWindow: TimeInterval = 2
    /// An abandoned query repeated inside this window is a retry.
    nonisolated static let retryWindow: TimeInterval = 10 * 60
    nonisolated static let digestLength = 12
    /// Current digest scheme. Bump if the keyed construction ever changes.
    nonisolated static let fingerprintVersion = 2
    nonisolated static let keyByteCount = 32
    /// Longest identifier kept verbatim; anything longer is a digest.
    nonisolated static let maximumItemIDLength = 96

    /// Identifier prefixes whose payload is a stable, non-content identity.
    /// One entry per `LauncherItemKind`, plus the catalog roots and the
    /// saved-action hotkey rows (`askAI:ask` is a fixed id; the typed question
    /// lives in the row's title and detail, which the journal never stores).
    /// Anything not listed — a window title, a future dynamic id — is replaced
    /// by a keyed digest.
    nonisolated static let safeItemIDPrefixes = [
        "application:", "catalog:", "command:", "folder:", "snippet:",
        "quickLink:", "clipboard:", "emoji:", "screenshot:", "conversation:",
        "answer:", "askAI:", "color:", "action:",
    ]

    /// Identifier shapes the journal always re-keys, whatever their kind
    /// prefix says.
    ///
    /// A typed URL row is identified by `StableIdentifier`, an FNV-1a content
    /// hash with no key — the launcher has to compute it without one, so that
    /// identity is stable and irreversible-for-practical-purposes but **not**
    /// cryptographic: a short or guessable address can be brute-forced. The
    /// journal does not inherit that property. It re-keys the row id under this
    /// install's HMAC key before writing, so the stored id is only reversible
    /// with `interaction-journal-key`. Ranking keeps using the launcher's own
    /// id unchanged.
    nonisolated static let alwaysDigestedItemIDMarkers = ["typed:"]

    /// Oldest first, so the newest event is always `events.last`.
    private(set) var events: [InteractionJournalEvent] = []
    /// How long an event stays in the log. Clamped to the documented range.
    var retentionDays: Int = InteractionJournalStore.defaultRetentionDays {
        didSet { retentionDays = Self.clampRetention(retentionDays) }
    }
    /// How many events the log keeps. Clamped to the documented range.
    var eventCap: Int = InteractionJournalStore.defaultEventCap {
        didSet { eventCap = Self.clampEventCap(eventCap) }
    }
    var now: () -> Date

    /// Bytes of the newest encoding, for the Settings status line.
    private(set) var byteSize: Int = 0

    private let fileURL: URL?
    private let file: JSONFileStore<Snapshot>?
    private let digestKey: SymmetricKey

    /// Pass `nil` for an in-memory store (tests, previews). An in-memory store
    /// still gets an ephemeral random key, so it exercises the keyed path and
    /// can correlate repeats for as long as it lives.
    init(
        fileURL: URL?,
        now: @escaping () -> Date = Date.init,
        retentionDays: Int = InteractionJournalStore.defaultRetentionDays,
        eventCap: Int = InteractionJournalStore.defaultEventCap,
        keyURL: URL? = nil
    ) {
        self.fileURL = fileURL
        self.file = fileURL.map { JSONFileStore(fileURL: $0) }
        self.now = now
        self.retentionDays = Self.clampRetention(retentionDays)
        self.eventCap = Self.clampEventCap(eventCap)
        self.digestKey = SymmetricKey(data: Self.loadOrCreateKey(
            at: keyURL ?? fileURL.map(Self.keyURL(forJournalAt:))
        ))
        load()
    }

    nonisolated static func defaultFileURL() -> URL {
        AppPaths.file("interaction-journal.json")
    }

    /// File name of the random digest key. It always sits beside its journal.
    nonisolated static let keyFileName = "interaction-journal-key"

    /// Owner-only random key, beside the default journal. Never leaves this Mac.
    nonisolated static func defaultKeyURL() -> URL {
        AppPaths.file(keyFileName)
    }

    /// The key belonging to a given journal file.
    ///
    /// Derived from the journal's own directory rather than hard-coded, so a
    /// store pointed at any other file — a test's temporary folder, an export
    /// sandbox — never reads or writes the live app's key. For
    /// `defaultFileURL()` this is exactly `defaultKeyURL()`.
    nonisolated static func keyURL(forJournalAt fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(keyFileName)
    }

    nonisolated static func clampRetention(_ days: Int) -> Int {
        min(maximumRetentionDays, max(minimumRetentionDays, days))
    }

    nonisolated static func clampEventCap(_ cap: Int) -> Int {
        min(maximumEventCap, max(minimumEventCap, cap))
    }

    /// Presets offered in Settings. The settable range is wider on purpose, so
    /// `retentionChoices(including:)` and `eventCapChoices(including:)` add the
    /// current value when it is not a preset. Without that, a clamped or
    /// hand-edited value would leave the picker with nothing selected.
    nonisolated static let retentionPresets = [7, 30, 90, 365]
    nonisolated static let eventCapPresets = [500, 2_000, 5_000]

    nonisolated static func retentionChoices(including current: Int) -> [Int] {
        let clamped = clampRetention(current)
        guard retentionPresets.contains(clamped) else {
            return (retentionPresets + [clamped]).sorted()
        }
        return retentionPresets
    }

    nonisolated static func eventCapChoices(including current: Int) -> [Int] {
        let clamped = clampEventCap(current)
        guard eventCapPresets.contains(clamped) else {
            return (eventCapPresets + [clamped]).sorted()
        }
        return eventCapPresets
    }

    // MARK: - Query digest

    /// Keyed digest of the folded, length-bounded query, or `nil` when the
    /// query folds away to nothing.
    ///
    /// The fold is the same one ranking uses, so repeats of the same typing
    /// correlate; the key is this install's. A stored digest is written as
    /// `"v2:<hex>"`, so a row can never be compared across digest schemes.
    func fingerprint(ofQuery query: String) -> String? {
        let folded = LauncherUsageStore.normalizedQuery(query)
        guard !folded.isEmpty else { return nil }
        return fingerprint(ofFoldedQuery: folded)
    }

    /// Digest of an already-folded query.
    func fingerprint(ofFoldedQuery folded: String) -> String? {
        guard !folded.isEmpty else { return nil }
        return Self.digest(folded, key: digestKey)
    }

    nonisolated static func digest(_ value: String, key: SymmetricKey) -> String {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: key
        )
        let hex = code.map { String(format: "%02x", $0) }.joined()
        return "v\(fingerprintVersion):" + String(hex.prefix(digestLength))
    }

    /// Coarse band for a folded query's length. Never the exact count.
    nonisolated static func lengthBucket(forFoldedLength length: Int) -> String? {
        switch length {
        case ..<1: nil
        case 1...3: "1-3"
        case 4...7: "4-7"
        case 8...15: "8-15"
        case 16...31: "16-31"
        default: "32+"
        }
    }

    // MARK: - Item identifier sanitization

    /// Keeps an identifier only when it is a known launcher identity with a
    /// plain payload. Anything else — a typed URL, a window title, a value —
    /// becomes `"redacted:<keyed digest>"`, which still correlates repeats on
    /// this Mac without carrying the content.
    func sanitizedItemID(_ itemID: String?) -> String? {
        guard let itemID, !itemID.isEmpty else { return nil }
        // Idempotent: an identifier that is already a digest stays one, so
        // re-loading a migrated file never re-digests it.
        if itemID.hasPrefix("redacted:") { return itemID }
        if Self.alwaysDigestedItemIDMarkers.contains(where: { itemID.contains($0) }) {
            return "redacted:" + Self.digest(itemID, key: digestKey)
        }
        for prefix in Self.safeItemIDPrefixes where itemID.hasPrefix(prefix) {
            let payload = itemID.dropFirst(prefix.count)
            let isPlain = !payload.isEmpty
                && payload.count <= Self.maximumItemIDLength
                && !payload.contains { character in
                    character.isWhitespace
                        || character == "/"
                        || character == "\\"
                        || character == "?"
                        || character == "#"
                        || character == "&"
                        || character == "="
                }
            if isPlain { return itemID }
            break
        }
        return "redacted:" + (Self.digest(itemID, key: digestKey))
    }

    // MARK: - Recording

    /// Appends one outcome. Returns the stored event, or `nil` when the event
    /// was a duplicate of the newest row or was dropped by bounds.
    ///
    /// `query` is folded and reduced to a keyed digest inside this call; the
    /// text never leaves the function. `itemID` is sanitized the same way.
    @discardableResult
    func record(
        kind: InteractionJournalEventKind,
        scope: String = LauncherUsageStore.rootScope,
        itemID: String? = nil,
        query: String? = nil,
        detail: String? = nil
    ) -> InteractionJournalEvent? {
        let stamp = now()
        prune(at: stamp)

        let folded = query.map(LauncherUsageStore.normalizedQuery) ?? ""
        let fingerprint = folded.isEmpty ? nil : fingerprint(ofFoldedQuery: folded)
        let lengthBucket = folded.isEmpty ? nil : Self.lengthBucket(forFoldedLength: folded.count)
        let sanitizedItem = sanitizedItemID(itemID)

        // A query abandoned twice in a row is a retry, not a second fresh
        // abandonment. Resolved before de-duplication, so a quick retry is
        // never swallowed as a duplicate of the first abandonment.
        var resolvedKind = kind
        if kind == .searchAbandoned, let fingerprint,
           events.contains(where: {
               ($0.kind == .searchAbandoned || $0.kind == .searchRetried)
                   && $0.queryFingerprint == fingerprint
                   && $0.fingerprintVersion == Self.fingerprintVersion
                   && stamp.timeIntervalSince($0.date) < Self.retryWindow
           }) {
            resolvedKind = .searchRetried
        }

        if let newest = events.last,
           newest.kind == resolvedKind,
           newest.scope == scope,
           newest.itemID == sanitizedItem,
           newest.queryFingerprint == fingerprint,
           stamp.timeIntervalSince(newest.date) < Self.dedupeWindow {
            return nil
        }

        let event = InteractionJournalEvent(
            date: stamp,
            kind: resolvedKind,
            scope: scope,
            itemID: sanitizedItem,
            queryFingerprint: fingerprint,
            queryLengthBucket: lengthBucket,
            detail: detail
        )
        events.append(event)
        trimToCap()
        save()
        return event
    }

    /// Sets or clears the explicit "this was the wrong choice" marker.
    /// Reversible and never affects ranking.
    @discardableResult
    func setMarkedAccidental(_ accidental: Bool, id: UUID) -> Bool {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return false }
        guard events[index].markedAccidental != accidental else { return false }
        events[index].markedAccidental = accidental
        save()
        return true
    }

    /// Drops stale and over-cap events. Called on every record and whenever
    /// the retention or cap settings change.
    func prune(at stamp: Date? = nil) {
        let stamp = stamp ?? now()
        let cutoff = stamp.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        let before = events.count
        events.removeAll { $0.date < cutoff }
        let trimmed = trimToCap()
        if events.count != before || trimmed { save() }
    }

    /// Empties the log. The file stays so the store keeps its permissions.
    func clear() {
        guard !events.isEmpty else { return }
        events.removeAll()
        save()
    }

    // MARK: - Reading

    var isEmpty: Bool { events.isEmpty }
    var count: Int { events.count }
    var markedAccidentalCount: Int { events.count { $0.markedAccidental } }
    var lastEventDate: Date? { events.last?.date }
    var fileExists: Bool { file?.exists ?? false }

    /// Newest first, for the Settings review list and the export.
    func recentEvents() -> [InteractionJournalEvent] { events.reversed() }

    func recentEvents(limit: Int) -> [InteractionJournalEvent] {
        Array(events.suffix(max(0, limit)).reversed())
    }

    func count(of kind: InteractionJournalEventKind) -> Int {
        events.count { $0.kind == kind }
    }

    // MARK: - Helpers

    /// Drops oldest events past the cap. Returns true when something went.
    @discardableResult
    private func trimToCap() -> Bool {
        guard events.count > eventCap else { return false }
        events.removeFirst(events.count - eventCap)
        return true
    }

    // MARK: - Key

    /// Reads the key, creating it with `0600` on first use. Falls back to a
    /// fresh in-memory key when there is no writable location, so the digest
    /// is keyed either way.
    nonisolated static func loadOrCreateKey(at url: URL?) -> Data {
        if let url, let data = try? Data(contentsOf: url), data.count >= keyByteCount {
            // Re-assert owner-only on every load: a restored backup, an
            // umask, or a copy can widen it after it was first written.
            reassertOwnerOnly(at: url)
            return data
        }
        var bytes = [UInt8](repeating: 0, count: keyByteCount)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<keyByteCount).map { _ in UInt8.random(in: .min ... .max) }
        }
        let data = Data(bytes)
        guard let url else { return data }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            AppLog.persistence.error(
                "Could not write the interaction journal key: \(error.localizedDescription, privacy: .public)"
            )
        }
        return data
    }

    /// Best-effort `chmod 0600`. A failure is recorded, not fatal: the journal
    /// keeps working, and the next load tries again.
    nonisolated static func reassertOwnerOnly(at url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            AppLog.persistence.error(
                "Could not tighten the interaction journal key permissions: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let snapshot = file?.load() else { return }
        // Rows are normalized by `InteractionJournalEvent.init(from:)`: unknown
        // kinds survive as `.unknown`, an exact old length becomes a band, and
        // the keyless fingerprint of the first build is dropped.
        events = snapshot.events.sorted { $0.date < $1.date }
        byteSize = fileURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int }
            ?? 0

        // An identifier an older build wrote verbatim — a typed URL, a window
        // title — is digested now, so it does not survive on disk.
        var migrated = false
        for index in events.indices {
            if events[index].wasMigrated {
                events[index].wasMigrated = false
                migrated = true
            }
            let sanitized = sanitizedItemID(events[index].itemID)
            if sanitized != events[index].itemID {
                events[index].itemID = sanitized
                migrated = true
            }
        }
        prune()
        // Rewrite once, so the weaker values do not stay on disk.
        if migrated { save() }
    }

    private func save() {
        guard let file else { return }
        let snapshot = Snapshot(events: events)
        if let data = try? JSONEncoder().encode(snapshot) {
            byteSize = data.count
        }
        file.save(snapshot)
    }

    /// Tests: block until queued writes are on disk.
    func waitForPendingWrites() {
        file?.flush()
    }
}
