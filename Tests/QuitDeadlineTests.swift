// QuitDeadlineTests: the quit save is bounded and carries its own outcome.
//
// A quit must never report "saved" for work that did not finish, and must never
// hang the app on a busy archive root. `withQuitDeadline` returns the save's
// own value; a deadline returns nil so the caller refuses the quit.

import Foundation
import Testing
@testable import QuickLaunch

@MainActor
private final class QuitSaveGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    func wait() async {
        if isFinished { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        isFinished = true
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Quit deadline", .serialized)
@MainActor
struct QuitDeadlineTests {

    @Test func aSaveThatFinishesIsReportedWithItsOwnOutcome() async {
        let outcome = await withQuitDeadline(.seconds(30)) {
            await Task.yield()
            return QuitOutcome.durable
        }
        #expect(outcome == .durable)
    }

    /// Completing is not the same as saving: the save's own refusal travels.
    @Test func aCompletedSaveThatRefusedIsReported() async {
        let outcome = await withQuitDeadline(.seconds(30)) {
            QuitOutcome.unsavedActivity
        }
        #expect(outcome == .unsavedActivity)
    }

    /// The deadline wins, the result is nil, and the late finish is ignored. A
    /// second resume here would trap the test process.
    @Test func aSavePastTheDeadlineIsReportedUnsaved() async {
        let gate = QuitSaveGate()
        let outcome = await withQuitDeadline(.milliseconds(30)) {
            await gate.wait()
            return QuitOutcome.durable
        }
        #expect(outcome == nil)
        gate.finish()
    }
}
