import Foundation

/// A text source paired with its attribution label ("Clipboard", or an app
/// name). Pairing them in one value makes an orphaned label without source
/// text impossible.
struct LabeledSource: Equatable, Sendable {
    var text: String
    var label: String?
}

/// All transient state belonging to a single in-flight Quick AI or AI Chat
/// turn. Grouping these into one value type lets every reset, cancel, and
/// completion path clear the entire turn atomically, preventing stale tool
/// lines, orphaned web-search notes, or stuck status indicators.
struct ActiveTurnState: Equatable, Sendable {
    /// The question of the ask in flight before it becomes a saved turn
    /// (during web search / page read, or for a local answer).
    var pendingQuestion: String?
    /// The question a web search or page read took out of the composer, held
    /// until the model call makes it a turn.
    var enrichmentSubmittedInput: String?
    /// "Search web: …" for the ask in flight, moved onto the finished answer's
    /// `toolRecords` when it lands.
    var webSearchNote: String?
    /// Short progress note while streaming ("Searching the web…") until
    /// answer text arrives.
    var streamingStatus: String?
    /// Tool lines of the answer streaming now, in completion order.
    var liveToolRecords: [ChatToolRecord] = []
    /// True while a send waits for attachment chips still reading.
    var isWaitingForAttachments = false
    /// Return while an answer streams queues the typed follow-up for when the
    /// stream ends.
    var isFollowUpQueued = false
    /// A dismissal asked for the surface to clear while a stream was running;
    /// runs once the turn finishes.
    var isTransientClearDeferred = false

    /// Clears all turn-scoped transient state in one step.
    mutating func reset() {
        self = ActiveTurnState()
    }

    /// Clears live progress indicators (status line and tool records),
    /// optionally retaining `webSearchNote`.
    mutating func clearLiveProgress(keepingWebSearchNote: Bool = false) {
        streamingStatus = nil
        liveToolRecords = []
        if !keepingWebSearchNote {
            webSearchNote = nil
        }
    }
}
