// QuitAttemptTests: one quit attempt, one reply.
//
// AppKit's termination is one pending request: returning `.terminateLater` and
// replying once releases it. This file pins the identity rules the delegate
// depends on, including that the phase is already terminal when the reply runs.
// It does not exercise NSApplication itself; that stays a native check.

import Testing
@testable import QuickLaunch

@Suite("Quit attempts")
@MainActor
struct QuitAttemptTests {

    /// The delegate replies with this, so a stale attempt must refuse.
    @Test func onlyProvenDurabilityAllowsTheExit() {
        #expect(QuitOutcome.durable.allowsExit)
        #expect(!QuitOutcome.unsavedActivity.allowsExit)
        #expect(!QuitOutcome.incompleteDeletion.allowsExit)
        #expect(!QuitOutcome.activityAfterFreeze.allowsExit)
    }

    @Test func aSecondQuitCoalescesIntoTheRunningAttempt() {
        var attempts = QuitAttempts()
        let first = attempts.begin()
        let coalesced = attempts.begin()
        #expect(first != nil)
        #expect(coalesced == nil)
        #expect(attempts.isActive)
        #expect(attempts.current == .waiting(first ?? 0))
    }

    @Test func aStaleResolveDoesNotReply() {
        var attempts = QuitAttempts()
        guard let first = attempts.begin() else {
            Issue.record("no attempt")
            return
        }
        let claimed = attempts.resolve(first + 1, saved: true)
        #expect(claimed == false)
        #expect(attempts.current == .waiting(first), "the live attempt is untouched")
    }

    @Test func aResolveRepliesExactlyOnce() {
        var attempts = QuitAttempts()
        guard let first = attempts.begin() else {
            Issue.record("no attempt")
            return
        }
        let firstReply = attempts.resolve(first, saved: true)
        let secondReply = attempts.resolve(first, saved: true)
        let restarted = attempts.begin()
        #expect(firstReply)
        #expect(secondReply == false)
        #expect(attempts.current == .finished)
        #expect(restarted == nil, "a quit on its way out starts nothing")
        #expect(attempts.isActive)
    }

    @Test func aRefusalReturnsToIdleForTheNextQuit() {
        var attempts = QuitAttempts()
        guard let first = attempts.begin() else {
            Issue.record("no attempt")
            return
        }
        let refused = attempts.resolve(first, saved: false)
        #expect(refused)
        #expect(attempts.current == .idle)
        #expect(!attempts.isActive, "the termination fallback is live again")

        guard let second = attempts.begin() else {
            Issue.record("no second attempt")
            return
        }
        let stale = attempts.resolve(first, saved: true)
        #expect(second != first)
        #expect(stale == false, "a stale result cannot clear it")
        #expect(attempts.current == .waiting(second))
    }

    /// The phase is terminal before the reply runs, so a reentrant quit cannot
    /// see a live attempt or send a second reply.
    @Test func thePhaseMovesBeforeTheReply() {
        var attempts = QuitAttempts()
        guard let first = attempts.begin() else {
            Issue.record("no attempt")
            return
        }
        var seenAtReply: [QuitAttempts.Phase] = []
        var replies = 0
        var reentrantBegins: [Int?] = []
        var reentrantResolves: [Bool] = []
        let reply = { (saved: Bool) -> Bool in
            guard attempts.resolve(first, saved: saved) else { return false }
            replies += 1
            seenAtReply.append(attempts.current)
            // A reentrant quit inside the reply sees a terminal phase.
            reentrantBegins.append(attempts.begin())
            reentrantResolves.append(attempts.resolve(first, saved: saved))
            return true
        }

        let firstReply = reply(true)
        #expect(firstReply)
        #expect(replies == 1)
        #expect(seenAtReply == [.finished])
        #expect(reentrantBegins == [nil])
        #expect(reentrantResolves == [false])
        #expect(attempts.begin() == nil)
    }
}
