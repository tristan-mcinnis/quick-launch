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
///
/// Attachments are fitted first, before this runs
/// (`AttachmentRequestComposer`): they get their own share of the limit,
/// and what that cut or left out rides in `Trim` with the files' names. A
/// turn that still carries an attachment block (at full size or as a head
/// excerpt) is protected here like the first and the current question.
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

    /// The opening of an attachment block in a user turn. A turn that holds
    /// one is never dropped to make room.
    static let attachmentBlockMarker = "<untrusted_attachment "

    /// What `fit` left out, and what the attachment fitting cut or left out
    /// before it, by name.
    struct Trim: Sendable, Equatable {
        var toolResults = 0
        var turns = 0
        /// Attachments sent as a head excerpt to fit, by name.
        var attachmentsCut: [String] = []
        /// Attachments left out to fit (sent as a one-line stub), by name.
        var attachmentsLeftOut: [String] = []

        var isEmpty: Bool {
            toolResults == 0 && turns == 0 && attachmentsCut.isEmpty && attachmentsLeftOut.isEmpty
        }

        /// The line the thread shows, or nil when nothing was left out:
        /// "Left out Q3 report.pdf and 2 older messages to fit the context
        /// window".
        var summary: String? {
            var leftOut = Self.names(attachmentsLeftOut)
            if turns > 0 { leftOut.append("\(turns) older \(turns == 1 ? "message" : "messages")") }
            if toolResults > 0 {
                leftOut.append("\(toolResults) earlier tool \(toolResults == 1 ? "result" : "results")")
            }
            var clauses: [String] = []
            if !attachmentsCut.isEmpty { clauses.append("Cut \(Self.list(Self.names(attachmentsCut)))") }
            if !leftOut.isEmpty {
                clauses.append("\(clauses.isEmpty ? "Left out" : "left out") \(Self.list(leftOut))")
            }
            guard !clauses.isEmpty else { return nil }
            return clauses.joined(separator: ", ") + " to fit the context window"
        }

        /// This trim and a later one as one record, names first seen first.
        func adding(_ other: Trim) -> Trim {
            Trim(
                toolResults: toolResults + other.toolResults,
                turns: turns + other.turns,
                attachmentsCut: Self.merged(attachmentsCut, other.attachmentsCut),
                attachmentsLeftOut: Self.merged(attachmentsLeftOut, other.attachmentsLeftOut)
            )
        }

        private static func merged(_ first: [String], _ second: [String]) -> [String] {
            first + second.filter { !first.contains($0) }
        }

        /// At most three names; past that, two and a count.
        private static func names(_ names: [String]) -> [String] {
            guard names.count > 3 else { return names }
            return Array(names.prefix(2)) + ["\(names.count - 2) more attachments"]
        }

        /// "a", "a and b", "a, b and c".
        private static func list(_ parts: [String]) -> String {
            guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
            return parts.dropLast().joined(separator: ", ") + " and " + last
        }
    }

    /// Whether a wire message is a user turn that carries an attachment
    /// block.
    static func carriesAttachment(_ message: [String: Any]) -> Bool {
        guard message["role"] as? String == "user" else { return false }
        if let text = message["content"] as? String { return text.contains(attachmentBlockMarker) }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.contains { ($0["text"] as? String)?.contains(attachmentBlockMarker) == true }
        }
        return false
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
        //    goes last. A turn that carries an attachment block stays.
        while total > characterLimit {
            let roles = messages.map { $0["role"] as? String }
            guard let first = roles.firstIndex(of: "user"),
                  let current = roles.lastIndex(of: "user"),
                  first < current
            else { break }
            var groups: [Range<Int>] = []
            var start = first + 1
            while start < current {
                var end = start + 1
                if roles[start] == "user", end < current, roles[end] == "assistant" { end += 1 }
                groups.append(start..<end)
                start = end
            }
            let droppable = groups.filter { group in
                !group.contains { Self.carriesAttachment(messages[$0]) }
            }
            // The first answer stays while any later turn can go.
            let firstAnswer = groups.first.flatMap { roles[$0.lowerBound] == "assistant" ? $0 : nil }
            guard let drop = droppable.first(where: { $0 != firstAnswer }) ?? droppable.first else { break }
            for index in drop { total -= Self.characters(in: messages[index]) }
            messages.removeSubrange(drop)
            trim.turns += drop.count
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
