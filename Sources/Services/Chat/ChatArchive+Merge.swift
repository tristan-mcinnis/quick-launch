import Foundation
import HouseChatCore

extension ChatArchive {
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
        // Links only accumulate: a link the stored record lacks is added.
        merged.sessionLinks += live.sessionLinks.filter { !stored.sessionLinks.contains($0) }
        merged.updatedAt = later(live.updatedAt, stored.updatedAt)
        merged.turns = mergeTurns(live: live.turns, stored: stored.turns)
        return merged
    }

    static func merge(liveTurn live: TurnRecord, into stored: TurnRecord) -> TurnRecord {
        // A projection can carry an older copy of the same turn: the other
        // window's history, a reload, or a retry of a write that failed before
        // a newer one landed. A stream only appends to its turn's text, and a
        // regenerated answer is a new turn id, so a live text that is a strict
        // prefix of a terminal stored text is older, never a replacement.
        // Preserve the answer and receipt, but still add ancillary data only
        // this older copy carries. Matching attachments keep their stored values.
        if live.text.count < stored.text.count,
           stored.text.hasPrefix(live.text),
           let status = stored.request?.status,
           status != .pending, status != .streaming, status != .unknown {
            return mergeReplay(liveTurn: live, into: stored)
        }
        var merged = stored
        merged.role = live.role
        merged.text = live.text
        merged.attachments = mergeAttachments(live: live.attachments, stored: stored.attachments)
        var payload = mergingAppPayload(live: live.appPayload, stored: stored.appPayload, owned: turnOwnedKeys)
        // Tool lines accumulate; list length cannot prove that one copy
        // contains the other's records. Keep stored values and add missing ones.
        if let status = stored.request?.status,
           status != .pending, status != .streaming, status != .unknown,
           let records = mergingToolRecordPayload(
               live: live.appPayload?["toolRecords"], stored: stored.appPayload?["toolRecords"]
           ) {
            if payload == nil { payload = AppPayload(namespace: namespace) }
            payload?["toolRecords"] = records
        }
        merged.appPayload = payload
        if merged.createdAt == nil { merged.createdAt = live.createdAt }
        // Links only accumulate: a link the stored record lacks is added.
        merged.sessionLinks += live.sessionLinks.filter { !stored.sessionLinks.contains($0) }
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

    /// The replay of an older snapshot: additive only. Every stored value
    /// stays; live values fill gaps. Used by `applyProjection(_:replay:)`.
    static func mergeReplay(live: ConversationRecord, into stored: ConversationRecord) -> ConversationRecord {
        var merged = stored
        var payload = stored.appPayload ?? AppPayload(namespace: namespace)
        let livePayload = live.appPayload ?? AppPayload(namespace: namespace)
        for key in conversationOwnedKeys where payload[key] == nil {
            if let value = livePayload[key] { payload[key] = value }
        }
        merged.appPayload = payload.isEmpty ? nil : payload
        if merged.title == nil, let title = live.title { merged.title = title }
        if merged.createdAt == nil { merged.createdAt = live.createdAt }
        merged.sessionLinks += live.sessionLinks.filter { !stored.sessionLinks.contains($0) }
        merged.updatedAt = later(merged.updatedAt, live.updatedAt)
        merged.turns = mergeReplayTurns(live: live.turns, stored: stored.turns)
        return merged
    }

    /// One turn of a replay: fill gaps, extend a stored text that the live copy
    /// continues, and never replace a divergent or shorter text.
    static func mergeReplay(liveTurn live: TurnRecord, into stored: TurnRecord) -> TurnRecord {
        var merged = stored
        if stored.text.isEmpty, !live.text.isEmpty {
            merged.text = live.text
        } else if live.text.count > stored.text.count, live.text.hasPrefix(stored.text) {
            merged.text = live.text
        }
        let storedAttachmentIDs = Set(stored.attachments.map(\.id))
        merged.attachments = stored.attachments + live.attachments.filter { !storedAttachmentIDs.contains($0.id) }
        if let livePayload = live.appPayload {
            var payload = stored.appPayload ?? AppPayload(namespace: namespace)
            for key in livePayload.values.keys where payload[key] == nil {
                payload[key] = livePayload[key]
            }
            payload["toolRecords"] = mergingToolRecordPayload(
                live: livePayload["toolRecords"], stored: stored.appPayload?["toolRecords"]
            )
            merged.appPayload = payload.isEmpty ? nil : payload
        }
        if merged.createdAt == nil { merged.createdAt = live.createdAt }
        merged.sessionLinks += live.sessionLinks.filter { !stored.sessionLinks.contains($0) }
        return merged
    }

    /// Tool records have value identity, not an event ID. Preserve stored
    /// order and values, then append distinct missing records. Unknown or
    /// malformed payloads stay untouched rather than being replaced by a guess.
    private static func mergingToolRecordPayload(live: JSONValue?, stored: JSONValue?) -> JSONValue? {
        guard let stored else { return live }
        guard let live,
              let kept = decodeValue(stored, as: [ChatToolRecord].self),
              let incoming = decodeValue(live, as: [ChatToolRecord].self)
        else { return stored }
        var seen = Set(kept)
        let missing = incoming.filter { seen.insert($0).inserted }
        guard !missing.isEmpty else { return stored }
        return jsonValue(kept + missing) ?? stored
    }

    /// The replay's turn union: stored order and stored content, plus live-only
    /// turns at their stored-relative position. It never drops a stored turn.
    static func mergeReplayTurns(live: [TurnRecord], stored: [TurnRecord]) -> [TurnRecord] {
        var byID: [String: TurnRecord] = [:]
        for turn in stored { byID[turn.id] = turn }
        var storedIndex: [String: Int] = [:]
        for (index, turn) in stored.enumerated() { storedIndex[turn.id] = index }
        var result = live.map { turn in
            guard let existing = byID[turn.id] else { return turn }
            return mergeReplay(liveTurn: turn, into: existing)
        }
        let liveIDs = Set(live.map(\.id))
        for (index, turn) in stored.enumerated() where !liveIDs.contains(turn.id) {
            result.insert(turn, at: Self.insertionPoint(forStoredIndex: index, in: result, storedIndex: storedIndex))
        }
        return result
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
}
