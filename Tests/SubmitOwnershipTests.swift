// SubmitOwnershipTests: an accepted submit's pre-stream claim is owned.
//
// `isSubmitBeforeStream` is true while any accepted submit has not reached its
// model request. This file pins the single-claim bug: an older submit finishing
// (or being cancelled) must not clear a newer one that is still waiting before
// its durable question write, and `QuitSession` must refuse an exit while any
// claim remains.
//
// The window is held by the view model's documented test seam
// (`beforeDurableSubmitWrite`), which is nil in the app. No real provider or
// user data is involved. The 30-second fixture bounds prevent hangs; they are
// not app-latency assertions. The old 3-second bounds failed in full-suite runs
// while the focused run passed. App quit deadlines are unchanged.

import Foundation
import Testing
@testable import QuickLaunch

/// Holds accepted submits at the durable-write boundary. `open()` releases the
/// oldest waiting submit, or grants a pass to the next one to arrive.
@MainActor
private final class SubmitSeam {
    private var passes = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0

    func enter() async {
        entered += 1
        if passes > 0 {
            passes -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Bounded on purpose: a submit routed away from `submit` never reaches
    /// the seam, and a cooperative time limit cannot interrupt a continuation
    /// that is never resumed. This returns false instead of hanging the suite.
    func waitForEntry(_ count: Int, within: Duration = .seconds(30)) async -> Bool {
        let deadline = ContinuousClock.now + within
        while entered < count {
            if Task.isCancelled || ContinuousClock.now >= deadline { return false }
            await Task.yield()
        }
        return true
    }

    func open() {
        if waiting.isEmpty {
            passes += 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

@Suite("Submit ownership", .serialized)
@MainActor
struct SubmitOwnershipTests {

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("submit-ownership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The reviewer's case: two submits are accepted and both before their
    /// question write. The older one finishes; the newer one is still pending.
    /// The newer claim must survive, so the quit refuses.
    @Test(.timeLimit(.minutes(2)))
    func anOlderCompletionCannotClearANewerPendingSubmit() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "first answer", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            historyFileURL: directory.appendingPathComponent("chat-history.json"),
            archiveRootURL: directory.appendingPathComponent("archive", isDirectory: true)
        )
        let seam = SubmitSeam()
        vm.beforeDurableSubmitWrite = { await seam.enter() }

        vm.input = "first"
        let first = Task { await vm.submit() }
        #expect(await seam.waitForEntry(1), "the older submit reached the write boundary")

        vm.input = "second"
        let second = Task { await vm.submit() }
        #expect(await seam.waitForEntry(2), "the newer submit reached the write boundary")
        #expect(vm.isSubmitBeforeStream, "both accepted submits are before their write")

        // The older submit runs to a finished answer; its own claim retires.
        seam.open()
        let firstFinished = await withQuitDeadline(.seconds(30)) {
            await first.value
            return true
        }
        #expect(firstFinished == true, "the older send finished after its release")
        #expect(!vm.isStreaming)
        #expect(vm.isSubmitBeforeStream, "the newer pending submit still owns its claim")

        // The quit freezes with one claim left that nothing stopped.
        let session = QuitSession(controller: nil, launcher: vm)
        #expect(await session.finish() == .activityAfterFreeze)
        #expect(vm.isSubmitBeforeStream, "the refusal did not consume the newer submit")

        // Cleanup: let the newer submit finish on its own.
        seam.open()
        let secondFinished = await withQuitDeadline(.seconds(30)) {
            await second.value
            return true
        }
        #expect(secondFinished == true, "the second send finished after its release")
        #expect(!vm.isSubmitBeforeStream)
    }

    /// A cancelled older submit cannot clear a newer pending one either. The
    /// older send goes through the real Tab admission handle, is really
    /// cancelled, and its body unwinds while the newer submit is still held:
    /// the newer claim must survive, so the quit refuses.
    @Test(.timeLimit(.minutes(2)))
    func aCancelledOlderSubmitCannotClearANewerPendingSubmit() async throws {
        let directory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "answer", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            historyFileURL: directory.appendingPathComponent("chat-history.json"),
            archiveRootURL: directory.appendingPathComponent("archive", isDirectory: true)
        )
        let seam = SubmitSeam()
        vm.beforeDurableSubmitWrite = { await seam.enter() }

        // The older send is an ordinary Tab submit: `handleTab` opens Quick AI
        // and sends the typed text without passing through launcher-row
        // classification, so it reaches `submit` on a fresh view model.
        vm.input = "first"
        #expect(vm.handleTab(), "Tab sent the typed text")
        let older = try #require(vm.tabSubmitTask, "the Tab admission handle exists")
        #expect(await seam.waitForEntry(1), "the older submit reached the write boundary")

        // The newer send is accepted while the older one is held.
        vm.input = "second"
        let newer = Task { await vm.submit() }
        #expect(await seam.waitForEntry(2), "the newer submit reached the write boundary")
        #expect(vm.isSubmitBeforeStream, "both accepted sends are before their write")

        // Cancel the older send through the app's own path, which nils the
        // handle before the body unwinds.
        vm.cancel()
        #expect(vm.tabSubmitTask == nil, "cancel dropped the older handle")
        #expect(older.isCancelled, "the older send is really cancelled")

        // Let the older body unwind; only its own claim retires.
        seam.open()
        let olderFinished = await withQuitDeadline(.seconds(30)) {
            await older.value
            return true
        }
        #expect(olderFinished == true, "the cancelled older send unwound after its release")
        #expect(vm.isSubmitBeforeStream, "the newer pending submit still owns its claim")

        let session = QuitSession(controller: nil, launcher: vm)
        #expect(await session.finish() == .activityAfterFreeze)
        #expect(vm.isSubmitBeforeStream, "the refusal did not consume the newer submit")

        // Cleanup: let the newer send finish on its own.
        seam.open()
        let newerFinished = await withQuitDeadline(.seconds(30)) {
            await newer.value
            return true
        }
        #expect(newerFinished == true, "the newer send finished after its release")
        #expect(!vm.isSubmitBeforeStream)
    }
}
