// AnswerDurabilityTests: the state model behind quit durability, through its
// interface only.
//
// The ledger owns every mandatory archive write as debt: a terminal turn write,
// a projection, or a delete. These tests use a scripted writer, so each failure
// shape is reachable without the file system, and every wait is a gate the test
// opens, never a sleep deciding the outcome.

import Foundation
import HouseChatCore
import Testing
@testable import QuickLaunch

private struct ScriptedWriteError: Error, LocalizedError {
    var errorDescription: String? { "scripted write failure" }
}

/// Holds one write open until the test releases it.
@MainActor
private final class WriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// One recorded write, for asserting what was attempted and in which order.
private enum WrittenCall: Equatable {
    case terminal(conversation: UUID, turn: UUID, text: String, status: RequestStatus)
    case projection(UUID, replay: Bool)
    case deletion(UUID)
}

/// Counts write starts so a test can wait for one without a timer.
@MainActor
private final class CallSignal {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var count = 0

    func record() {
        count += 1
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    func wait(for total: Int) async {
        while count < total {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

@MainActor
private final class ScriptedAnswerWriter: AnswerArchiveWriting {
    /// Outcomes consumed in order per kind; the last value repeats. Empty
    /// means success.
    var terminalOutcomes: [Bool] = []
    var projectionOutcomes: [Bool] = []
    var deletionOutcomes: [Bool] = []
    /// A settled serialized write for these chats reports the tombstone.
    var deletedConversations: Set<UUID> = []
    /// Writes for these chats fail, whatever the outcome queues say.
    var failingConversations: Set<UUID> = []
    /// The next matching call waits for `gate`.
    var holdsNextTerminal = false
    var holdsNextProjection = false
    private(set) var calls: [WrittenCall] = []
    private(set) var gate = WriteGate()
    private(set) var started = CallSignal()

    func waitForWrites(_ count: Int) async {
        await started.wait(for: count)
    }

    func holdNextTerminalWrite() {
        holdsNextTerminal = true
        gate = WriteGate()
    }

    func holdNextProjectionWrite() {
        holdsNextProjection = true
        gate = WriteGate()
    }

    func openGate() { gate.open() }

    func writeTerminal(_ write: AnswerTerminalWrite) async throws {
        calls.append(.terminal(
            conversation: write.conversationID,
            turn: write.turnID,
            text: write.text ?? "",
            status: write.status
        ))
        started.record()
        if holdsNextTerminal {
            holdsNextTerminal = false
            await gate.wait()
        }
        if failingConversations.contains(write.conversationID) {
            throw ScriptedWriteError()
        }
        if deletedConversations.contains(write.conversationID) {
            throw ChatArchiveError.conversationDeleted(id: write.conversationID.uuidString)
        }
        guard consume(&terminalOutcomes) else { throw ScriptedWriteError() }
    }

    func writeProjection(
        _ conversation: QuickConversation,
        after fence: Task<Void, Never>?,
        replay: Bool
    ) async throws {
        await fence?.value
        calls.append(.projection(conversation.id, replay: replay))
        started.record()
        if holdsNextProjection {
            holdsNextProjection = false
            await gate.wait()
        }
        if failingConversations.contains(conversation.id) {
            throw ScriptedWriteError()
        }
        if deletedConversations.contains(conversation.id) {
            throw ChatArchiveError.conversationDeleted(id: conversation.id.uuidString)
        }
        guard consume(&projectionOutcomes) else { throw ScriptedWriteError() }
    }

    func writeDeletion(_ conversationID: UUID) async throws {
        calls.append(.deletion(conversationID))
        if deletedConversations.contains(conversationID) {
            throw ChatArchiveError.conversationDeleted(id: conversationID.uuidString)
        }
        guard consume(&deletionOutcomes) else { throw ScriptedWriteError() }
    }

    private func consume(_ outcomes: inout [Bool]) -> Bool {
        guard !outcomes.isEmpty else { return true }
        return outcomes.removeFirst()
    }
}

@MainActor
private func terminalWrite(
    conversation: UUID,
    turn: UUID = UUID(),
    text: String = "answer",
    status: RequestStatus = .cancelled
) -> AnswerTerminalWrite {
    AnswerTerminalWrite(
        conversationID: conversation,
        turnID: turn,
        status: status,
        error: status == .completed ? nil : "stopped",
        text: text,
        receipt: nil,
        selection: nil,
        timings: RequestTimings(),
        usage: nil,
        toolRounds: nil,
        rounds: nil,
        checkpointFence: nil
    )
}

private func conversation(_ id: UUID = UUID(), text: String = "answer") -> QuickConversation {
    var conversation = QuickConversation(
        id: id,
        providerID: UUID(),
        model: "test-model"
    )
    conversation.messages.append(QuickMessage(id: UUID(), role: .assistant, content: text))
    return conversation
}

@Suite("Answer durability", .serialized)
@MainActor
struct AnswerDurabilityTests {

    @Test func aRegisteredWriteIsDebtBeforeAnyAwait() async {
        let writer = ScriptedAnswerWriter()
        writer.holdNextTerminalWrite()
        let ledger = AnswerDurability(writer: writer)
        let id = UUID()

        ledger.register(terminalWrite(conversation: id))
        // No await yet: the debt exists and the ledger says so.
        #expect(ledger.pendingCount == 1)
        #expect(!ledger.isIdle)

        let snapshot = ledger.freeze()
        // A controlled deadline observes the held write; no sleep decides.
        let unsettled = await withQuitDeadline(.milliseconds(50)) {
            await ledger.settle(snapshot)
        }
        #expect(unsettled == nil)

        writer.openGate()
        #expect(await ledger.settle(snapshot) == .durable)
        #expect(ledger.isIdle)
        #expect(writer.calls.count == 1)
    }

    @Test func repeatedFreezeOfARunningWriteKeepsOneWrite() async {
        let writer = ScriptedAnswerWriter()
        writer.holdNextTerminalWrite()
        let ledger = AnswerDurability(writer: writer)
        ledger.register(terminalWrite(conversation: UUID()))

        await writer.waitForWrites(1)
        let first = ledger.freeze()
        let second = ledger.freeze()
        #expect(writer.calls.count == 1, "one in-flight attempt, not a duplicate")

        writer.openGate()
        #expect(await ledger.settle(first) == .durable)
        #expect(await ledger.settle(second) == .durable)
        #expect(writer.calls.count == 1)
    }

    @Test func aFailedTerminalWriteRetriesOnlyTheTerminalWrite() async {
        let writer = ScriptedAnswerWriter()
        writer.terminalOutcomes = [false, true]
        let ledger = AnswerDurability(writer: writer)
        let id = UUID()
        ledger.register(terminalWrite(conversation: id))
        ledger.record(conversation(id))

        #expect(await ledger.settle(ledger.freeze()) == .unsavedActivity)
        #expect(await ledger.settle(ledger.freeze()) == .durable)
        #expect(writer.calls.filter { if case .terminal = $0 { return true }; return false }.count == 2)
        #expect(writer.calls.filter { if case .projection = $0 { return true }; return false }.count == 1)
    }

    @Test func aFailedProjectionRetriesOnlyTheProjection() async {
        let writer = ScriptedAnswerWriter()
        writer.projectionOutcomes = [false, true]
        let ledger = AnswerDurability(writer: writer)
        let id = UUID()
        ledger.register(terminalWrite(conversation: id))
        ledger.record(conversation(id))

        #expect(await ledger.settle(ledger.freeze()) == .unsavedActivity)
        #expect(await ledger.settle(ledger.freeze()) == .durable)
        #expect(writer.calls.filter { if case .terminal = $0 { return true }; return false }.count == 1)
        #expect(writer.calls.filter { if case .projection = $0 { return true }; return false }.count == 2)
    }

    @Test func twoTurnsInTwoChatsKeepTheirOwnDebt() async {
        let writer = ScriptedAnswerWriter()
        writer.terminalOutcomes = [false, false, true, true]
        let ledger = AnswerDurability(writer: writer)
        let first = UUID()
        let second = UUID()
        let firstTurn = UUID()
        let secondTurn = UUID()
        ledger.register(terminalWrite(conversation: first, turn: firstTurn, text: "first answer"))
        ledger.register(terminalWrite(conversation: second, turn: secondTurn, text: "second answer"))

        #expect(await ledger.settle(ledger.freeze()) == .unsavedActivity)
        #expect(ledger.pendingCount == 2, "neither turn replaced the other")
        #expect(await ledger.settle(ledger.freeze()) == .durable)

        let texts = writer.calls.compactMap { call -> String? in
            if case .terminal(_, let turn, let text, _) = call, turn == firstTurn || turn == secondTurn {
                return text
            }
            return nil
        }
        #expect(texts == ["first answer", "second answer", "first answer", "second answer"])
    }

    @Test func aPendingRetryIsNotProofTheOlderPayloadLanded() async {
        let writer = ScriptedAnswerWriter()
        writer.terminalOutcomes = [false, true]
        let ledger = AnswerDurability(writer: writer)
        let id = UUID()
        ledger.register(terminalWrite(conversation: id))

        let first = ledger.freeze()
        #expect(await ledger.settle(first) == .unsavedActivity)

        // The retry runs and is held open. The older attempt must not report
        // saved just because a newer version exists.
        writer.holdNextTerminalWrite()
        let second = ledger.freeze()
        #expect(await ledger.settle(first) == .unsavedActivity)
        #expect(ledger.pendingCount == 1)

        writer.openGate()
        #expect(await ledger.settle(second) == .durable)
    }

    @Test func aFrozenSettleDoesNotClearNewerDebt() async {
        let writer = ScriptedAnswerWriter()
        writer.holdNextTerminalWrite()
        let ledger = AnswerDurability(writer: writer)
        let id = UUID()
        ledger.register(terminalWrite(conversation: id))
        let frozen = ledger.freeze()
        await writer.waitForWrites(1)

        // New work and a new write are accepted while the frozen one runs.
        // The newer chat's write fails, so the debt is real and independent.
        let newer = UUID()
        writer.failingConversations = [newer]
        ledger.register(terminalWrite(conversation: newer, turn: UUID(), text: "newer"))

        writer.openGate()
        #expect(await ledger.settle(frozen) == .durable, "the frozen write landed")
        #expect(!ledger.isIdle, "the newer debt is still owed, not silently cleared")
        #expect(await ledger.settle(ledger.freeze()) == .unsavedActivity)
    }

    @Test func aSettledDeletedWriteIsAuthoritativeEvidence() async {
        let writer = ScriptedAnswerWriter()
        let id = UUID()
        writer.deletedConversations = [id]
        let ledger = AnswerDurability(writer: writer)
        ledger.register(terminalWrite(conversation: id))
        ledger.record(conversation(id))

        #expect(await ledger.settle(ledger.freeze()) == .durable)
        #expect(ledger.isIdle, "a tombstoned chat owes nothing")
        writer.deletedConversations = []
        #expect(await ledger.settle(ledger.freeze()) == .durable)
        // The projection waiting behind the terminal write was retired by the
        // settled tombstone and never performed its own write.
        #expect(writer.calls.count == 1, "the deletion retired the chat; no second write")
    }

    @Test func aFailedDeletionRefusesUntilItLands() async {
        let writer = ScriptedAnswerWriter()
        writer.deletionOutcomes = [false, true]
        let ledger = AnswerDurability(writer: writer)
        let id = UUID()
        ledger.registerDeletion(id)

        #expect(await ledger.settle(ledger.freeze()) == .incompleteDeletion)
        #expect(ledger.pendingCount == 1)
        #expect(await ledger.settle(ledger.freeze()) == .durable)
        #expect(ledger.isIdle)
    }

    @Test func aLandedDeletionRetiresTheChatsOtherDebt() async {
        let writer = ScriptedAnswerWriter()
        writer.terminalOutcomes = [false]
        let ledger = AnswerDurability(writer: writer)
        let id = UUID()
        ledger.register(terminalWrite(conversation: id))
        ledger.record(conversation(id))
        ledger.registerDeletion(id)

        // The delete lands; the answer write that failed is no longer owed.
        #expect(await ledger.settle(ledger.freeze()) == .durable)
        #expect(ledger.isIdle)
    }

    @Test func anIdenticalPendingProjectionIsNotWrittenTwice() async {
        let writer = ScriptedAnswerWriter()
        writer.holdNextProjectionWrite()
        let ledger = AnswerDurability(writer: writer)
        let id = UUID()
        let snapshot = conversation(id)
        ledger.record(snapshot)
        ledger.record(snapshot)

        #expect(ledger.pendingCount == 1)
        writer.openGate()
        #expect(await ledger.settle(ledger.freeze()) == .durable)
        #expect(writer.calls.count == 1)
    }

    @Test func distinctProjectionsAreEachOwed() async {
        let writer = ScriptedAnswerWriter()
        let ledger = AnswerDurability(writer: writer)
        let id = UUID()
        ledger.record(conversation(id, text: "first"))
        ledger.record(conversation(id, text: "second"))

        #expect(await ledger.settle(ledger.freeze()) == .durable)
        #expect(writer.calls.count == 2, "a distinct snapshot is its own write")
    }

    @Test func activityAloneRaisesTheRevision() async {
        let writer = ScriptedAnswerWriter()
        let ledger = AnswerDurability(writer: writer)
        let before = ledger.revision
        ledger.noteActivity()
        #expect(ledger.revision == before + 1)

        let snapshot = ledger.freeze()
        #expect(snapshot.revision == ledger.revision)
        ledger.noteActivity()
        #expect(ledger.revision != snapshot.revision)
        #expect(await ledger.settle(snapshot) == .durable)
    }

    /// An entry retired while its task waits for a newer one must not perform
    /// its write after the await.
    @Test func aRetiredEntryDoesNotPerformItsWriteAfterAwaitingANewerOne() async {
        let writer = ScriptedAnswerWriter()
        let ledger = AnswerDurability(writer: writer)
        let chat = UUID()

        writer.projectionOutcomes = [false]
        ledger.record(conversation(chat, text: "older"))
        #expect(await ledger.settle(ledger.freeze()) == .unsavedActivity)

        writer.holdNextProjectionWrite()
        ledger.record(conversation(chat, text: "newer"))
        await writer.waitForWrites(2)

        // The retry of the older projection waits for the newer one.
        let frozen = ledger.freeze()
        // The newer write settles as a tombstone, which retires the chat.
        writer.deletedConversations = [chat]
        writer.openGate()
        _ = await ledger.settle(frozen)

        let projections = writer.calls.filter { call in
            if case .projection(let id, _) = call { return id == chat }
            return false
        }
        #expect(projections.count == 2, "the retired retry performed no write")
        #expect(ledger.isIdle)
    }

    @Test func outstandingDebtHasNoCap() async {
        let writer = ScriptedAnswerWriter()
        writer.terminalOutcomes = Array(repeating: false, count: 40) + Array(repeating: true, count: 40)
        let ledger = AnswerDurability(writer: writer)
        for _ in 0..<40 {
            ledger.register(terminalWrite(conversation: UUID()))
        }
        #expect(ledger.pendingCount == 40)
        #expect(await ledger.settle(ledger.freeze()) == .unsavedActivity)
        #expect(ledger.pendingCount == 40, "nothing was evicted")
        #expect(await ledger.settle(ledger.freeze()) == .durable)
        #expect(ledger.isIdle)
    }

    @Test func settlingAgainStartsNoSecondWrite() async {
        let writer = ScriptedAnswerWriter()
        let ledger = AnswerDurability(writer: writer)
        ledger.register(terminalWrite(conversation: UUID()))
        let snapshot = ledger.freeze()
        #expect(await ledger.settle(snapshot) == .durable)
        #expect(await ledger.settle(snapshot) == .durable)
        #expect(writer.calls.count == 1)
    }
}
