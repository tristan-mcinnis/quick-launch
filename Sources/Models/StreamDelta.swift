import Foundation
import HouseChatCore

struct StreamDelta: Sendable {
    let text: String?
    let finishReason: String?
    /// Short progress note while the service works between answer tokens
    /// (for example "Searching the web…" during a tool call). Never part
    /// of the answer text.
    var status: String? = nil
    /// Set when the model paused to ask the user a multiple-choice question.
    /// The UI renders the card; the answer travels back through the
    /// service's `askUserQuestion` closure, not through this stream.
    var question: AskUserQuestion? = nil
    /// A tool call finished: its line for the thread and the sources it
    /// found. The view model keeps it with the answer this stream becomes.
    var toolRecord: ChatToolRecord? = nil
    /// One whole model-to-tools-to-model round, with its calls, arguments,
    /// results, statuses, adapters, and timing. The view model keeps these
    /// with the answer and archives them on the turn's receipt.
    var toolRound: ToolRound? = nil
    /// Token usage the provider reported for the turn so far, or nil when it
    /// reported none. Never invented.
    var usage: TokenUsage? = nil
    /// The Chief of Staff card this answer made (`cos tell`), drawn under it.
    var cosCard: String? = nil
}

extension TokenUsage {
    /// True when a provider reported nothing at all.
    var isEmpty: Bool {
        inputTokens == nil && outputTokens == nil && cachedInputTokens == nil && totalTokens == nil
    }

    /// Two reports summed field by field. A field only one report carries is
    /// carried; a field neither reported stays absent.
    func adding(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: Self.sum(inputTokens, other.inputTokens),
            outputTokens: Self.sum(outputTokens, other.outputTokens),
            cachedInputTokens: Self.sum(cachedInputTokens, other.cachedInputTokens),
            totalTokens: Self.sum(totalTokens, other.totalTokens),
            extra: extra
        )
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (l?, r?): return l + r
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }
}

extension Duration {
    /// The duration in seconds, for the schema's `Double` timing fields.
    var secondsValue: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
