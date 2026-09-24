import Foundation
import HouseChatCore

/// Quick Launch's durable chat archive: the keep-all, canonical owner of
/// every chat, with no cap, no expiry, and no re-fetch.
///
/// ## Authority
///
/// `<root>/chats/<slug>-<hash of id>.json` is the single structured record
/// per chat, and `ChatArchive` is its only writer. `chat-history.json` is a
/// legacy source for a one-time, verified import and, after that, a
/// rebuildable UI cache: nothing durable is allowed to live only there.
///
/// ## Bytes
///
/// `<root>/chat-assets/<kind>/<xx>/<sha256>` holds the exact original bytes,
/// the inference-normalized image, the extracted text, and the request body
/// a provider received. **Every blob is written through one
/// `coordinator.commit`**, so a blob is always written under the same root
/// lock as the record that references it. Nothing is ever read back from
/// `ref.path`: the archive keeps what the reader handed it, and an artifact
/// that was never archived stays explicitly missing. A missing artifact is
/// never fabricated and never re-fetched.
///
/// ## Rewrites
///
/// Every write is a read-modify-write under one serialized chain, and it
/// fails closed:
///
/// - a record that exists but cannot be decoded, or that a newer build
///   wrote, throws instead of being replaced with a fresh projection;
/// - unknown fields at every level (conversation, turn, attachment,
///   artifacts, receipt, payload) are carried from the stored record onto
///   the rewrite, so a newer build's fields survive an older build's save;
/// - a tombstone written before deletion stops a late checkpoint, answer,
///   or projection sync from recreating a chat the user deleted.
actor ChatArchive {
    /// The `surface` every Quick Launch record carries.
    static let surface: ChatSurface = .quickLaunch
    /// The `AppPayload` namespace for Quick Launch's own fields.
    static let namespace = "quick-launch"

    /// The keys the live `QuickConversation` owns on the conversation
    /// payload; everything else on disk is preserved across a rewrite.
    static let conversationOwnedKeys: Set<String> = [
        "providerID", "model", "customTitle", "titleSource", "isPinned",
        "enabledTools", "assistantID", "cosCard",
    ]
    /// The keys the live `QuickMessage` owns on the turn payload.
    static let turnOwnedKeys: Set<String> = ["askUserQuestion", "toolRecords", "cosTell"]

    nonisolated let root: URL
    nonisolated let attachments: AttachmentArchive
    nonisolated let conversations: ConversationArchive
    nonisolated let coordinator: ChatCommitCoordinator
    nonisolated let deletions: DeletionLedger

    /// The tail of the serialized read-modify-write chain. Actor reentrancy
    /// would otherwise let two awaits interleave between a load and its
    /// save, and the second save would silently drop the first's facts.
    private var writeChain: Task<Void, Never>?

    init(root: URL) throws {
        self.root = root
        self.attachments = try AttachmentArchive(
            root: root.appendingPathComponent("chat-assets", isDirectory: true)
        )
        self.conversations = try ConversationArchive(
            root: root.appendingPathComponent("chats", isDirectory: true)
        )
        self.coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)
        self.deletions = DeletionLedger(root: root.appendingPathComponent("deletions", isDirectory: true))
    }

    /// The one archive for a canonical root, shared by every window. Prefer
    /// this over `init(root:)` in the app so both view models write one
    /// serialized store.
    static func shared(root: URL) throws -> ChatArchive {
        try ChatArchiveRegistry.shared(root: root)
    }

    // MARK: - Reads

    /// Every record, newest first. Fails closed: one damaged or
    /// newer-schema file throws instead of being skipped, so a caller never
    /// mistakes "could not read" for "nothing there".
    func loadAll() async throws -> [ConversationRecord] {
        var records: [ConversationRecord] = []
        for summary in try await conversations.list() {
            if let issue = summary.issue {
                throw ChatArchiveError.recordUnreadable(id: summary.id, detail: issue.rawValue)
            }
            do {
                records.append(try await conversations.load(id: summary.id))
            } catch {
                throw ChatArchiveError.recordUnreadable(id: summary.id, detail: String(describing: error))
            }
        }
        return records.sorted { ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id) }
    }

    /// Every record this build can read, next to the ones it cannot. The
    /// damaged list is never empty silently: a caller that shows the chats
    /// shows the trouble too.
    func readableRecords() async throws -> (records: [ConversationRecord], damaged: [ConversationSummary]) {
        var records: [ConversationRecord] = []
        var damaged: [ConversationSummary] = []
        for summary in try await conversations.list() {
            if summary.issue != nil {
                damaged.append(summary)
                continue
            }
            do {
                records.append(try await conversations.load(id: summary.id))
            } catch {
                damaged.append(summary)
            }
        }
        return (
            records.sorted { ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id) },
            damaged
        )
    }

    func load(id: String) async throws -> ConversationRecord {
        try await conversations.load(id: id)
    }

    /// True when the chat has a record on disk and no tombstone. A tombstoned
    /// chat reads as absent even if a crash left its file behind.
    nonisolated func contains(id: String) -> Bool {
        conversations.contains(id) && !deletions.contains(id)
    }

    func isDeleted(id: String) -> Bool {
        deletions.contains(id)
    }

    func deletedIDs() -> Set<String> {
        deletions.allIDs()
    }

    /// Storage and health, in one call for the Settings surface.
    func survey() async throws -> ChatArchiveSurvey {
        let summaries = try await conversations.list()
        var bytes = 0
        var count = 0
        for reference in try await attachments.list() {
            bytes += reference.byteCount
            count += 1
        }
        let damaged = summaries.filter { $0.issue != nil }
        return ChatArchiveSurvey(
            conversationCount: summaries.count - damaged.count,
            damagedCount: damaged.count,
            deletedCount: deletions.allIDs().count,
            issues: damaged.map { "\($0.id): \($0.issue?.rawValue ?? "unknown")" },
            artifactBytes: bytes,
            artifactCount: count
        )
    }

    /// Byte and record counts for the storage-usage surface.
    func usage() async throws -> ChatArchiveUsage {
        let survey = try await survey()
        return ChatArchiveUsage(
            conversationCount: survey.conversationCount,
            damagedConversationCount: survey.damagedCount,
            artifactBytes: survey.artifactBytes
        )
    }

    // MARK: - Writing a turn

    /// Submits one user turn before any provider call: the turn, its frozen
    /// route, its receipt, and every byte it carried, in one atomic commit.
    /// Throws when the turn (or its bytes) cannot be written; the caller
    /// keeps the draft and must not call a model.
    @discardableResult
    func submit(_ submission: TurnSubmission) async throws -> TurnCommit {
        try await serialized {
            try await self.performSubmit(submission)
        }
    }

    /// Compatibility entry point. Prefer `submit(_:)`, which also carries the
    /// context, tools, endpoint, and request snapshot.
    @discardableResult
    func commitUserTurn(
        _ conversation: QuickConversation,
        attachmentContents: [AttachmentContent] = [],
        model: ModelSelection? = nil
    ) async throws -> TurnCommit {
        try await submit(TurnSubmission(
            conversation: conversation,
            attachmentContents: attachmentContents,
            model: model
        ))
    }

    private func performSubmit(_ submission: TurnSubmission) async throws -> TurnCommit {
        let id = submission.conversation.id.uuidString
        try ensureNotDeleted(id)
        let merged = try await mergingStoredState(into: Self.record(for: submission.conversation))
        guard let turnIndex = merged.turns.lastIndex(where: { $0.role == .user }) else {
            throw ChatArchiveError.noUserTurn(conversationID: merged.id)
        }

        var record = merged
        // Freeze the route this turn will use, captured at Send.
        record.turns[turnIndex].model = submission.model
        record.turns[turnIndex].toolRounds = submission.toolRounds
        let prepared = Self.prepareArtifacts(
            for: submission.attachmentContents,
            requestSnapshot: submission.requestSnapshot,
            requestSnapshotKind: submission.requestSnapshotKind
        )
        record.turns[turnIndex].request = Self.receipt(for: submission, attachmentRefs: prepared.snapshotRefs)
        record.updatedAt = Date()

        return try await coordinator.commit(
            conversation: record,
            turnIndex: turnIndex,
            artifacts: prepared.artifacts
        )
    }

    /// Checkpoints a streaming answer. Upserts the assistant turn by ID, so
    /// the first partial text creates it and later checkpoints extend it.
    /// Never recreates a deleted chat.
    @discardableResult
    func checkpoint(conversationID: String, turnID: String, update: TurnUpdate) async throws -> TurnRecord {
        try await serialized {
            try await self.performTurnUpdate(conversationID: conversationID, turnID: turnID, update: update)
        }
    }

    /// Records the completed answer, merging the receipt onto the stored one
    /// so the submit-time snapshot hashes survive. The turn's tool rounds,
    /// token usage and timings ride the same update as the text, so a reply
    /// that finished normally can never be terminal without its telemetry.
    @discardableResult
    func completeTurn(
        conversationID: String,
        turnID: String,
        text: String,
        receipt: RequestReceipt? = nil,
        selection: ModelSelection? = nil,
        timings: RequestTimings? = nil,
        usage: TokenUsage? = nil,
        toolRounds: [ToolRound]? = nil
    ) async throws -> TurnRecord {
        var update = TurnUpdate.completed(
            text: text,
            timings: timings,
            usage: usage,
            toolRounds: toolRounds,
            receipt: receipt
        )
        update.selection = selection
        return try await checkpoint(conversationID: conversationID, turnID: turnID, update: update)
    }

    /// Records a failed or cancelled answer, keeping whatever text arrived
    /// and the telemetry the turn had already collected.
    @discardableResult
    func failTurn(
        conversationID: String,
        turnID: String,
        error: String,
        status: RequestStatus = .failed,
        text: String? = nil,
        receipt: RequestReceipt? = nil,
        timings: RequestTimings? = nil,
        usage: TokenUsage? = nil,
        toolRounds: [ToolRound]? = nil
    ) async throws -> TurnRecord {
        var update = TurnUpdate.failed(error: error, status: status, text: text, receipt: receipt)
        update.requestTimings = timings
        update.usage = usage
        update.toolRounds = toolRounds
        return try await checkpoint(conversationID: conversationID, turnID: turnID, update: update)
    }

    /// Compatibility entry point for a completed answer.
    func commitAnswer(
        conversationID: String,
        text: String,
        turnID: String,
        selection: ModelSelection?,
        receipt: RequestReceipt?
    ) async throws {
        _ = try await completeTurn(
            conversationID: conversationID,
            turnID: turnID,
            text: text,
            receipt: receipt,
            selection: selection
        )
    }

    private func performTurnUpdate(conversationID: String, turnID: String, update: TurnUpdate) async throws -> TurnRecord {
        try ensureNotDeleted(conversationID)
        guard var record = try await storedRecord(id: conversationID) else {
            throw ChatArchiveError.noConversation(conversationID: conversationID)
        }
        let index: Int
        if let existing = record.turns.firstIndex(where: { $0.id == turnID }) {
            index = existing
        } else {
            record.turns.append(TurnRecord(
                id: turnID,
                role: .assistant,
                text: update.text ?? "",
                createdAt: update.checkpointAt ?? Date()
            ))
            index = record.turns.count - 1
        }
        Self.apply(update, to: &record.turns[index])
        record.updatedAt = Date()
        try await conversations.save(record)
        return record.turns[index]
    }

    /// Makes one tool-loop request body durable before its network call.
    ///
    /// The exact bytes go through the coordinator's locked commit, so the
    /// snapshot is written under the same root lock as the record that
    /// references it, and the submission turn's receipt carries the hash. The
    /// turn is the one the user's question was committed as (round 0 already
    /// carries the first body), so no empty assistant turn is invented.
    ///
    /// A throw means the body is not durable: the caller must not let the
    /// request go out. Re-recording the same round replaces its reference
    /// instead of duplicating it.
    @discardableResult
    func recordRequestRound(
        conversationID: String,
        turnID: String,
        round: Int,
        body: Data,
        kind: String = "requestSansKey"
    ) async throws -> TurnRecord {
        try await serialized {
            try self.ensureNotDeleted(conversationID)
            guard var record = try await self.storedRecord(id: conversationID) else {
                throw ChatArchiveError.noConversation(conversationID: conversationID)
            }
            guard let index = record.turns.firstIndex(where: { $0.id == turnID }) else {
                throw ChatArchiveError.noUserTurn(conversationID: conversationID)
            }
            let ref = AttachmentSnapshotRef(
                snapshotData: body,
                kind: Self.requestRoundKind(base: kind, round: round)
            )
            var receipt = record.turns[index].request ?? RequestReceipt(status: .pending)
            receipt.attachmentRefs.removeAll { $0.kind == ref.kind }
            receipt.attachmentRefs.append(ref)
            record.turns[index].request = receipt.sanitizedForStorage()
            record.updatedAt = Date()
            let commit = try await self.coordinator.commit(
                conversation: record,
                turnIndex: index,
                artifacts: [PendingArtifact(role: .requestSnapshot, data: body, fileExtension: "json")]
            )
            return commit.conversation.turns[index]
        }
    }

    /// The reference label one request body is filed under. The turn's first
    /// request keeps the label it has always had; each tool round gets its
    /// own, so an audit can find every body the turn sent.
    static func requestRoundKind(base: String, round: Int) -> String {
        round <= 0 ? base : "\(base)-round\(round)"
    }

    /// Writes the whole conversation projection as it now stands, preserving
    /// every archive-only fact already on disk. A deleted chat is never
    /// recreated, and a corrupt record is never replaced with a fresh one.
    func syncConversation(_ conversation: QuickConversation) async throws {
        try await serialized {
            let id = conversation.id.uuidString
            try self.ensureNotDeleted(id)
            let merged = try await self.mergingStoredState(into: Self.record(for: conversation))
            try await self.conversations.save(merged)
        }
    }

    // MARK: - Rename, pin

    /// Renames a chat in the canonical record. The app's own copy is a cache.
    func rename(id: String, customTitle: String?, titleSource: String? = nil) async throws {
        try await serialized {
            try self.ensureNotDeleted(id)
            guard var record = try await self.storedRecord(id: id) else {
                throw ChatArchiveError.noConversation(conversationID: id)
            }
            var payload = record.appPayload ?? AppPayload(namespace: Self.namespace)
            payload.namespace = Self.namespace
            payload["customTitle"] = customTitle.map { .string($0) }
            if let titleSource { payload["titleSource"] = .string(titleSource) }
            record.appPayload = payload
            record.updatedAt = Date()
            try await self.conversations.save(record)
        }
    }

    /// Pins or unpins a chat in the canonical record.
    func setPinned(id: String, isPinned: Bool) async throws {
        try await serialized {
            try self.ensureNotDeleted(id)
            guard var record = try await self.storedRecord(id: id) else {
                throw ChatArchiveError.noConversation(conversationID: id)
            }
            var payload = record.appPayload ?? AppPayload(namespace: Self.namespace)
            payload.namespace = Self.namespace
            payload["isPinned"] = .bool(isPinned)
            record.appPayload = payload
            record.updatedAt = Date()
            try await self.conversations.save(record)
        }
    }

    // MARK: - Merge

    /// Copies archive-only state from the stored record onto a freshly built
    /// one, keyed by turn ID and attachment ID, and preserves every unknown
    /// field at every level.
    ///
    /// Fails closed: a record that exists but cannot be read throws. Returning
    /// the fresh projection here would silently replace a damaged or
    /// newer-schema record with a thinner one.
    func mergingStoredState(into record: ConversationRecord) async throws -> ConversationRecord {
        guard let stored = try await storedRecord(id: record.id) else { return record }
        return Self.merge(live: record, into: stored)
    }

    /// The stored record, or nil only when there is genuinely no file.
    /// Corrupt, newer-schema, unsafe-root and unusable-ID all throw a typed
    /// `ChatArchiveError.recordUnreadable`, so a caller can tell "damaged"
    /// apart from "absent" and refuse to rewrite over it.
    func storedRecord(id: String) async throws -> ConversationRecord? {
        do {
            return try await conversations.load(id: id)
        } catch ConversationArchiveError.missing {
            return nil
        } catch let error as ConversationArchiveError {
            throw ChatArchiveError.recordUnreadable(id: id, detail: error.localizedDescription)
        }
    }

    static func merge(live: ConversationRecord, into stored: ConversationRecord) -> ConversationRecord {
        var merged = stored
        let metadataWins = isNewer(live.updatedAt, than: stored.updatedAt)
        if metadataWins {
            merged.title = live.title
            merged.appPayload = mergingAppPayload(
                live: live.appPayload,
                stored: stored.appPayload,
                owned: conversationOwnedKeys
            )
        }
        if merged.createdAt == nil { merged.createdAt = live.createdAt }
        merged.updatedAt = later(live.updatedAt, stored.updatedAt)
        merged.turns = mergeTurns(live: live.turns, stored: stored.turns)
        return merged
    }

    static func merge(liveTurn live: TurnRecord, into stored: TurnRecord) -> TurnRecord {
        var merged = stored
        merged.role = live.role
        merged.text = live.text
        merged.attachments = mergeAttachments(live: live.attachments, stored: stored.attachments)
        merged.appPayload = mergingAppPayload(live: live.appPayload, stored: stored.appPayload, owned: turnOwnedKeys)
        if merged.createdAt == nil { merged.createdAt = live.createdAt }
        return merged
    }

    /// Every attachment survives. A live attachment that matches a stored one
    /// is merged onto the stored record; a live-only attachment is kept in
    /// live order; a stored-only attachment is kept too, at its stored
    /// position. The live projection can never drop a stored reference.
    static func mergeAttachments(live: [AttachmentRecord], stored: [AttachmentRecord]) -> [AttachmentRecord] {
        var byID: [String: AttachmentRecord] = [:]
        for attachment in stored { byID[attachment.id] = attachment }
        var storedIndex: [String: Int] = [:]
        for (index, attachment) in stored.enumerated() { storedIndex[attachment.id] = index }
        var result = live.map { attachment in
            guard let existing = byID[attachment.id] else { return attachment }
            return merge(liveAttachment: attachment, into: existing)
        }
        let liveIDs = Set(live.map(\.id))
        for (index, attachment) in stored.enumerated() where !liveIDs.contains(attachment.id) {
            result.insert(attachment, at: Self.insertionPoint(forStoredIndex: index, in: result, storedIndex: storedIndex))
        }
        return result
    }

    static func merge(liveAttachment live: AttachmentRecord, into stored: AttachmentRecord) -> AttachmentRecord {
        var merged = live
        let hashChanged = live.contentHash != nil
            && stored.contentHash != nil
            && live.contentHash != stored.contentHash
        if hashChanged {
            // The stored bytes describe a different source now; do not serve
            // them under the new hash, and do not keep a stale document.
            merged.artifacts = nil
            merged.extra = live.extra
        } else {
            merged.artifacts = stored.artifacts
            merged.extra = stored.extra
        }
        return merged
    }

    /// Every turn survives. `merge` only enriches turns present on both sides,
    /// so this unions instead of following the live array: a live turn that
    /// matches a stored one is merged onto the stored record, a live-only turn
    /// is kept in live order, and a stored-only turn is kept too. A thin live
    /// projection (the re-derived-new-chat path) can therefore never overwrite
    /// the archive with fewer turns than it already holds.
    static func mergeTurns(live: [TurnRecord], stored: [TurnRecord]) -> [TurnRecord] {
        var byID: [String: TurnRecord] = [:]
        for turn in stored { byID[turn.id] = turn }
        var storedIndex: [String: Int] = [:]
        for (index, turn) in stored.enumerated() { storedIndex[turn.id] = index }
        var result = live.map { turn in
            guard let existing = byID[turn.id] else { return turn }
            return merge(liveTurn: turn, into: existing)
        }
        let liveIDs = Set(live.map(\.id))
        for (index, turn) in stored.enumerated() where !liveIDs.contains(turn.id) {
            result.insert(turn, at: Self.insertionPoint(forStoredIndex: index, in: result, storedIndex: storedIndex))
        }
        return result
    }

    /// Where a stored-only element belongs in the merged result: after the
    /// last element whose stored position precedes it, so stored-only turns
    /// keep their order instead of being appended past newer ones.
    private static func insertionPoint<Element: Identifiable>(
        forStoredIndex index: Int,
        in result: [Element],
        storedIndex: [String: Int]
    ) -> Int where Element.ID == String {
        var insertion = 0
        for (offset, element) in result.enumerated() {
            if let position = storedIndex[element.id], position < index {
                insertion = offset + 1
            }
        }
        return insertion
    }

    /// The live payload wins for the keys this app owns; every other stored
    /// key is carried through untouched.
    static func mergingAppPayload(live: AppPayload?, stored: AppPayload?, owned: Set<String>) -> AppPayload? {
        var values = stored?.values ?? ExtraFields()
        for key in owned { values[key] = nil }
        if let live {
            for key in live.values.keys { values[key] = live.values[key] }
        }
        let namespace = live?.namespace ?? stored?.namespace
        if namespace == nil && values.isEmpty { return nil }
        return AppPayload(namespace: namespace, values: values)
    }

    static func isNewer(_ candidate: Date?, than reference: Date?) -> Bool {
        guard let candidate else { return false }
        guard let reference else { return true }
        return candidate >= reference
    }

    static func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (l?, r?): return max(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    // MARK: - Applying a later update

    static func apply(_ update: TurnUpdate, to turn: inout TurnRecord) {
        if let text = update.text { turn.text = text }
        if let timings = update.timings { turn.timings = timings }
        if let rounds = update.toolRounds { turn.toolRounds = rounds }
        if let selection = update.selection { turn.model = selection }
        if let error = update.error { turn.error = error }

        var receipt = turn.request ?? RequestReceipt(status: .unknown)
        if let incoming = update.receipt { receipt = merge(receipt: incoming, into: receipt) }
        if let status = update.status { receipt.status = status }
        if let timings = update.requestTimings { receipt.timings = timings }
        if let usage = update.usage { receipt.usage = usage }
        if let rounds = update.toolRounds { receipt.toolRounds = rounds }
        if let error = update.error { receipt.error = SecretRedactor.redact(error) }
        if let finishedAt = update.finishedAt { receipt.finishedAt = finishedAt }
        if let checkpointAt = update.checkpointAt, receipt.startedAt == nil { receipt.startedAt = checkpointAt }
        // Free text a provider or a tool echoed is scrubbed by the shared
        // helper; the user's own turn text and attachments are never touched.
        turn.request = receipt.sanitizedForStorage()
    }

    static func merge(receipt incoming: RequestReceipt, into stored: RequestReceipt) -> RequestReceipt {
        var merged = stored
        if incoming.selection != nil { merged.selection = incoming.selection }
        merged.status = incoming.status
        if let context = incoming.context { merged.context = context }
        if !incoming.attachmentRefs.isEmpty { merged.attachmentRefs = incoming.attachmentRefs }
        if !incoming.toolRounds.isEmpty { merged.toolRounds = incoming.toolRounds }
        merged.timings = incoming.timings
        if let usage = incoming.usage { merged.usage = usage }
        if let endpoint = incoming.endpoint { merged.endpoint = endpoint }
        if let startedAt = incoming.startedAt { merged.startedAt = startedAt }
        if let finishedAt = incoming.finishedAt { merged.finishedAt = finishedAt }
        if let error = incoming.error { merged.error = error }
        for key in incoming.extra.keys { merged.extra[key] = incoming.extra[key] }
        return merged
    }

    // MARK: - Bytes

    /// The stored bytes for one artifact, hash-verified.
    func readArtifact(_ ref: ArtifactRef) async throws -> Data {
        try await attachments.read(ref)
    }

    /// What one attachment retained and what it is missing. The ref list comes
    /// from the record alone; the extracted text is checked too, so a damaged
    /// envelope is reported here rather than as present-and-usable while the
    /// resume path silently drops it.
    func retainedSource(conversationID: String, attachmentID: String) async throws -> RetainedSource? {
        guard let record = try await storedRecord(id: conversationID) else { return nil }
        for turn in record.turns {
            for attachment in turn.attachments where attachment.id == attachmentID {
                return await inspectingExtraction(Self.retainedSource(for: attachment))
            }
        }
        return nil
    }

    /// Every retained source in a conversation, for the storage surface.
    func retainedSources(conversationID: String) async throws -> [RetainedSource] {
        guard let record = try await storedRecord(id: conversationID) else { return [] }
        var sources: [RetainedSource] = []
        for attachment in record.attachments {
            sources.append(await inspectingExtraction(Self.retainedSource(for: attachment)))
        }
        return sources
    }

    /// The bytes for one role of one attachment, or nil when that role was
    /// never archived. A missing role is not an error: it is the archive
    /// saying the bytes are not here.
    func retainedBytes(conversationID: String, attachmentID: String, role: ArtifactRef.Kind) async throws -> Data? {
        guard let source = try await retainedSource(conversationID: conversationID, attachmentID: attachmentID) else {
            return nil
        }
        let ref: ArtifactRef?
        switch role {
        case .original: ref = source.original
        case .normalizedImage: ref = source.normalizedImage
        case .extractedText: ref = source.extractedText
        case .requestSnapshot, .unknown: ref = nil
        }
        guard let ref else { return nil }
        return try await attachments.read(ref)
    }

    /// The model-ready text for one attachment, decoding the versioned
    /// extraction artifact when the shared reader wrote one. Nil when no text
    /// was archived, or when the envelope no longer decodes: the storage view
    /// reports that role as damaged rather than lending it a text. A resume
    /// reads this; it never re-extracts and never touches the original
    /// external path.
    func retainedText(conversationID: String, attachmentID: String) async throws -> String? {
        guard let data = try await retainedBytes(
            conversationID: conversationID,
            attachmentID: attachmentID,
            role: .extractedText
        ) else { return nil }
        return ExtractionArtifact.text(in: data)
    }

    /// The preserved structured extraction (sections, locations, units, and
    /// the document's text) for one attachment, when the reader produced one.
    /// Nil for a link or a selection, whose artifact is plain UTF-8 text.
    func retainedDocument(conversationID: String, attachmentID: String) async throws -> ExtractedDocument? {
        guard let data = try await retainedBytes(
            conversationID: conversationID,
            attachmentID: attachmentID,
            role: .extractedText
        ) else { return nil }
        return ExtractionArtifact.document(in: data)
    }

    static func retainedSource(for attachment: AttachmentRecord) -> RetainedSource {
        var missing: [String] = []
        if attachment.artifacts?.original == nil { missing.append("original") }
        if attachment.artifacts?.normalizedImage == nil { missing.append("normalizedImage") }
        if attachment.artifacts?.extractedText == nil { missing.append("extractedText") }
        return RetainedSource(
            attachment: attachment,
            original: attachment.artifacts?.original,
            normalizedImage: attachment.artifacts?.normalizedImage,
            extractedText: attachment.artifacts?.extractedText,
            missingRoles: missing
        )
    }

    /// The ref-only source with an unusable extraction reported. The bytes are
    /// read to answer the one question the refs cannot: does the stored
    /// envelope still decode as the document it was written as? A read failure
    /// is left to the byte paths, which already distinguish missing from
    /// damaged; only an envelope that no longer decodes is marked here, so the
    /// storage view and the resume path agree that the text is not there.
    private func inspectingExtraction(_ source: RetainedSource) async -> RetainedSource {
        guard let ref = source.extractedText,
              let data = try? await attachments.read(ref),
              ExtractionArtifact.isDamaged(data)
        else { return source }
        var inspected = source
        inspected.damagedRoles.append("extractedText")
        return inspected
    }

    /// One conversation exactly as stored.
    func export(id: String) async throws -> Data {
        try await conversations.export(id: id)
    }

    /// Every readable conversation in one bundle.
    func exportAll() async throws -> Data {
        try await conversations.exportAll()
    }

    // MARK: - Deletion

    /// Confirmed deletion: tombstone first, record second, then reclaim the
    /// blobs that only this chat referenced. Idempotent. The tombstone is
    /// what stops an answer already in flight from recreating the chat.
    @discardableResult
    func delete(id: String) async throws -> ChatDeletionReport {
        try await serialized {
            try await self.performDelete(id: id)
        }
    }

    private func performDelete(id: String) async throws -> ChatDeletionReport {
        let alreadyMissing = !conversations.contains(id)
        // Mark before removing: a late write that arrives mid-delete must
        // find the tombstone and refuse.
        try deletions.mark(id)

        var refs: [ArtifactRef] = []
        if let record = try? await conversations.load(id: id) {
            refs = Self.allArtifactRefs(of: record)
        }
        do {
            try await conversations.delete(id: id)
        } catch ConversationArchiveError.missing {
            // Already gone: the tombstone still stands.
        } catch {
            deletions.unmark(id)
            throw error
        }

        var removed: [ArtifactRef] = []
        var gcIssue: String?
        if !refs.isEmpty {
            do {
                removed = try await coordinator.removeArtifactsIfUnreferenced(refs)
            } catch {
                // The chat is deleted; the bytes stay. Surface it, never hide
                // it, and never force a delete on an incomplete scan.
                gcIssue = error.localizedDescription
            }
        }
        return ChatDeletionReport(
            deletedID: id,
            removedArtifacts: removed,
            gcIssue: gcIssue,
            wasAlreadyMissing: alreadyMissing
        )
    }

    /// Confirmed deletion of every chat this archive owns.
    ///
    /// Fail-closed, in this order:
    ///
    /// 1. **Preflight.** Every record is listed and read first. A record that
    ///    cannot be read throws before anything is touched, because "could not
    ///    read" must never become "deleted".
    /// 2. **Tombstone.** Every chat is marked before any record is removed, so
    ///    a checkpoint or answer already in flight cannot recreate one.
    /// 3. **Remove.** Each record is deleted. A record whose delete fails has
    ///    its tombstone removed again, so it stays visible and undeleted
    ///    rather than vanishing from the list with its file still on disk.
    /// 4. **Reclaim.** Only artifacts no readable record still references are
    ///    removed. A GC that cannot run is reported, and the bytes stay.
    ///
    /// Original user files are never touched: only archived copies.
    @discardableResult
    func deleteAll() async throws -> ChatArchiveDeleteReport {
        try await serialized {
            try await self.performDeleteAll()
        }
    }

    private func performDeleteAll() async throws -> ChatArchiveDeleteReport {
        let summaries = try await conversations.list()
        for summary in summaries {
            if let issue = summary.issue {
                throw ChatArchiveError.recordUnreadable(id: summary.id, detail: issue.rawValue)
            }
        }
        var records: [ConversationRecord] = []
        for summary in summaries {
            do {
                records.append(try await conversations.load(id: summary.id))
            } catch {
                throw ChatArchiveError.recordUnreadable(id: summary.id, detail: String(describing: error))
            }
        }

        var deleted: [String] = []
        var failed: [String] = []
        var refs: [ArtifactRef] = []
        for record in records {
            do {
                try deletions.mark(record.id)
                refs += Self.allArtifactRefs(of: record)
            } catch {
                failed.append(record.id)
            }
        }
        for record in records where !failed.contains(record.id) {
            do {
                try await conversations.delete(id: record.id)
                deleted.append(record.id)
            } catch ConversationArchiveError.missing {
                deleted.append(record.id)
            } catch {
                deletions.unmark(record.id)
                failed.append(record.id)
            }
        }

        var removed: [ArtifactRef] = []
        var gcIssue: String?
        if !refs.isEmpty {
            do {
                removed = try await coordinator.removeArtifactsIfUnreferenced(refs)
            } catch {
                gcIssue = error.localizedDescription
            }
        }
        return ChatArchiveDeleteReport(
            requestedIDs: records.map(\.id),
            deletedIDs: deleted,
            failedIDs: failed,
            removedArtifacts: removed,
            gcIssue: gcIssue
        )
    }

    /// Explicit, reference-safe cleanup: removes every artifact no readable
    /// record points at. Runs only when a caller asks, never on a timer.
    /// Throws (and removes nothing) when any record cannot be read.
    @discardableResult
    func removeUnreferencedArtifacts() async throws -> [ArtifactRef] {
        let all = try await attachments.list()
        return try await coordinator.removeArtifactsIfUnreferenced(all)
    }

    static func allArtifactRefs(of record: ConversationRecord) -> [ArtifactRef] {
        var refs: [ArtifactRef] = []
        for attachment in record.attachments {
            if let original = attachment.artifacts?.original { refs.append(original) }
            if let image = attachment.artifacts?.normalizedImage { refs.append(image) }
            if let text = attachment.artifacts?.extractedText { refs.append(text) }
        }
        for turn in record.turns {
            for snapshot in turn.request?.attachmentRefs ?? [] {
                if let hash = snapshot.snapshotHash {
                    refs.append(ArtifactRef(
                        kind: .requestSnapshot,
                        sha256: hash,
                        byteCount: snapshot.byteCount ?? 0
                    ))
                }
            }
        }
        return refs
    }

    // MARK: - Projection

    /// Rebuilds the app's in-memory `[QuickConversation]` from the canonical
    /// records, in `ordered` order. Fails closed on a damaged record: a
    /// projection built from a partial set would look authoritative and not
    /// be.
    func rebuildProjections() async throws -> [QuickConversation] {
        let projection = try await projectReadable()
        return projection.conversations
    }

    /// The projection next to the records it could not read. A record that
    /// cannot be represented (no usable provider) is reported in `damaged`
    /// rather than silently skipped.
    func projectReadable() async throws -> ChatProjection {
        let (records, damaged) = try await readableRecords()
        var conversations: [QuickConversation] = []
        var unrepresentable = damaged
        for record in records {
            if let conversation = Self.legacyConversation(for: record) {
                conversations.append(conversation)
            } else {
                unrepresentable.append(ConversationSummary(
                    id: record.id,
                    title: record.title,
                    surface: record.surface,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    turnCount: record.turns.count,
                    schemaVersion: record.schemaVersion,
                    issue: .corrupt
                ))
            }
        }
        return ChatProjection(conversations: QuickHistoryOrdering.ordered(conversations), damaged: unrepresentable)
    }

    // MARK: - Legacy migration

    /// Imports the app's legacy `[QuickConversation]` once, then verifies the
    /// cutover by reading every imported record back and comparing its turns.
    ///
    /// Idempotent: `saveIfAbsent` writes only a chat whose ID is not already
    /// present, so a second run changes nothing. An existing file is never
    /// replaced, even a damaged one. A tombstoned chat is not re-imported.
    /// Existing bytes are never re-read or re-fetched: a legacy reference
    /// with no archived artifact stays explicitly missing.
    func migrate(legacy: [QuickConversation], appVersion: String?) async -> ChatMigrationReport {
        do {
            return try await serialized {
                await self.performMigration(legacy: legacy, appVersion: appVersion)
            }
        } catch {
            var report = ChatMigrationReport()
            report.failed = legacy.count
            report.failures.append(error.localizedDescription)
            report.verified = false
            return report
        }
    }

    private func performMigration(legacy: [QuickConversation], appVersion: String?) async -> ChatMigrationReport {
        var report = ChatMigrationReport()
        var imported: [String] = []
        var expectedTurns: [String: Set<String>] = [:]

        for conversation in legacy {
            let id = conversation.id.uuidString
            if deletions.contains(id) {
                report.alreadyPresent += 1
                continue
            }
            if conversations.contains(id) {
                report.alreadyPresent += 1
                continue
            }
            var record = Self.record(for: conversation)
            record.appVersion = appVersion
            do {
                let wrote = try await conversations.saveIfAbsent(record)
                if wrote {
                    report.imported += 1
                    imported.append(id)
                    expectedTurns[id] = Set(conversation.messages.map(\.id.uuidString))
                } else {
                    report.alreadyPresent += 1
                }
            } catch {
                report.failed += 1
                report.failures.append("\(id): \(error.localizedDescription)")
            }
        }

        // Verified cutover: every record we just wrote must read back with the
        // same turn identities, or the import is not safe to treat as done.
        for id in imported {
            do {
                let stored = try await conversations.load(id: id)
                let storedTurns = Set(stored.turns.map(\.id))
                if storedTurns != expectedTurns[id] {
                    report.verified = false
                    report.failures.append("\(id): imported turn set differs on read-back")
                }
            } catch {
                report.verified = false
                report.failures.append("\(id): read-back failed: \(error.localizedDescription)")
            }
        }
        return report
    }

    // MARK: - Conversion

    /// One legacy conversation as a durable record, preserving every
    /// Quick-Launch-only field in the namespaced `appPayload`.
    static func record(for conversation: QuickConversation) -> ConversationRecord {
        var payload = AppPayload(namespace: namespace)
        payload["providerID"] = .string(conversation.providerID.uuidString)
        payload["model"] = .string(conversation.model)
        if let customTitle = conversation.customTitle { payload["customTitle"] = .string(customTitle) }
        if let titleSource = conversation.titleSource { payload["titleSource"] = .string(titleSource) }
        payload["isPinned"] = .bool(conversation.isPinned)
        if let enabledTools = conversation.enabledTools {
            payload["enabledTools"] = .array(enabledTools.map { .string($0.rawValue) }.sorted { lhs, rhs in
                if case .string(let a) = lhs, case .string(let b) = rhs { return a < b }
                return false
            })
        }
        if let assistantID = conversation.assistantID {
            payload["assistantID"] = .string(assistantID.uuidString)
        }
        if let cosCard = conversation.cosCard {
            payload["cosCard"] = .string(cosCard)
        }

        return ConversationRecord(
            id: conversation.id.uuidString,
            surface: surface,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            turns: conversation.messages.map(turn(for:)),
            appPayload: payload
        )
    }

    /// One legacy message as a turn, keeping the card and the tool records in
    /// the turn's own namespaced payload.
    static func turn(for message: QuickMessage) -> TurnRecord {
        var payload = AppPayload(namespace: namespace)
        if let question = message.askUserQuestion {
            payload["askUserQuestion"] = jsonValue(question)
        }
        if let tools = message.toolRecords {
            payload["toolRecords"] = jsonValue(tools)
        }
        if let told = message.cosTell {
            payload["cosTell"] = jsonValue(told)
        }
        return TurnRecord(
            id: message.id.uuidString,
            role: TurnRole(rawValue: message.role.rawValue) ?? .unknown,
            text: message.content,
            attachments: (message.attachments ?? []).map(attachment(for:)),
            appPayload: payload.isEmpty ? nil : payload
        )
    }

    /// One legacy attachment reference as a record. No bytes are invented:
    /// `artifacts` is nil, so the archive reports the bytes as missing.
    static func attachment(for reference: ChatAttachmentRef) -> AttachmentRecord {
        AttachmentRecord(
            id: reference.id.uuidString,
            kind: AttachmentKind(rawValue: reference.kind.rawValue) ?? .other,
            kindRaw: reference.kind.rawValue,
            name: reference.name,
            byteCount: reference.byteCount,
            pageCount: reference.pageCount,
            characterCount: reference.characterCount,
            truncation: truncation(for: reference.truncation),
            contentHash: reference.contentHash,
            extractorVersion: reference.extractorVersion,
            path: reference.path,
            url: reference.url,
            pixelWidth: reference.pixelWidth,
            pixelHeight: reference.pixelHeight,
            addedAt: reference.addedAt,
            artifacts: nil
        )
    }

    static func truncation(for truncation: AttachmentTruncation?) -> TextTruncation? {
        guard let truncation else { return nil }
        return TextTruncation(
            keptCharacters: truncation.keptCharacters,
            totalCharacters: truncation.totalCharacters,
            unit: truncation.unit.flatMap { DocumentUnit(rawValue: $0.rawValue) },
            keptUnits: truncation.keptUnits,
            totalUnits: truncation.totalUnits
        )
    }

    // MARK: - Reverse conversion (projection rebuild)

    static func legacyConversation(for record: ConversationRecord) -> QuickConversation? {
        guard let id = UUID(uuidString: record.id) else { return nil }
        let payload = record.appPayload?.namespace == namespace ? record.appPayload : nil
        guard let providerID = payload?["providerID"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        let model = payload?["model"]?.stringValue ?? ""
        let enabledTools: Set<ChatToolKind>? = payload?["enabledTools"]?.arrayValue.map { values in
            Set(values.compactMap { $0.stringValue.flatMap(ChatToolKind.init(rawValue:)) })
        }
        let assistantID = payload?["assistantID"]?.stringValue.flatMap(UUID.init(uuidString:))
        return QuickConversation(
            id: id,
            createdAt: record.createdAt ?? Date(),
            updatedAt: record.updatedAt ?? Date(),
            providerID: providerID,
            model: model,
            messages: record.turns.compactMap(legacyMessage(for:)),
            customTitle: payload?["customTitle"]?.stringValue,
            titleSource: payload?["titleSource"]?.stringValue,
            isPinned: payload?["isPinned"]?.boolValue ?? false,
            enabledTools: enabledTools,
            assistantID: assistantID,
            cosCard: payload?["cosCard"]?.stringValue
        )
    }

    static func legacyMessage(for turn: TurnRecord) -> QuickMessage? {
        guard let id = UUID(uuidString: turn.id),
              let role = QuickMessage.Role(rawValue: turn.role.rawValue)
        else { return nil }
        let payload = turn.appPayload?.namespace == namespace ? turn.appPayload : nil
        return QuickMessage(
            id: id,
            role: role,
            content: turn.text,
            askUserQuestion: payload?["askUserQuestion"].flatMap { Self.decodeValue($0, as: AskUserQuestion.self) },
            toolRecords: payload?["toolRecords"].flatMap { Self.decodeValue($0, as: [ChatToolRecord].self) },
            attachments: turn.attachments.isEmpty ? nil : turn.attachments.map(legacyReference(for:)),
            cosTell: payload?["cosTell"].flatMap { Self.decodeValue($0, as: CosTold.self) }
        )
    }

    static func legacyReference(for record: AttachmentRecord) -> ChatAttachmentRef {
        ChatAttachmentRef(
            id: UUID(uuidString: record.id) ?? UUID(),
            kind: ChatAttachmentKind(rawValue: record.kindRaw ?? record.kind.rawValue) ?? .text,
            name: record.name,
            byteCount: record.byteCount,
            pageCount: record.pageCount,
            characterCount: record.characterCount,
            truncation: record.truncation.map { trunc in
                AttachmentTruncation(
                    keptCharacters: trunc.keptCharacters,
                    totalCharacters: trunc.totalCharacters,
                    unit: trunc.unit.flatMap { AttachmentTruncation.Unit(rawValue: $0.rawValue) },
                    keptUnits: trunc.keptUnits,
                    totalUnits: trunc.totalUnits
                )
            },
            contentHash: record.contentHash,
            extractorVersion: record.extractorVersion,
            path: record.path,
            url: record.url,
            pixelWidth: record.pixelWidth,
            pixelHeight: record.pixelHeight,
            addedAt: record.addedAt ?? Date()
        )
    }

    // MARK: - Artifacts for a turn

    /// The bytes this turn archives and the snapshot refs its receipt should
    /// carry, built from what the reader already handed over.
    ///
    /// **No source path is read here.** A file that changed or was deleted
    /// after it was read cannot defeat the snapshot: the bytes come from
    /// `AttachmentContent`, and when the reader did not keep them, the role
    /// stays missing rather than being faked from a normalized image.
    ///
    /// A document the shared extractor read is stored behind the versioned
    /// `ExtractionArtifact` header, so the structured sections and locations
    /// survive for a resume. Links and selections store plain UTF-8 text.
    static func prepareArtifacts(
        for contents: [AttachmentContent],
        requestSnapshot: Data? = nil,
        requestSnapshotKind: String? = nil
    ) -> (artifacts: [PendingArtifact], snapshotRefs: [AttachmentSnapshotRef]) {
        var artifacts: [PendingArtifact] = []
        var refs: [AttachmentSnapshotRef] = []

        for (index, content) in contents.enumerated() {
            let ref = content.ref
            let attachmentID = ref.id.uuidString

            if let original = content.originalBytes,
               ref.contentHash == nil || SHA256Digest.hex(original) == ref.contentHash {
                artifacts.append(PendingArtifact(
                    role: .original,
                    data: original,
                    fileExtension: fileExtension(for: ref),
                    attachmentIndex: index
                ))
                refs.append(AttachmentSnapshotRef(
                    attachmentID: attachmentID,
                    contentHash: ref.contentHash,
                    snapshotHash: SHA256Digest.hex(original),
                    kind: "original",
                    byteCount: original.count
                ))
            }

            if let image = content.normalizedImage {
                artifacts.append(PendingArtifact(
                    role: .normalizedImage,
                    data: image.data,
                    fileExtension: image.mimeType == "image/jpeg" ? "jpg" : "png",
                    attachmentIndex: index
                ))
                refs.append(AttachmentSnapshotRef(
                    attachmentID: attachmentID,
                    contentHash: ref.contentHash,
                    snapshotHash: SHA256Digest.hex(image.data),
                    kind: "normalizedImage",
                    byteCount: image.data.count
                ))
            }

            if let extraction = extractionArtifact(for: content) {
                artifacts.append(PendingArtifact(
                    role: .extractedText,
                    data: extraction.data,
                    fileExtension: extraction.fileExtension,
                    attachmentIndex: index
                ))
                refs.append(AttachmentSnapshotRef(
                    attachmentID: attachmentID,
                    contentHash: ref.contentHash,
                    snapshotHash: SHA256Digest.hex(extraction.data),
                    kind: extraction.kind,
                    byteCount: extraction.data.count,
                    characterCount: extraction.characterCount
                ))
            }
        }

        if let snapshot = requestSnapshot, !snapshot.isEmpty {
            artifacts.append(PendingArtifact(
                role: .requestSnapshot,
                data: snapshot,
                fileExtension: requestSnapshotKind ?? "json"
            ))
            refs.append(AttachmentSnapshotRef(
                snapshotData: snapshot,
                kind: requestSnapshotKind ?? "requestSnapshot"
            ))
        }
        return (artifacts, refs)
    }

    /// The one extraction artifact for a content: the versioned structured
    /// document when the shared reader produced one, plain text otherwise.
    /// Nil when there is neither.
    static func extractionArtifact(
        for content: AttachmentContent
    ) -> (data: Data, fileExtension: String, kind: String, characterCount: Int?)? {
        if let document = content.extractedDocument {
            guard let data = ExtractionArtifact.encode(document: document) else { return nil }
            return (
                data,
                "json",
                "extractedDocument",
                document.characterCount ?? content.text?.count
            )
        }
        guard let text = content.text, !text.isEmpty else { return nil }
        return (Data(text.utf8), "txt", "extractedText", text.count)
    }

    /// Compatibility shim for callers that only need the artifact list.
    static func pendingArtifacts(for contents: [AttachmentContent]) -> [PendingArtifact] {
        prepareArtifacts(for: contents).artifacts
    }

    /// The receipt written at Send. It already carries the snapshot hash of
    /// every byte this commit writes, so the reference scan sees them.
    static func receipt(for submission: TurnSubmission, attachmentRefs: [AttachmentSnapshotRef]) -> RequestReceipt {
        var receipt = RequestReceipt(
            id: submission.receiptID ?? UUID().uuidString,
            selection: submission.model,
            status: .pending,
            context: submission.context,
            attachmentRefs: attachmentRefs,
            toolRounds: submission.toolRounds,
            endpoint: submission.endpoint,
            startedAt: submission.startedAt ?? Date()
        )
        if let tools = submission.tools {
            receipt.extra["tools"] = .array(
                tools.map { .string($0.rawValue) }.sorted { lhs, rhs in
                    if case .string(let a) = lhs, case .string(let b) = rhs { return a < b }
                    return false
                }
            )
        }
        return receipt.sanitizedForStorage()
    }

    static func fileExtension(for ref: ChatAttachmentRef) -> String? {
        if let path = ref.path {
            let ext = URL(fileURLWithPath: path).pathExtension
            if !ext.isEmpty { return ext }
        }
        return ref.kind.rawValue
    }

    // MARK: - JSON helpers

    static func jsonValue<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? HouseChatCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    static func decodeValue<T: Decodable>(_ value: JSONValue, as type: T.Type) -> T? {
        guard let data = try? HouseChatCoding.makeEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Serialization and guards

    /// Runs `body` after every previously enqueued write has finished.
    private func serialized<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = writeChain
        let task = Task { () -> T in
            if let previous { await previous.value }
            return try await body()
        }
        writeChain = Task { _ = try? await task.value }
        return try await task.value
    }

    private nonisolated func ensureNotDeleted(_ id: String) throws {
        if deletions.contains(id) {
            throw ChatArchiveError.conversationDeleted(id: id)
        }
    }
}

/// Quick Launch's chat ordering, shared by the projection and the legacy
/// cache so both read the same way.
enum QuickHistoryOrdering {
    /// Pinned chats first, then newest first.
    static func ordered(_ conversations: [QuickConversation]) -> [QuickConversation] {
        conversations.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }
}

/// Storage usage for the Settings surface.
struct ChatArchiveUsage: Sendable, Equatable {
    var conversationCount: Int
    var damagedConversationCount: Int
    var artifactBytes: Int
}

/// What one migration run did.
struct ChatMigrationReport: Sendable, Equatable {
    var imported = 0
    var alreadyPresent = 0
    var failed = 0
    /// False when a read-back check failed: the import is not safe to treat
    /// as complete and the legacy file must stay as rollback data.
    var verified = true
    var failures: [String] = []

    var isClean: Bool { failed == 0 && verified }
}

/// Why an archive write was refused.
enum ChatArchiveError: Error, LocalizedError, Equatable {
    case noUserTurn(conversationID: String)
    case noConversation(conversationID: String)
    /// The user deleted this chat; a late write must not recreate it.
    case conversationDeleted(id: String)
    /// A record exists but cannot be read. A rewrite would replace it, so it
    /// is refused instead.
    case recordUnreadable(id: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .noUserTurn(let id): "Conversation \(id) has no user turn to archive"
        case .noConversation(let id): "Conversation \(id) has no archive record"
        case .conversationDeleted(let id): "Conversation \(id) was deleted"
        case .recordUnreadable(let id, let detail): "Conversation \(id) cannot be read: \(detail)"
        }
    }
}
