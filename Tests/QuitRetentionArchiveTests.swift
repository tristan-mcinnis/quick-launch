// QuitRetentionArchiveTests: the canonical chat archive at the quit boundary.
//
// Prepared 2026-10-22 against quick-launch 27bd421. It was red before the
// shutdown-durability fix (see red-phase2-20261022.log): the final tail stayed
// at the 800-character checkpoint and the status stayed `.streaming`, because
// the quit path's archive writes were fire-and-forget and the process could
// exit first.
//
// The boundary is: stop and freeze every chat (`QuitSession`), await the frozen
// debt (`AnswerDurability.settle`), then judge. A write that did not land, a
// delete that did not finish, or activity accepted after the freeze refuses the
// quit; the debt is kept and the next quit retries it. Quit is not Stop and not
// hide: Stop is `cancel()` on a live surface, and hide and window close let the
// answer finish (AIChatWindowLifecycleTests).

import Darwin
import Foundation
import HouseChatCore
import Observation
import Synchronization
import Testing
@testable import QuickLaunch

/// A stream that sends its whole answer in two deltas, then holds the stream
/// open the way a provider does while it thinks. Later calls answer `followUp`
/// at once, or hold too when `holdsEveryCall` is set.
private final class HeldTailQuickService: QuickService {
    let head: String
    let tail: String
    let followUp: String
    let holdsEveryCall: Bool

    private struct State {
        var calls = 0
        var gate: CheckedContinuation<Void, Never>?
        var isTerminated = false
    }

    private let state = Mutex(State())

    init(head: String, tail: String, followUp: String = "", holdsEveryCall: Bool = false) {
        self.head = head
        self.tail = tail
        self.followUp = followUp
        self.holdsEveryCall = holdsEveryCall
    }

    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: messages, images: [])
    }

    func send(
        messages: [QuickMessage],
        images: [QuickImageAttachment]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        let call = state.withLock { state in
            state.calls += 1
            return state.calls
        }
        return AsyncThrowingStream { continuation in
            guard call == 1 || holdsEveryCall else {
                continuation.finish()
                return
            }
            let producer = Task { [head, tail, followUp] in
                if call == 1 {
                    continuation.yield(StreamDelta(text: head, finishReason: nil))
                    continuation.yield(StreamDelta(text: tail, finishReason: nil))
                } else {
                    continuation.yield(StreamDelta(text: followUp, finishReason: nil))
                }
                await self.hold()
                continuation.yield(StreamDelta(text: "", finishReason: "stop"))
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                self?.release()
                producer.cancel()
            }
        }
    }

    func healthCheck() async throws -> Bool { true }

    private func hold() async {
        await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
            let terminated = state.withLock { state -> Bool in
                if state.isTerminated { return true }
                state.gate = gate
                return false
            }
            if terminated { gate.resume() }
        }
    }

    private func release() {
        let gate = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.isTerminated = true
            let gate = state.gate
            state.gate = nil
            return gate
        }
        gate?.resume()
    }
}

/// A stream that sends its answer at once and ends normally only when the test
/// releases it. This is the normal-completion window: the answer is on screen,
/// the stream is finishing, and the archive write has not landed yet.
private final class GatedFinishQuickService: QuickService {
    let head: String
    let tail: String

    private struct State {
        var gate: CheckedContinuation<Void, Never>?
        var isReleased = false
    }

    private let state = Mutex(State())

    init(head: String, tail: String) {
        self.head = head
        self.tail = tail
    }

    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        send(messages: messages, images: [])
    }

    func send(
        messages: [QuickMessage],
        images: [QuickImageAttachment]
    ) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(StreamDelta(text: head, finishReason: nil))
            continuation.yield(StreamDelta(text: tail, finishReason: nil))
            let producer = Task {
                await self.waitForRelease()
                continuation.yield(StreamDelta(text: "", finishReason: "stop"))
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                self?.release()
                producer.cancel()
            }
        }
    }

    func healthCheck() async throws -> Bool { true }

    func release() {
        let gate = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.isReleased = true
            let gate = state.gate
            state.gate = nil
            return gate
        }
        gate?.resume()
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
            let released = state.withLock { state -> Bool in
                if state.isReleased { return true }
                state.gate = gate
                return false
            }
            if released { gate.resume() }
        }
    }
}

/// Waits on the app's own output changes, not a timer.
@MainActor
private func waitForOutput(_ vm: QuickViewModel, _ expected: String) async {
    for await value in Observations({ vm.output }) {
        if value == expected { return }
    }
}

@Suite("Quit archive durability", .serialized)
@MainActor
struct QuitRetentionArchiveTests {

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quit-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeViewModel(
        service: any QuickService,
        root: URL,
        store: QuickStore? = nil
    ) -> (QuickViewModel, URL) {
        let historyFile = root.appendingPathComponent("chat-history.json")
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let vm = QuickViewModel(
            settings: settings,
            store: store,
            service: service,
            historyFileURL: historyFile,
            archiveRootURL: root.appendingPathComponent("archive", isDirectory: true)
        )
        return (vm, historyFile)
    }

    /// The archive as a different process would read it, with no `await`.
    /// Called immediately after the quit flush: if the flush did not really
    /// wait, this read sees the checkpoint, not the final answer. `chats/` is
    /// the layout `ChatArchive.init` creates; the envelope is the public
    /// HouseChatCore record.
    private func archivedConversation(in root: URL) throws -> ConversationRecord {
        let chats = root.appendingPathComponent("archive/chats", isDirectory: true)
        let files = try FileManager.default
            .contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        try #require(files.count == 1, "one conversation file")
        let data = try Data(contentsOf: files[0])
        return try HouseChatCoding.makeDecoder()
            .decode(ConversationEnvelope.self, from: data)
            .conversation
    }

    private func setWritable(_ url: URL, _ writable: Bool) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o700 : 0o500],
            ofItemAtPath: url.path
        )
    }

    private func chatsDirectory(_ root: URL) -> URL {
        root.appendingPathComponent("archive/chats", isDirectory: true)
    }

    /// The quit boundary as `AppDelegate` runs it.
    private func quit(_ vm: QuickViewModel) async -> QuitOutcome {
        await QuitSession(controller: nil, launcher: vm).finish()
    }

    // MARK: - Stop at quit

    @Test(.timeLimit(.minutes(1)))
    func quittingMidAnswerKeepsTheFinalTailAndTerminalStatusInTheArchive() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 800 characters is exactly one checkpoint. The 200 after it are the
        // tail the quit path used to lose.
        let head = String(repeating: "a", count: 800)
        let tail = String(repeating: "b", count: 200)
        let expected = head + tail
        let service = HeldTailQuickService(head: head, tail: tail)
        let (vm, historyFile) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, expected)

        let conversationID = try #require(vm.currentConversation?.id.uuidString)
        let archive = try #require(vm.chatArchive)
        // The checkpoint gate: this awaits the checkpoint the stream already
        // scheduled, so the tail gap is measured against a real record.
        _ = await vm.flushArchiveForQuit()
        let checkpointed = try await archive.load(id: conversationID)
        #expect(checkpointed.turns.first { $0.role == .assistant }?.text == head)

        // Repeated, because a second Quit must not hang on completed work.
        #expect(await quit(vm) == .durable)
        #expect(await quit(vm) == .durable)

        // What the user saw and what the quit kept in memory; cancel flushed
        // the buffered tail.
        #expect(vm.conversationMessages.last?.content == expected)
        #expect(!vm.isStreaming)

        // No `await` from here to the read: the flush is the barrier, so this
        // is the disk state a real exit would leave. Without the flush this
        // read is the 800-character checkpoint with `.streaming`.
        let record = try archivedConversation(in: directory)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.text == expected, "the final tail must survive the quit")
        #expect(answer.request?.status == .cancelled, "a quit is terminal, not still streaming")
        #expect(record.turns.map(\.role) == [.user, .assistant], "one question, then its answer")

        // The legacy cache received the whole answer too. It is rollback
        // data, not the canonical read path: the archive record wins.
        let cached = QuickHistoryStore.load(from: historyFile, migratingFrom: nil)
        #expect(cached.first?.messages.last?.content == expected)

        await submit.value
    }

    /// The checkpoint is still in flight when the quit starts. The terminal
    /// write is fenced behind it, so a late checkpoint cannot put the stale
    /// text or the streaming status back.
    @Test(.timeLimit(.minutes(1)))
    func quittingWithACheckpointStillInFlightKeepsTheFinalAnswer() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let head = String(repeating: "a", count: 800)
        let tail = String(repeating: "b", count: 200)
        let expected = head + tail
        let service = HeldTailQuickService(head: head, tail: tail)
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, expected)

        // No wait for the checkpoint: it is pending, or already done.
        #expect(await quit(vm) == .durable)

        let conversationID = try #require(vm.currentConversation?.id.uuidString)
        let archive = try #require(vm.chatArchive)
        let record = try await archive.load(id: conversationID)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.text == expected)
        #expect(answer.request?.status == .cancelled)
        #expect(record.turns.map(\.role) == [.user, .assistant])

        await submit.value
    }

    /// Shorter than one checkpoint: the archive had no assistant turn until
    /// the stop write. The quit still keeps the answer and marks it terminal.
    @Test(.timeLimit(.minutes(1)))
    func quittingBelowTheCheckpointKeepsTheShortAnswerAndTerminalStatus() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let answer = "Lima is the capital"
        let service = HeldTailQuickService(head: answer, tail: "")
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, answer)

        let conversationID = try #require(vm.currentConversation?.id.uuidString)
        let archive = try #require(vm.chatArchive)
        let before = try await archive.load(id: conversationID)
        #expect(!before.turns.contains { $0.role == .assistant }, "no checkpoint below 800 characters")

        #expect(await quit(vm) == .durable)

        // No `await` after the flush: without it, the answer turn is absent.
        let record = try archivedConversation(in: directory)
        let saved = try #require(record.turns.first { $0.role == .assistant })
        #expect(saved.text == answer)
        #expect(saved.request?.status == .cancelled)
        #expect(record.turns.map(\.role) == [.user, .assistant])

        await submit.value
    }

    /// Nothing was streaming: the flush returns saved and invents no record.
    @Test func quittingWithNoStreamWritesNoArchive() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (vm, historyFile) = makeViewModel(service: MockQuickService(), root: directory)

        #expect(await quit(vm) == .durable)

        let archive = try #require(vm.chatArchive)
        #expect(try await archive.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: historyFile.path))
    }

    /// A refused write reports the debt and refuses the quit. After the cause
    /// is fixed, the next quit retries the frozen turn and lands it. The
    /// legacy cache is rollback data, never the recovery path.
    @Test(.timeLimit(.minutes(1)))
    func aFailedArchiveWriteRefusesAndARetryLandsAfterRecovery() async throws {
        try #require(geteuid() != 0, "permissions test needs a normal user")
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let answer = "Lima is the capital"
        let service = HeldTailQuickService(head: answer, tail: "")
        let (vm, historyFile) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, answer)

        let conversationID = try #require(vm.currentConversation?.id.uuidString)
        let archive = try #require(vm.chatArchive)
        let chats = chatsDirectory(directory)
        try setWritable(chats, false)
        defer { try? setWritable(chats, true) }

        #expect(await quit(vm) == .unsavedActivity, "a failed write refuses the quit")
        let refused = try await archive.load(id: conversationID)
        #expect(!refused.turns.contains { $0.role == .assistant })

        // The cause is fixed. The app is still open, so the next quit retries
        // the frozen terminal write and its projection.
        try setWritable(chats, true)
        #expect(await quit(vm) == .durable, "the retry lands after recovery")

        let record = try await archive.load(id: conversationID)
        let saved = try #require(record.turns.first { $0.role == .assistant })
        #expect(saved.text == answer)
        #expect(saved.request?.status == .cancelled)

        // Rollback data only.
        let cached = QuickHistoryStore.load(from: historyFile, migratingFrom: nil)
        #expect(cached.first?.messages.last?.content == answer)

        await submit.value
    }

    // MARK: - A naturally completed answer

    /// Defect 1: `isStreaming` is false while the completion write is still
    /// owed. A quit here must see the debt, not a quiet chat.
    @Test(.timeLimit(.minutes(1)))
    func aCompletedAnswerInFlightIsFrozenAndItsFailureRefusesTheQuit() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let head = "Lima is the capital"
        let tail = " of Peru."
        let expected = head + tail
        let service = GatedFinishQuickService(head: head, tail: tail)
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, expected)

        // The answer is live and the stream has not ended. Make the archive
        // unwritable, then let the stream finish: the completion write fails,
        // and that failure is the only thing that can refuse this quit.
        let chats = chatsDirectory(directory)
        try setWritable(chats, false)
        defer { try? setWritable(chats, true) }
        service.release()
        await submit.value
        #expect(!vm.isStreaming, "the answer finished before the quit")

        #expect(await quit(vm) == .unsavedActivity, "a completed answer is still owed")

        try setWritable(chats, true)
        #expect(await quit(vm) == .durable)

        let record = try archivedConversation(in: directory)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.text == expected)
        #expect(answer.request?.status == .completed, "a naturally finished answer is completed")
    }

    @Test(.timeLimit(.minutes(1)))
    func aCompletedAnswerIsDurableAtQuit() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = GatedFinishQuickService(head: "Lima is", tail: " the capital")
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, "Lima is the capital")
        service.release()
        await submit.value

        #expect(await quit(vm) == .durable)

        // Synchronous read: the settle is the barrier.
        let record = try archivedConversation(in: directory)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.text == "Lima is the capital")
        #expect(answer.request?.status == .completed)
    }

    // MARK: - Deletion

    /// A chat deleted after its stop write failed is retired only by the
    /// tombstone the archive wrote, not by the in-memory set.
    @Test(.timeLimit(.minutes(1)))
    func aDeletedChatRetiresItsFailedStopWrite() async throws {
        try #require(geteuid() != 0, "permissions test needs a normal user")
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = HeldTailQuickService(head: "Lima is the capital", tail: "")
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, "Lima is the capital")

        let conversationID = try #require(vm.currentConversation?.id)
        let chats = chatsDirectory(directory)
        try setWritable(chats, false)
        #expect(await quit(vm) == .unsavedActivity)
        try setWritable(chats, true)

        // The delete lands: the tombstone is on disk and the record is gone.
        vm.deleteConversation(id: conversationID)
        let archive = try #require(vm.chatArchive)

        #expect(await quit(vm) == .durable, "a durably deleted chat owes nothing")
        #expect(archive.deletions.contains(conversationID.uuidString), "the tombstone is the evidence")
        #expect(await quit(vm) == .durable)
        #expect(try await archive.loadAll().isEmpty)

        await submit.value
    }

    /// The record removal fails after the tombstone was written. The archive
    /// unmarks the tombstone, so the chat still exists and the delete is still
    /// owed: the quit must refuse, then land after recovery.
    @Test(.timeLimit(.minutes(1)))
    func aDeletionThatFailsAfterTheTombstoneKeepsItsDebt() async throws {
        try #require(geteuid() != 0, "permissions test needs a normal user")
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = GatedFinishQuickService(head: "Lima is the capital", tail: "")
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, "Lima is the capital")
        service.release()
        await submit.value

        let conversationID = try #require(vm.currentConversation?.id)
        let archive = try #require(vm.chatArchive)
        let chats = chatsDirectory(directory)
        try setWritable(chats, false)
        defer { try? setWritable(chats, true) }

        vm.deleteConversation(id: conversationID)
        // The marker was written and then removed by the failed delete.
        #expect(!archive.deletions.contains(conversationID.uuidString))
        #expect(try await archive.loadAll().count == 1, "the record is still there")

        #expect(await quit(vm) == .incompleteDeletion)

        try setWritable(chats, true)
        #expect(await quit(vm) == .durable)
        #expect(archive.deletions.contains(conversationID.uuidString))
        #expect(try await archive.loadAll().isEmpty)
    }

    /// The delete cannot even mark its tombstone: the chat is still there, so
    /// the quit refuses and retries.
    @Test(.timeLimit(.minutes(1)))
    func aDeletionThatCannotMarkRefusesTheQuit() async throws {
        try #require(geteuid() != 0, "permissions test needs a normal user")
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = GatedFinishQuickService(head: "Lima is the capital", tail: "")
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, "Lima is the capital")
        service.release()
        await submit.value

        let conversationID = try #require(vm.currentConversation?.id)
        let archive = try #require(vm.chatArchive)
        let deletions = directory.appendingPathComponent("archive/deletions", isDirectory: true)
        try FileManager.default.createDirectory(at: deletions, withIntermediateDirectories: true)
        try setWritable(deletions, false)
        defer { try? setWritable(deletions, true) }

        vm.deleteConversation(id: conversationID)
        #expect(await quit(vm) == .incompleteDeletion)

        try setWritable(deletions, true)
        #expect(await quit(vm) == .durable)
        #expect(try await archive.loadAll().isEmpty)
    }

    /// The chat is deleted from the other view model, which owns the same store
    /// and archive. The tombstone retires this view model's debt too.
    @Test(.timeLimit(.minutes(1)))
    func aDeleteFromTheOtherViewRetiresThisChatsDebt() async throws {
        try #require(geteuid() != 0, "permissions test needs a normal user")
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = HeldTailQuickService(head: "Lima is the capital", tail: "")
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, "Lima is the capital")

        let conversationID = try #require(vm.currentConversation?.id)
        let chats = chatsDirectory(directory)
        try setWritable(chats, false)
        #expect(await quit(vm) == .unsavedActivity)
        try setWritable(chats, true)

        // The other window's view model, sharing the store and the root.
        let historyFile = directory.appendingPathComponent("chat-history.json")
        let other = QuickViewModel(
            settings: vm.settings,
            store: vm.store,
            service: MockQuickService(),
            historyFileURL: historyFile,
            archiveRootURL: directory.appendingPathComponent("archive", isDirectory: true)
        )
        other.deleteConversation(id: conversationID)
        #expect(await QuitSession(controller: nil, launcher: other).finish() == .durable)

        #expect(await quit(vm) == .durable, "the tombstone retired the failed write")
        #expect(try await vm.chatArchive?.loadAll().isEmpty == true)

        await submit.value
    }

    // MARK: - Freshness

    /// Activity accepted after the freeze makes the attempt stale: the quit is
    /// refused, and the new request is neither stopped nor consumed.
    @Test(.timeLimit(.minutes(1)))
    func activityAfterTheFreezeRefusesTheQuitAndLeavesTheNewRequestAlone() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = HeldTailQuickService(
            head: "first answer",
            tail: "",
            followUp: "second answer",
            holdsEveryCall: true
        )
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "first"
        let first = Task { await vm.submit() }
        await waitForOutput(vm, "first answer")

        // The quit's synchronous stop-and-freeze phase.
        let session = QuitSession(controller: nil, launcher: vm)
        #expect(!vm.isStreaming, "the session stops the chat before any await")

        // A new request is accepted while the attempt is still open.
        vm.input = "second"
        let second = Task { await vm.submit() }
        await waitForOutput(vm, "second answer")

        #expect(await session.finish() == .activityAfterFreeze)
        #expect(vm.isStreaming, "the new request was not stopped or consumed")
        #expect(vm.output == "second answer")

        // The next quit freezes the new work properly.
        #expect(await quit(vm) == .durable)
        #expect(vm.conversationMessages.last?.content == "second answer")

        await first.value
        await second.value
    }

    /// The session's freshness check runs after every participant settles: a
    /// chat surface that is no longer the one the attempt froze refuses it.
    @Test(.timeLimit(.minutes(1)))
    func aChatSurfaceAppearingAfterTheFreezeRefusesTheQuit() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = HeldTailQuickService(head: "first answer", tail: "")
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "first"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, "first answer")

        let session = QuitSession(controller: nil, launcher: vm)
        #expect(await session.finish(isStillCurrent: { false }) == .activityAfterFreeze)
        #expect(await session.finish(isStillCurrent: { true }) == .durable)

        await submit.value
    }

    /// A frozen settle only finishes frozen work: a request started after a
    /// refusal keeps streaming, and its answer is saved by its own writes.
    @Test(.timeLimit(.minutes(1)))
    func aLateFrozenSettleDoesNotTouchARequestStartedAfterIt() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = HeldTailQuickService(
            head: "first answer",
            tail: "",
            followUp: "second answer",
            holdsEveryCall: true
        )
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "first"
        let first = Task { await vm.submit() }
        await waitForOutput(vm, "first answer")

        let frozen = vm.freezeAnswerDurability()
        AIChatWindowController.keepStreamForQuit(vm)

        vm.input = "second"
        let second = Task { await vm.submit() }
        await waitForOutput(vm, "second answer")
        #expect(vm.isStreaming)

        // Finishing the frozen work now must not stop or read the new request.
        #expect(await vm.settleAnswerDurability(frozen) == .durable)
        #expect(vm.isStreaming)
        #expect(vm.output == "second answer")

        vm.cancel()
        await first.value
        await second.value
    }

    // MARK: - Projection debt and stale replay

    /// The reviewer's regression: a failed projection carries data only it
    /// has (the assistant turn's UI tool records). A terminal write for the
    /// same turn does not carry them. The debt must stay owed, the quit must
    /// refuse, and the replay must add them without touching the terminal
    /// answer.
    @Test(.timeLimit(.minutes(1)))
    func aFailedProjectionWithUniqueToolRecordsStaysOwedUntilItLands() async throws {
        try #require(geteuid() != 0, "permissions test needs a normal user")
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("archive", isDirectory: true)
        let archive = try ChatArchive(root: root)
        let chats = root.appendingPathComponent("chats", isDirectory: true)

        let conversationID = UUID()
        let assistantID = UUID()
        let full = "Lima is the capital of Peru."
        let records = [ChatToolRecord(kind: .web, summary: "Search web: Lima is the capital")]

        var bare = QuickConversation(id: conversationID, providerID: UUID(), model: "test-model")
        bare.messages = [
            QuickMessage(id: UUID(), role: .user, content: "tell me about Lima"),
            QuickMessage(id: assistantID, role: .assistant, content: full),
        ]
        try await archive.syncConversation(bare)

        let ledger = AnswerDurability(writer: ChatArchiveAnswerWriter(archive: archive))
        var withRecords = bare
        withRecords.messages[1].toolRecords = records

        try setWritable(chats, false)
        ledger.record(withRecords)
        #expect(await ledger.settle(ledger.freeze()) == .unsavedActivity, "the projection is owed")

        // The terminal write lands while the projection is still owed.
        try setWritable(chats, true)
        let terminal = ledger.register(
            AnswerTerminalWrite(
                conversationID: conversationID,
                turnID: assistantID,
                status: .completed,
                error: nil,
                text: full,
                receipt: RequestReceipt(status: .completed),
                selection: nil,
                timings: RequestTimings(totalSeconds: 1),
                usage: TokenUsage(inputTokens: 4, outputTokens: 6),
                toolRounds: nil,
                rounds: nil,
                checkpointFence: nil
            )
        )
        _ = await terminal?.value

        #expect(ledger.pendingCount == 1, "the projection is still owed after the terminal write")
        let before = try await archive.load(id: conversationID.uuidString)
        let pendingAnswer = try #require(before.turns.first { $0.role == .assistant })
        #expect(pendingAnswer.text == full)
        #expect(pendingAnswer.appPayload?["toolRecords"] == nil, "not applied yet")

        #expect(await ledger.settle(ledger.freeze()) == .durable)

        let after = try await archive.load(id: conversationID.uuidString)
        let answer = try #require(after.turns.first { $0.role == .assistant })
        #expect(answer.text == full, "the terminal answer is intact")
        #expect(answer.request?.status == .completed)
        #expect(answer.request?.usage?.outputTokens == 6, "the terminal receipt is intact")
        #expect(answer.appPayload?["toolRecords"] != nil, "the projection's own data landed")
    }

    /// A replay is additive. An older snapshot must not rewrite a newer answer
    /// (different or equal length), title, pin, or tool records, but its unique
    /// turn data must not be discarded either.
    @Test(.timeLimit(.minutes(1)))
    func aReplayAddsOnlyAndNeverErasesANewerField() async throws {
        try #require(geteuid() != 0, "permissions test needs a normal user")
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("archive", isDirectory: true)
        let archive = try ChatArchive(root: root)
        let chats = root.appendingPathComponent("chats", isDirectory: true)

        let conversationID = UUID()
        let assistantID = UUID()
        let newerText = "Lima is the capital, and Callao is its port."
        let olderText = "Lima is the capital, and Cusco is its port."
        let extraTurn = QuickMessage(id: UUID(), role: .user, content: "one more thing")
        let olderRecords = [ChatToolRecord(kind: .memory, summary: "Recall: Lima notes")]

        var stored = QuickConversation(
            id: conversationID,
            providerID: UUID(),
            model: "test-model",
            customTitle: "Newer title",
            isPinned: true
        )
        stored.messages = [
            QuickMessage(id: UUID(), role: .user, content: "tell me about Lima"),
            QuickMessage(id: assistantID, role: .assistant, content: newerText),
        ]
        try await archive.syncConversation(stored)

        let ledger = AnswerDurability(writer: ChatArchiveAnswerWriter(archive: archive))

        // The older snapshot: equal-length divergent answer, an older title, an
        // unpinned chat, its own tool records, and one turn the newer state
        // never had.
        var older = stored
        older.customTitle = "Older title"
        older.isPinned = false
        older.messages[1].content = olderText
        older.messages[1].toolRecords = olderRecords
        older.messages.append(extraTurn)

        try setWritable(chats, false)
        ledger.record(older)
        #expect(await ledger.settle(ledger.freeze()) == .unsavedActivity)
        try setWritable(chats, true)

        // A newer snapshot lands, without the older tool records or the extra
        // turn. It is the current state, so it applies normally.
        var newer = stored
        newer.updatedAt = older.updatedAt.addingTimeInterval(1)
        ledger.record(newer)
        #expect(ledger.pendingCount == 2, "the older snapshot is still owed")

        #expect(await ledger.settle(ledger.freeze()) == .durable)

        let record = try await archive.load(id: conversationID.uuidString)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.text == newerText, "an older divergent answer never wins")
        #expect(record.appPayload?["customTitle"] == .string("Newer title"), "the newer title survives")
        #expect(record.appPayload?["isPinned"] == .bool(true), "the newer pin survives")
        #expect(answer.appPayload?["toolRecords"] != nil, "the older snapshot's unique records landed")
        #expect(record.turns.contains { $0.id == extraTurn.id.uuidString }, "its unique turn is not discarded")
    }

    /// A quit whose freeze lands inside a pre-stream submit (here: a held
    /// attachment read) must not approve the exit once that submit reaches the
    /// durable question and the provider start.
    @Test(.timeLimit(.minutes(1)))
    func aFreezeInsideAPreStreamSubmitRefusesTheQuit() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let extractor = FakeAttachmentExtractor()
        await extractor.hold("slow.txt")
        let historyFile = directory.appendingPathComponent("chat-history.json")
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let vm = QuickViewModel(
            settings: settings,
            service: MockQuickService(),
            historyFileURL: historyFile,
            archiveRootURL: directory.appendingPathComponent("archive", isDirectory: true),
            attachmentExtractor: extractor
        )
        vm.input = "tell me about Lima"
        vm.attachmentTray.add(.file(AttachmentFlowTests.file("slow.txt")))
        let submit = Task { await vm.submit() }
        // Wait for the held read: a signal from the reader, not a timer.
        while await !extractor.requested.contains("slow.txt") {
            await Task.yield()
        }

        let session = QuitSession(controller: nil, launcher: vm)
        #expect(!vm.isStreaming, "the question has not reached the model yet")

        await extractor.release("slow.txt")
        await submit.value
        #expect(!vm.isStreaming)

        #expect(await session.finish() == .activityAfterFreeze, "the frozen attempt is stale")
        #expect(await quit(vm) == .durable, "the next quit settles the finished turn")
    }

    /// A replay never rewrites text, whatever its length or content.
    @Test(.timeLimit(.minutes(1)))
    func aReplayNeverReplacesTextWhateverItsLength() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("archive", isDirectory: true)
        let archive = try ChatArchive(root: root)
        let conversationID = UUID()
        let assistantID = UUID()
        let storedText = "Stored answer text."

        var conversation = QuickConversation(id: conversationID, providerID: UUID(), model: "test-model")
        conversation.messages = [
            QuickMessage(id: UUID(), role: .user, content: "question"),
            QuickMessage(id: assistantID, role: .assistant, content: storedText),
        ]
        try await archive.syncConversation(conversation)

        var equalLength = conversation
        equalLength.messages[1].content = "Equal length text!!"
        try await archive.applyProjection(equalLength, replay: true)
        var longer = conversation
        longer.messages[1].content = "A longer, different, older answer text."
        try await archive.applyProjection(longer, replay: true)
        var shorter = conversation
        shorter.messages[1].content = "Stored answer"
        try await archive.applyProjection(shorter, replay: true)

        let record = try await archive.load(id: conversationID.uuidString)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.text == storedText, "a replay never rewrites text")
    }

    /// A stale normal projection (the other window) cannot shrink a terminal
    /// turn's tool lines either.
    @Test(.timeLimit(.minutes(1)))
    func aShorterToolRecordListDoesNotReplaceATerminalTurnsRecords() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("archive", isDirectory: true)
        let archive = try ChatArchive(root: root)
        let conversationID = UUID()
        let assistantID = UUID()
        let text = "Lima is the capital."

        var conversation = QuickConversation(id: conversationID, providerID: UUID(), model: "test-model")
        conversation.messages = [
            QuickMessage(id: UUID(), role: .user, content: "question"),
            QuickMessage(
                id: assistantID,
                role: .assistant,
                content: text,
                toolRecords: [
                    ChatToolRecord(kind: .web, summary: "Search web: Lima"),
                    ChatToolRecord(kind: .memory, summary: "Recall: Lima"),
                ]
            ),
        ]
        try await archive.syncConversation(conversation)
        _ = try await archive.failTurn(
            conversationID: conversationID.uuidString,
            turnID: assistantID.uuidString,
            error: "Stopped by the user",
            status: .cancelled,
            text: text
        )

        var stale = conversation
        stale.messages[1].toolRecords = [ChatToolRecord(kind: .web, summary: "Search web: Lima")]
        try await archive.syncConversation(stale)

        let record = try await archive.load(id: conversationID.uuidString)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        guard case .array(let records)? = answer.appPayload?["toolRecords"] else {
            Issue.record("no tool records")
            return
        }
        #expect(records.count == 2, "an older shorter list does not shrink the record")
    }

    // MARK: - Stale projections

    /// A stale snapshot registered after the terminal write must not shorten
    /// the durable answer or drop its receipt.
    @Test(.timeLimit(.minutes(1)))
    func aStaleProjectionDoesNotRegressATerminalAnswer() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("archive", isDirectory: true)
        let archive = try ChatArchive(root: root)

        let conversationID = UUID()
        let assistantID = UUID()
        let full = String(repeating: "a", count: 1000)

        var conversation = QuickConversation(
            id: conversationID,
            providerID: UUID(),
            model: "test-model"
        )
        conversation.messages = [
            QuickMessage(id: UUID(), role: .user, content: "tell me about Lima"),
            QuickMessage(id: assistantID, role: .assistant, content: full),
        ]
        try await archive.syncConversation(conversation)
        _ = try await archive.failTurn(
            conversationID: conversationID.uuidString,
            turnID: assistantID.uuidString,
            error: "Stopped by the user",
            status: .cancelled,
            text: full,
            timings: RequestTimings(totalSeconds: 1),
            usage: TokenUsage(inputTokens: 3, outputTokens: 5)
        )

        // An older copy of the same turn, registered late.
        var stale = conversation
        stale.messages[1].content = String(full.prefix(800))
        try await archive.syncConversation(stale)

        let record = try await archive.load(id: conversationID.uuidString)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.text == full, "a shorter stale copy never replaces the answer")
        #expect(answer.request?.status == .cancelled)
        #expect(answer.request?.usage?.outputTokens == 5, "the receipt survives")
        #expect(answer.request?.timings.totalSeconds == 1)
        #expect(record.turns.map(\.role) == [.user, .assistant], "no turn is added or dropped")
    }

    /// An intentional rewrite that is not a prefix (a regenerated answer text)
    /// still lands: the guard is for stale copies, not for edits.
    @Test(.timeLimit(.minutes(1)))
    func aDifferentAnswerTextStillLands() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("archive", isDirectory: true)
        let archive = try ChatArchive(root: root)

        let conversationID = UUID()
        let assistantID = UUID()
        var conversation = QuickConversation(id: conversationID, providerID: UUID(), model: "test-model")
        conversation.messages = [
            QuickMessage(id: UUID(), role: .user, content: "tell me about Lima"),
            QuickMessage(id: assistantID, role: .assistant, content: "Lima is the capital."),
        ]
        try await archive.syncConversation(conversation)
        _ = try await archive.failTurn(
            conversationID: conversationID.uuidString,
            turnID: assistantID.uuidString,
            error: "Stopped by the user",
            status: .cancelled,
            text: "Lima is the capital."
        )

        var rewritten = conversation
        rewritten.messages[1].content = "Actually, Callao is the port."
        try await archive.syncConversation(rewritten)

        let record = try await archive.load(id: conversationID.uuidString)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.text == "Actually, Callao is the port.")
    }

    /// A failed older projection is retired once a later write for the same
    /// chat lands, so it can never be retried over newer data.
    @Test(.timeLimit(.minutes(1)))
    func aFailedOlderProjectionIsRetiredByALaterLandedWrite() async throws {
        try #require(geteuid() != 0, "permissions test needs a normal user")
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = GatedFinishQuickService(head: "Lima is the capital", tail: "")
        let (vm, _) = makeViewModel(service: service, root: directory)

        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await waitForOutput(vm, "Lima is the capital")
        service.release()
        await submit.value
        #expect(await quit(vm) == .durable)

        let conversationID = try #require(vm.currentConversation?.id)
        let archive = try #require(vm.chatArchive)
        let chats = chatsDirectory(directory)

        // An older snapshot fails while the disk is unwritable.
        var stale = try #require(vm.currentConversation)
        stale.messages[stale.messages.count - 1].content = "Lima is"
        try setWritable(chats, false)
        vm.syncConversationToArchive(stale)
        #expect(await quit(vm) == .unsavedActivity)
        try setWritable(chats, true)

        // A newer snapshot for the same chat lands, retiring the older debt.
        vm.syncConversationToArchive(try #require(vm.currentConversation))
        #expect(await quit(vm) == .durable)

        let record = try await archive.load(id: conversationID.uuidString)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.text == "Lima is the capital", "no stale retry overwrote the answer")
        #expect(answer.request?.status == .completed)
    }

    // MARK: - Receipt rounds

    /// The receipt carries the turn's real round count, filled inside the
    /// write from the turn's own recorder.
    @Test func theTerminalWriteCarriesTheExactRoundCount() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("archive", isDirectory: true)
        let archive = try ChatArchive(root: root)

        let conversationID = UUID()
        let assistantID = UUID()
        var conversation = QuickConversation(id: conversationID, providerID: UUID(), model: "test-model")
        conversation.messages = [
            QuickMessage(id: UUID(), role: .user, content: "tell me about Lima"),
            QuickMessage(id: assistantID, role: .assistant, content: "Lima is the capital."),
        ]
        try await archive.syncConversation(conversation)

        let recorder = ChatRoundRecorder(archive: archive)
        await recorder.attach(conversationID: conversationID.uuidString, turnID: assistantID.uuidString)
        // Two model requests, no tool round bodies to file.
        try await recorder.beforeRequest(ProviderRequestRound(round: 0, body: Data("{}".utf8), kind: "requestSansKey"))
        try await recorder.beforeRequest(ProviderRequestRound(round: 0, body: Data("{}".utf8), kind: "requestSansKey"))

        let writer = ChatArchiveAnswerWriter(archive: archive)
        try await writer.writeTerminal(
            AnswerTerminalWrite(
                conversationID: conversationID,
                turnID: assistantID,
                status: .completed,
                error: nil,
                text: "Lima is the capital.",
                receipt: RequestReceipt(status: .completed),
                selection: nil,
                timings: RequestTimings(totalSeconds: 2),
                usage: nil,
                toolRounds: nil,
                rounds: recorder,
                checkpointFence: nil
            )
        )

        let record = try await archive.load(id: conversationID.uuidString)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.request?.timings.extra["modelRounds"] == .number(2))
        #expect(answer.timings.extra["modelRounds"] == nil, "the turn timing is untouched")
        #expect(answer.request?.status == .completed)
    }
}
