import Foundation
import HouseChatCore

/// The archive work one finished answer owes, frozen when the answer becomes
/// final. Nothing here is read from the chat again: a retry writes the same
/// bytes, never a newer turn.
struct AnswerTerminalWrite {
    let conversationID: UUID
    let turnID: UUID
    let status: RequestStatus
    let error: String?
    let text: String?
    let receipt: RequestReceipt?
    let selection: ModelSelection?
    let timings: RequestTimings
    let usage: TokenUsage?
    let toolRounds: [ToolRound]?
    /// The turn's own round counter, so the receipt carries `modelRounds`.
    /// Its count is fixed once the stream ends.
    let rounds: ChatRoundRecorder?
    /// The checkpoint in flight when the answer became final. A checkpoint
    /// writes `.streaming`, so the terminal write waits for it.
    let checkpointFence: Task<Void, Never>?
}

/// Why one owed write did not land, for the view model to log and surface.
struct AnswerWriteFailure: Equatable {
    enum Kind: Equatable {
        case terminal
        case projection
        case deletion
    }

    let kind: Kind
    let message: String
}

/// The three archive writes the ledger owns. A test supplies a scripted
/// adapter; the app supplies the `ChatArchive` one.
@MainActor
protocol AnswerArchiveWriting {
    func writeTerminal(_ write: AnswerTerminalWrite) async throws
    func writeProjection(
        _ conversation: QuickConversation,
        after fence: Task<Void, Never>?,
        replay: Bool
    ) async throws
    func writeDeletion(_ conversationID: UUID) async throws
}

/// The archive writer the app uses. `conversationDeleted` is rethrown as it
/// is: the ledger treats that settled, serialized result as durable evidence
/// that the chat was deleted, never a failure to retry.
@MainActor
struct ChatArchiveAnswerWriter: AnswerArchiveWriting {
    let archive: ChatArchive

    func writeTerminal(_ write: AnswerTerminalWrite) async throws {
        // The checkpoint in flight would otherwise land after this write and
        // put `.streaming` back.
        await write.checkpointFence?.value
        var timings = write.timings
        var receipt = write.receipt
        if let rounds = write.rounds {
            let count = await rounds.requestedRounds
            if count > 0 {
                timings.extra["modelRounds"] = .number(Double(count))
                receipt?.timings.extra["modelRounds"] = .number(Double(count))
            }
        }
        let conversationID = write.conversationID.uuidString
        let turnID = write.turnID.uuidString
        if write.status == .completed {
            _ = try await archive.completeTurn(
                conversationID: conversationID,
                turnID: turnID,
                text: write.text ?? "",
                receipt: receipt,
                selection: write.selection,
                timings: timings,
                usage: write.usage,
                toolRounds: write.toolRounds
            )
        } else {
            _ = try await archive.failTurn(
                conversationID: conversationID,
                turnID: turnID,
                error: write.error ?? "",
                status: write.status,
                text: write.text,
                timings: timings,
                usage: write.usage,
                toolRounds: write.toolRounds
            )
        }
    }

    func writeProjection(
        _ conversation: QuickConversation,
        after fence: Task<Void, Never>?,
        replay: Bool
    ) async throws {
        await fence?.value
        try await archive.applyProjection(conversation, replay: replay)
    }

    func writeDeletion(_ conversationID: UUID) async throws {
        _ = try await archive.delete(id: conversationID.uuidString)
    }
}

/// Every mandatory archive write the chat owes, kept as debt until it lands or
/// the chat is durably deleted.
///
/// ## Why entries and not flags
///
/// An answer becomes durable in more than one step: the terminal turn write and
/// the whole-conversation projection. A quit must wait for both, per turn, and
/// must know which part failed so a retry writes only that part. Task handles in
/// shared slots cannot express that: a later turn overwrote an earlier one's
/// retry, and a spent handle read as debt forever.
///
/// ## Invariants
///
/// - `register` is synchronous and runs before the caller's first suspension,
///   so a quit at any later suspension point sees the debt.
/// - An entry's payload is immutable. A retry reuses it, so a retry can never
///   write a newer turn or a newer text.
/// - This view model queues writes per conversation. An older retry following
///   its own newer landed write uses additive replay. Other view models'
///   snapshot revisions are not ranked by this ledger.
/// - An entry is retired only when its own write lands or a settled serialized
///   write reports `conversationDeleted`. No later write retires earlier debt;
///   a pending newer version never counts as saved.
/// - No cap, no age rule, no eviction.
@MainActor
final class AnswerDurability {
    /// What a settle says about the work it was given.
    enum Verdict: Equatable {
        case durable
        case unsavedActivity
        case incompleteDeletion
    }

    /// The work one freeze owns. Opaque to callers, and the only input a settle
    /// reads besides the ledger's own state.
    struct Snapshot {
        let revision: Int
        fileprivate let attempts: [Attempt]
        fileprivate struct Attempt {
            let key: Key
            let generation: Int
            let task: Task<Bool, Never>
        }

        static let empty = Snapshot(revision: 0, attempts: [])
    }

    fileprivate enum Key: Hashable {
        case terminal(UUID, UUID)
        case projection(UUID, Int)
        case deletion(UUID)
    }

    private enum Work {
        case terminal(AnswerTerminalWrite)
        case projection(QuickConversation, Task<Void, Never>?)
        case deletion(UUID)
    }

    private struct Entry {
        let key: Key
        let conversationID: UUID
        let sequence: Int
        let kind: AnswerWriteFailure.Kind
        let work: Work
        var generation: Int
        var task: Task<Bool, Never>?
    }

    private let writer: any AnswerArchiveWriting
    /// A landed deletion message or a log line, for the view model. Never used
    /// to decide durability.
    var onFailure: ((AnswerWriteFailure) -> Void)?

    private var entries: [Key: Entry] = [:]
    /// The newest sequence that landed for a chat. A projection retried behind
    /// it is a replay: additive, never a rewrite.
    private var lastLandedSequence: [UUID: Int] = [:]
    private var nextSequence = 0
    /// Bumped by every accepted activity and every registered write. A settle
    /// against an older revision describes a stale attempt.
    private(set) var revision = 0

    init(writer: any AnswerArchiveWriting) {
        self.writer = writer
    }

    /// Outstanding writes. Tests and diagnostics only.
    var pendingCount: Int { entries.count }
    var isIdle: Bool { entries.isEmpty }

    /// A submit accepted before its first suspension, so a quit during
    /// enrichment or before the first token is not mistaken for a quiet app.
    func noteActivity() {
        revision &+= 1
    }

    /// The final answer of one turn. Synchronous: call it where the text is
    /// final, never after an await.
    @discardableResult
    func register(_ write: AnswerTerminalWrite) -> Task<Bool, Never>? {
        let key = Key.terminal(write.conversationID, write.turnID)
        guard entries[key] == nil else { return entries[key]?.task }
        revision &+= 1
        nextSequence &+= 1
        entries[key] = Entry(
            key: key,
            conversationID: write.conversationID,
            sequence: nextSequence,
            kind: .terminal,
            work: .terminal(write),
            generation: 0,
            task: nil
        )
        return start(key)
    }

    /// One projection of the whole conversation. A distinct snapshot is a
    /// distinct entry; only the identical pending snapshot is skipped.
    func record(_ conversation: QuickConversation, after checkpointFence: Task<Void, Never>? = nil) {
        let conversationID = conversation.id
        let alreadyOwed = entries.values.contains { entry in
            guard entry.conversationID == conversationID, entry.kind == .projection,
                  case .projection(let stored, _) = entry.work
            else { return false }
            return stored == conversation
        }
        guard !alreadyOwed else { return }
        revision &+= 1
        nextSequence &+= 1
        let key = Key.projection(conversationID, nextSequence)
        entries[key] = Entry(
            key: key,
            conversationID: conversationID,
            sequence: nextSequence,
            kind: .projection,
            work: .projection(conversation, checkpointFence),
            generation: 0,
            task: nil
        )
        start(key)
    }

    /// The user's delete. A failed delete stays owed, so a record and its
    /// answer cannot survive behind an error the user may never see.
    func registerDeletion(_ conversationID: UUID) {
        let key = Key.deletion(conversationID)
        guard entries[key] == nil else { return }
        revision &+= 1
        nextSequence &+= 1
        entries[key] = Entry(
            key: key,
            conversationID: conversationID,
            sequence: nextSequence,
            kind: .deletion,
            work: .deletion(conversationID),
            generation: 0,
            task: nil
        )
        start(key)
    }

    /// Freezes the work a quit owns. Failed entries get one new attempt from
    /// their own frozen payload; entries already running keep their one task.
    /// Captures the revision, so the caller can tell whether activity was
    /// accepted after this freeze.
    func freeze() -> Snapshot {
        let retryable = entries.keys
            .filter { entries[$0]?.task == nil }
            .sorted { (entries[$0]?.sequence ?? 0) < (entries[$1]?.sequence ?? 0) }
        for key in retryable {
            entries[key]?.generation &+= 1
            start(key)
        }
        let attempts = entries.values.compactMap { entry in
            entry.task.map { Snapshot.Attempt(key: entry.key, generation: entry.generation, task: $0) }
        }
        return Snapshot(revision: revision, attempts: attempts)
    }

    /// Awaits exactly the frozen writes, then reports which debt remains.
    /// Work registered after the freeze is not this attempt's; the caller's
    /// revision check catches it.
    func settle(_ snapshot: Snapshot) async -> Verdict {
        for attempt in snapshot.attempts {
            _ = await attempt.task.value
        }
        let frozen = Set(snapshot.attempts.map(\.key))
        let pending = entries.keys.filter { frozen.contains($0) }
        if pending.contains(where: { key in
            if case .deletion = key { return true }
            return false
        }) {
            return .incompleteDeletion
        }
        return pending.isEmpty ? .durable : .unsavedActivity
    }

    // MARK: - Attempts

    @discardableResult
    private func start(_ key: Key) -> Task<Bool, Never>? {
        guard var entry = entries[key], entry.task == nil else { return nil }
        // Every other write for this conversation is a prerequisite. Sequence
        // order is therefore the write order, and a retry cannot overtake a
        // newer entry that is already running.
        let prerequisites = entries.values
            .filter { $0.key != key && $0.conversationID == entry.conversationID }
            .compactMap(\.task)
        let generation = entry.generation
        let work = entry.work
        let identifier = entry.conversationID
        let sequence = entry.sequence
        let task = Task<Bool, Never> { @MainActor [weak self] in
            for prerequisite in prerequisites {
                _ = await prerequisite.value
            }
            guard let self else { return false }
            // The entry may have been retired (a durable deletion) or replaced
            // while this task waited. Recheck identity and generation before
            // any I/O: retired work never executes.
            guard let current = self.entries[key], current.generation == generation else {
                return false
            }
            // A projection retried behind a newer landed write is a replay.
            let replay = self.lastLandedSequence[identifier, default: 0] > sequence
            do {
                try await self.perform(work, replay: replay)
                self.finish(key, generation: generation, succeeded: true, sequence: sequence)
                return true
            } catch ChatArchiveError.conversationDeleted {
                // A settled serialized write reported the tombstone, so the
                // chat is durably deleted and nothing else is owed for it.
                self.retireConversation(identifier, generation: generation, key: key)
                return true
            } catch {
                self.finish(key, generation: generation, succeeded: false, sequence: sequence, failure: error)
                return false
            }
        }
        entry.task = task
        entries[key] = entry
        return task
    }

    private func perform(_ work: Work, replay: Bool) async throws {
        switch work {
        case .terminal(let write): try await writer.writeTerminal(write)
        case .projection(let conversation, let fence):
            try await writer.writeProjection(conversation, after: fence, replay: replay)
        case .deletion(let conversationID): try await writer.writeDeletion(conversationID)
        }
    }

    private func finish(
        _ key: Key,
        generation: Int,
        succeeded: Bool,
        sequence: Int,
        failure: Error? = nil
    ) {
        guard var entry = entries[key], entry.generation == generation else { return }
        guard succeeded else {
            entry.task = nil
            entries[key] = entry
            onFailure?(AnswerWriteFailure(kind: entry.kind, message: failure?.localizedDescription ?? "unknown"))
            return
        }
        entries[key] = nil
        if entry.kind == .deletion {
            // The tombstone is on disk and the record is gone; nothing else is
            // owed for this chat, and any late write would be refused.
            entries = entries.filter { $0.value.conversationID != entry.conversationID }
            lastLandedSequence[entry.conversationID] = nil
            return
        }
        // A distinct projection stays owed until its own write lands. The only
        // thing a later landing changes is that an older projection retried
        // afterwards is applied as a replay, which cannot erase this write.
        lastLandedSequence[entry.conversationID] = max(
            lastLandedSequence[entry.conversationID] ?? 0,
            sequence
        )
    }

    private func retireConversation(_ conversationID: UUID, generation: Int, key: Key) {
        guard entries[key]?.generation == generation else { return }
        entries = entries.filter { $0.value.conversationID != conversationID }
    }

}
