import Foundation

/// How much of a chat, plus the tool results of the answer in progress, one
/// request may carry. Measured in characters, derived from the model's
/// context window with a safety margin, and applied before every request of
/// the tool loop.
///
/// When a transcript is over the budget, `fit` leaves things out in a fixed
/// order: the results of the answer's older tool rounds first (the call
/// stays, its text becomes a short note), then the oldest turns of the
/// chat, and only then the results of the newest round, the data the model
/// just fetched. The system prompt, the chat's first question, and the
/// current question, with every call the tool loop added after it, are
/// never left out. What was left out is reported, so the thread can say so.
struct ContextBudget: Sendable, Equatable {
    /// Characters the transcript may hold.
    let characterLimit: Int

    /// A conservative estimate: English runs about four characters a token,
    /// code and Chinese fewer.
    static let charactersPerToken = 3
    /// Half the window stays free for the answer, the tool definitions, and
    /// the estimate's error.
    static let usableShare = 0.5
    /// A model with no known window is treated as a small local one.
    static let unknownContextWindow = 32_000
    /// What an image counts for: the data URL itself is never measured.
    static let imageCharacters = 4_000
    /// The text a left-out tool result is replaced with.
    static let omittedToolResult = "[Left out to fit the model's context window.]"

    init(characterLimit: Int) {
        self.characterLimit = characterLimit
    }

    /// The budget for a model with `contextWindow` tokens (nil when unknown).
    init(contextWindow: Int?) {
        let tokens = max(contextWindow ?? Self.unknownContextWindow, 1)
        self.characterLimit = Int(Double(tokens * Self.charactersPerToken) * Self.usableShare)
    }

    /// No limit worth checking.
    static let unlimited = ContextBudget(characterLimit: .max)

    /// What `fit` left out.
    struct Trim: Sendable, Equatable {
        var toolResults = 0
        var turns = 0
        var isEmpty: Bool { toolResults == 0 && turns == 0 }

        /// The line the thread shows, or nil when nothing was left out.
        var summary: String? {
            var parts: [String] = []
            if turns > 0 { parts.append("\(turns) older \(turns == 1 ? "message" : "messages")") }
            if toolResults > 0 {
                parts.append("\(toolResults) earlier tool \(toolResults == 1 ? "result" : "results")")
            }
            guard !parts.isEmpty else { return nil }
            return "Left out \(parts.joined(separator: " and ")) to fit the context window"
        }
    }

    /// Characters one wire message counts for.
    static func characters(in message: [String: Any]) -> Int {
        var total = 0
        if let text = message["content"] as? String {
            total += text.utf8.count
        } else if let parts = message["content"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String { total += text.utf8.count }
                if part["image_url"] != nil { total += imageCharacters }
            }
        }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for call in calls {
                let function = call["function"] as? [String: Any]
                total += ((function?["name"] as? String) ?? "").utf8.count
                total += ((function?["arguments"] as? String) ?? "").utf8.count
            }
        }
        return total
    }

    static func characters(in messages: [[String: Any]]) -> Int {
        messages.reduce(0) { $0 + characters(in: $1) }
    }

    /// `messages` cut to the budget, and what was left out. A transcript that
    /// still does not fit once only the protected messages remain is sent as
    /// it is: the current question is never dropped to make room.
    func fit(_ messages: [[String: Any]]) -> (messages: [[String: Any]], trim: Trim) {
        var messages = messages
        var trim = Trim()
        var total = Self.characters(in: messages)
        guard total > characterLimit else { return (messages, trim) }

        // The newest round starts at the last message that asked for tools:
        // its results are what the model is about to read.
        let newestRound = messages.lastIndex { $0["tool_calls"] != nil } ?? messages.endIndex

        // 1. Results of the older rounds, oldest first.
        omitToolResults(in: messages.startIndex..<newestRound, of: &messages, total: &total, trim: &trim)

        // 2. Turns between the first question and the current one, oldest
        //    first, a question and its answer together; the first answer
        //    goes last.
        while total > characterLimit {
            let roles = messages.map { $0["role"] as? String }
            guard let first = roles.firstIndex(of: "user"),
                  let current = roles.lastIndex(of: "user"),
                  first < current
            else { break }
            var dropStart = first + 1
            // The first answer stays while any later turn can go.
            if roles[dropStart] == "assistant", dropStart + 1 < current { dropStart += 1 }
            guard dropStart < current else { break }
            var dropEnd = dropStart + 1
            if roles[dropStart] == "user", dropEnd < current, roles[dropEnd] == "assistant" {
                dropEnd += 1
            }
            for index in dropStart..<dropEnd { total -= Self.characters(in: messages[index]) }
            messages.removeSubrange(dropStart..<dropEnd)
            trim.turns += dropEnd - dropStart
        }

        // 3. Only when the chat is down to what it must keep: the newest
        //    round's results, oldest first.
        let newestCall = messages.lastIndex { $0["tool_calls"] != nil } ?? messages.endIndex
        omitToolResults(in: newestCall..<messages.endIndex, of: &messages, total: &total, trim: &trim)
        return (messages, trim)
    }

    /// Replaces tool results in `range` with the short note, oldest first,
    /// until the transcript fits.
    private func omitToolResults(
        in range: Range<Int>,
        of messages: inout [[String: Any]],
        total: inout Int,
        trim: inout Trim
    ) {
        for index in range where total > characterLimit {
            guard messages[index]["role"] as? String == "tool",
                  let content = messages[index]["content"] as? String,
                  content != Self.omittedToolResult
            else { continue }
            total -= content.utf8.count
            total += Self.omittedToolResult.utf8.count
            messages[index]["content"] = Self.omittedToolResult
            trim.toolResults += 1
        }
    }
}
