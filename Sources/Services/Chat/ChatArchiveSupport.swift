import Foundation
import HouseChatCore

// MARK: - Submit

/// One user turn, everything frozen at Send, handed to the archive as one
/// atomic commit: the turn, its references, the bytes it carried, and the
/// exact request body the provider will receive.
///
/// The app builds this before it calls a provider. A throw means the turn is
/// not durable, so the caller keeps the draft and never sends.
struct TurnSubmission: Sendable {
    var conversation: QuickConversation
    /// The contents the app already read: original bytes, normalized pixels,
    /// extracted text. The archive never re-reads `ref.path`.
    var attachmentContents: [AttachmentContent]
    /// Chosen and effective route, frozen for this turn.
    var model: ModelSelection?
    /// The retrieval decision the consumer enforced for this turn.
    var context: ContextReceipt?
    /// The tools this turn may call. Recorded under the receipt's app fields.
    var tools: [ChatToolKind]?
    /// The exact provider request body, archived for audit. Nil when the app
    /// has not built one yet.
    var requestSnapshot: Data?
    /// "request", "requestSansKey", …; nil writes "request".
    var requestSnapshotKind: String?
    var endpoint: EndpointDescriptor?
    var receiptID: String?
    var startedAt: Date?
    var toolRounds: [ToolRound]

    init(
        conversation: QuickConversation,
        attachmentContents: [AttachmentContent] = [],
        model: ModelSelection? = nil,
        context: ContextReceipt? = nil,
        tools: [ChatToolKind]? = nil,
        requestSnapshot: Data? = nil,
        requestSnapshotKind: String? = nil,
        endpoint: EndpointDescriptor? = nil,
        receiptID: String? = nil,
        startedAt: Date? = nil,
        toolRounds: [ToolRound] = []
    ) {
        self.conversation = conversation
        self.attachmentContents = attachmentContents
        self.model = model
        self.context = context
        self.tools = tools
        self.requestSnapshot = requestSnapshot
        self.requestSnapshotKind = requestSnapshotKind
        self.endpoint = endpoint
        self.receiptID = receiptID
        self.startedAt = startedAt
        self.toolRounds = toolRounds
    }
}

// MARK: - Later updates

/// One update to an assistant turn as it streams, ends, or fails.
///
/// Every field is optional: a checkpoint sends what it has, and the archive
/// merges it onto what is already stored, so a later partial update never
/// erases an earlier fact.
struct TurnUpdate: Sendable {
    var text: String?
    var status: RequestStatus?
    var timings: TurnTimings?
    var requestTimings: RequestTimings?
    var usage: TokenUsage?
    var toolRounds: [ToolRound]?
    var error: String?
    var checkpointAt: Date?
    var finishedAt: Date?
    /// A full receipt to merge onto the stored one. Its `attachmentRefs` are
    /// only taken when it carries some, so the submit-time snapshot hashes
    /// are never dropped by a completion receipt.
    var receipt: RequestReceipt?
    /// The concise frozen route, when the caller wants to set it here.
    var selection: ModelSelection?

    init(
        text: String? = nil,
        status: RequestStatus? = nil,
        timings: TurnTimings? = nil,
        requestTimings: RequestTimings? = nil,
        usage: TokenUsage? = nil,
        toolRounds: [ToolRound]? = nil,
        error: String? = nil,
        checkpointAt: Date? = nil,
        finishedAt: Date? = nil,
        receipt: RequestReceipt? = nil,
        selection: ModelSelection? = nil
    ) {
        self.text = text
        self.status = status
        self.timings = timings
        self.requestTimings = requestTimings
        self.usage = usage
        self.toolRounds = toolRounds
        self.error = error
        self.checkpointAt = checkpointAt
        self.finishedAt = finishedAt
        self.receipt = receipt
        self.selection = selection
    }

    /// A streaming checkpoint: the text so far, still in flight, with the
    /// tool rounds that have finished so far. It carries no timings of its
    /// own: an empty `RequestTimings` would erase the ones already stored.
    static func checkpoint(
        text: String,
        toolRounds: [ToolRound]? = nil,
        at date: Date = Date()
    ) -> TurnUpdate {
        TurnUpdate(
            text: text,
            status: .streaming,
            toolRounds: toolRounds,
            checkpointAt: date
        )
    }

    /// A completed answer.
    static func completed(
        text: String,
        timings: RequestTimings? = nil,
        usage: TokenUsage? = nil,
        toolRounds: [ToolRound]? = nil,
        receipt: RequestReceipt? = nil,
        at date: Date = Date()
    ) -> TurnUpdate {
        TurnUpdate(
            text: text,
            status: .completed,
            requestTimings: timings,
            usage: usage,
            toolRounds: toolRounds,
            finishedAt: date,
            receipt: receipt
        )
    }

    /// A failed or cancelled answer: the partial text stays.
    static func failed(
        error: String,
        status: RequestStatus = .failed,
        text: String? = nil,
        receipt: RequestReceipt? = nil,
        at date: Date = Date()
    ) -> TurnUpdate {
        TurnUpdate(
            text: text,
            status: status,
            error: error,
            finishedAt: date,
            receipt: receipt
        )
    }
}

// MARK: - Per-round request snapshots

/// The send path's per-round request-snapshot writer.
///
/// The model client's `beforeRequest` hook awaits this before every tool round
/// goes out, so the exact body the provider is about to receive is durable
/// first. The conversation and submission ids are attached once the question's
/// durable submission exists, which is before the stream starts, so the hook
/// can never fire against a turn that is not there.
///
/// Round 0 is the submission's own body: `ChatArchive.submit` already made it
/// durable under the same locked commit, so this records only the later tool
/// rounds and never duplicates the first snapshot. A throw propagates through
/// the hook and stops the loop before that round's network call.
actor ChatRoundRecorder {
    private let archive: ChatArchive
    private var conversationID: String?
    private var turnID: String?
    /// Model requests the client asked this recorder about, round 0 included.
    /// Zero means the hook never ran.
    private(set) var requestedRounds = 0
    /// The rounds whose snapshot is durably referenced.
    private(set) var recordedRounds: [Int] = []

    init(archive: ChatArchive) {
        self.archive = archive
    }

    /// The durable submission this stream writes its rounds against.
    func attach(conversationID: String, turnID: String) {
        self.conversationID = conversationID
        self.turnID = turnID
    }

    /// The provider's own hook. Returns only when the round's body is durable.
    func beforeRequest(_ round: ProviderRequestRound) async throws {
        requestedRounds += 1
        guard round.round > 0 else { return }
        guard let conversationID, let turnID else {
            throw ChatArchiveError.noConversation(conversationID: "unknown")
        }
        _ = try await archive.recordRequestRound(
            conversationID: conversationID,
            turnID: turnID,
            round: round.round,
            body: round.body,
            kind: round.kind
        )
        recordedRounds.append(round.round)
    }
}

// MARK: - Extraction artifact encoding

/// Quick Launch's extraction artifact encoding.
///
/// A link or a selection stores plain UTF-8 text. A document the shared
/// extractor read stores the whole `ExtractedDocument` (sections, unit
/// locations, notes, and its text) behind a small versioned header, so a
/// resume rebuilds passage selection from the preserved extraction instead of
/// re-reading the original path or re-extracting silently.
///
/// One artifact per attachment, referenced by the record and visible to the
/// reference scan: no second, unreferenced blob, and nothing that a GC could
/// sweep out from under a record. The header distinguishes the two encodings,
/// so a plain-text artifact written by an older build still reads as text.
///
/// This mirrors the pipeline's `AttachmentContent`: `extractedDocument` is the
/// structured payload, `text` the plain fallback.
enum ExtractionArtifact {
    /// The exact prefix on a structured extraction. Bump the version when the
    /// envelope changes; the old version stays readable by keeping its
    /// decoder.
    static let header = "#!ql-extraction-v1\n"

    static func encode(text: String) -> Data {
        Data(text.utf8)
    }

    /// The structured envelope, or nil when the document cannot be encoded.
    static func encode(document: ExtractedDocument) -> Data? {
        guard let json = try? HouseChatCoding.makeEncoder().encode(document) else { return nil }
        var data = Data(header.utf8)
        data.append(json)
        return data
    }

    static func isEnvelope(_ data: Data) -> Bool {
        data.starts(with: Array(header.utf8))
    }

    static func document(in data: Data) -> ExtractedDocument? {
        guard isEnvelope(data) else { return nil }
        let json = Data(data.dropFirst(header.utf8.count))
        return try? HouseChatCoding.makeDecoder().decode(ExtractedDocument.self, from: json)
    }

    /// The text a model may receive: the document's own text when it has one,
    /// the joined section text when it does not, or the plain UTF-8 body.
    static func text(in data: Data) -> String? {
        if let document = document(in: data) {
            if let text = document.text { return text }
            return document.sections.map(\.text).joined()
        }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Status surfaces

/// What one attachment retained, role by role, and which roles are missing.
/// A missing role is the archive telling the truth: the bytes were never
/// archived and are never fetched again.
struct RetainedSource: Sendable, Equatable {
    var attachment: AttachmentRecord
    var original: ArtifactRef?
    var normalizedImage: ArtifactRef?
    var extractedText: ArtifactRef?
    /// The role names with no archived bytes, in a stable order.
    var missingRoles: [String]

    var hasBytes: Bool {
        original != nil || normalizedImage != nil || extractedText != nil
    }
}

/// What one delete-everything run did. A partial run is reported as partial:
/// the caller must not tell the user everything is gone when it is not.
struct ChatArchiveDeleteReport: Sendable, Equatable {
    /// Every chat the run set out to delete.
    var requestedIDs: [String]
    var deletedIDs: [String]
    /// Chats whose record is still on disk. Non-empty means the run stopped
    /// part-way and those chats are still there.
    var failedIDs: [String]
    var removedArtifacts: [ArtifactRef]
    /// Set when the records were deleted but the reference scan could not run,
    /// so no bytes were reclaimed. The chats are gone; the copies stay.
    var gcIssue: String?

    var isComplete: Bool { failedIDs.isEmpty }
}

/// What one deletion did.
struct ChatDeletionReport: Sendable, Equatable {
    var deletedID: String
    var removedArtifacts: [ArtifactRef]
    /// Set when the record was deleted but the reference scan could not run,
    /// so no bytes were reclaimed. The record is still gone.
    var gcIssue: String?
    /// Set when the chat had no record to delete (already gone).
    var wasAlreadyMissing: Bool
}

/// Counts for the storage and health surfaces.
struct ChatArchiveSurvey: Sendable, Equatable {
    var conversationCount: Int
    var damagedCount: Int
    var deletedCount: Int
    var issues: [String]
    var artifactBytes: Int
    var artifactCount: Int

    var isHealthy: Bool { damagedCount == 0 }
}

/// A projection rebuild that reports the records it could not read instead
/// of hiding them.
struct ChatProjection: Sendable {
    var conversations: [QuickConversation]
    var damaged: [ConversationSummary]
}

// MARK: - Deletion ledger

/// Tombstones for deleted chats.
///
/// A chat is deleted by writing its marker first and removing its record
/// second. A late checkpoint or completion that arrives after the record is
/// gone finds the marker and refuses, so a deleted thread can never be
/// recreated by an answer that was already in flight. Markers are keyed by
/// the hash of the chat ID, owner-only, and kept: they are tiny and they are
/// the evidence that the chat was deliberately removed.
struct DeletionLedger: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    func markerURL(for id: String) -> URL {
        root.appendingPathComponent(SHA256Digest.hex(id), isDirectory: false)
    }

    func contains(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(for: id).path)
    }

    func allIDs() -> Set<String> {
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var ids: Set<String> = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let value = try? JSONDecoder().decode(Marker.self, from: data)
            else { continue }
            ids.insert(value.id)
        }
        return ids
    }

    /// Writes the tombstone. Idempotent: a second mark for the same chat is a
    /// no-op that keeps the first timestamp.
    func mark(_ id: String, at date: Date = Date()) throws {
        let url = markerURL(for: id)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(Marker(id: id, deletedAt: date))
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes a tombstone written for a delete that then failed, so the
    /// chat is not left marked when its record is still on disk.
    func unmark(_ id: String) {
        try? FileManager.default.removeItem(at: markerURL(for: id))
    }

    struct Marker: Codable, Sendable, Equatable {
        var id: String
        var deletedAt: Date
    }
}

// MARK: - Shared instances

/// One `ChatArchive` per canonical root.
///
/// Two app windows each build their own view model, but they write one
/// history. A per-root instance is what makes the archive's read-modify-write
/// serialization real across both, instead of two actors racing the same
/// files. The app asks for `ChatArchive.shared(root:)`; tests may still build
/// a private instance with `init(root:)`.
enum ChatArchiveRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var archives: [String: ChatArchive] = [:]

    static func shared(root: URL) throws -> ChatArchive {
        let key = root.standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        if let existing = archives[key] { return existing }
        let archive = try ChatArchive(root: root)
        archives[key] = archive
        return archive
    }

    /// Test hook: forget every shared instance (never called by the app).
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        archives.removeAll()
    }
}
