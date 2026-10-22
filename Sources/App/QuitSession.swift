import Foundation

/// What one quit attempt proved before the app is allowed to exit.
enum QuitOutcome: Equatable {
    /// Every owed write landed and nothing was accepted after the freeze.
    case durable
    /// Chat activity is still not on disk. Includes a missed deadline.
    case unsavedActivity
    /// A chat the user deleted is still on disk, so quitting would keep it.
    case incompleteDeletion
    /// Activity or a chat surface appeared after the freeze. The attempt is
    /// stale: the app stays open and the next quit freezes the new work.
    case activityAfterFreeze
}

extension QuitOutcome {
    /// Only proven durability allows the exit. Every other verdict refuses it,
    /// including the stale attempt.
    var allowsExit: Bool { self == .durable }

    /// One phrase for the log line. Not user copy.
    var logDescription: String {
        switch self {
        case .durable: "the archive writes landed"
        case .unsavedActivity: "chat activity is not saved yet"
        case .incompleteDeletion: "a deleted chat is still on disk"
        case .activityAfterFreeze: "activity was accepted after the freeze"
        }
    }
}

/// The chats one quit owns. Stopping, freezing and reading the activity
/// revision happen in `init`, before the caller's first await, so a deadline
/// that fires later can only finish frozen writes; it never stops, reads or
/// cancels a request started after the refusal.
@MainActor
struct QuitSession {
    private struct Participant {
        let chat: QuickViewModel
        let snapshot: AnswerDurability.Snapshot
        /// A submit was accepted and had not reached its model request when the
        /// freeze ran. This attempt never owned that work (nothing stopped it),
        /// so it cannot vouch for the exit even if it later settled.
        let wasBeforeStream: Bool
    }

    private let participants: [Participant]

    init(controller: AIChatWindowController?, launcher: QuickViewModel?) {
        var participants: [Participant] = []
        if let controller {
            controller.stopForTermination()
            let chat = controller.model.chat
            participants.append(Participant(
                chat: chat,
                snapshot: chat.freezeAnswerDurability(),
                wasBeforeStream: chat.isSubmitBeforeStream
            ))
        }
        if let launcher {
            AIChatWindowController.keepStreamForQuit(launcher)
            participants.append(Participant(
                chat: launcher,
                snapshot: launcher.freezeAnswerDurability(),
                wasBeforeStream: launcher.isSubmitBeforeStream
            ))
        }
        self.participants = participants
    }

    /// Awaits only the frozen writes. The freshness check runs once, after
    /// every participant has settled, so a chat that accepted work during a
    /// slow sibling cannot pass. `isStillCurrent` reports whether the chat
    /// surfaces are the ones this attempt froze.
    func finish(isStillCurrent: () -> Bool = { true }) async -> QuitOutcome {
        var verdicts: [AnswerDurability.Verdict] = []
        for participant in participants {
            verdicts.append(await participant.chat.settleAnswerDurability(participant.snapshot))
        }
        guard isStillCurrent() else { return .activityAfterFreeze }
        // A submit that was already past `noteActivity` but not yet streaming
        // at the freeze was never stopped. Its question write and provider
        // start are unowned by this attempt, so it refuses rather than
        // guessing whether that work finished cleanly.
        if participants.contains(where: \.wasBeforeStream) { return .activityAfterFreeze }
        for participant in participants {
            // A revision move means work was accepted after the freeze. A
            // stream or a pre-stream submit still live at this point is work
            // the frozen attempt never stopped and cannot vouch for.
            let chat = participant.chat
            if chat.answerDurabilityRevision != participant.snapshot.revision
                || chat.isStreaming
                || chat.isSubmitBeforeStream {
                return .activityAfterFreeze
            }
        }
        if verdicts.contains(.incompleteDeletion) { return .incompleteDeletion }
        if verdicts.contains(.unsavedActivity) { return .unsavedActivity }
        return .durable
    }
}
