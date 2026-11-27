import Foundation

/// Splits a leading `<think>…</think>` block out of streamed answer text.
///
/// Local thinking models (Qwen3, DeepSeek R1 distills and others served
/// through an OpenAI-compatible endpoint) put their reasoning inside the
/// answer's own `content`, wrapped in `<think>` tags. Only a block that
/// opens the answer counts: a `<think>` later in the text is the answer's
/// own words and passes through untouched. A tag split across two chunks is
/// held back until it is whole, so no half tag ever reaches the screen.
struct ThinkTagSplitter: Sendable {
    static let openTag = "<think>"
    static let closeTag = "</think>"

    /// `opening`: the reasoning just closed; the blank lines after the close
    /// tag are dropped, in whichever chunk they arrive.
    private enum Mode: Sendable { case undecided, reasoning, opening, answer }
    private var mode = Mode.undecided
    private var pending = ""

    struct Piece: Equatable, Sendable {
        var answer = ""
        var reasoning = ""
    }

    mutating func feed(_ chunk: String) -> Piece {
        pending += chunk
        return drain()
    }

    /// Everything still held back, at the end of the stream.
    mutating func finish() -> Piece {
        defer { pending = "" }
        switch mode {
        case .reasoning: return Piece(reasoning: pending)
        case .opening: return Piece()
        case .undecided, .answer: return Piece(answer: pending)
        }
    }

    private mutating func drain() -> Piece {
        var piece = Piece()
        while true {
            switch mode {
            case .opening:
                pending = String(pending.drop { $0.isWhitespace || $0.isNewline })
                guard !pending.isEmpty else { return piece }
                mode = .answer
            case .answer:
                piece.answer += pending
                pending = ""
                return piece
            case .undecided:
                let lead = pending.drop { $0.isWhitespace || $0.isNewline }
                if lead.hasPrefix(Self.openTag) {
                    pending = String(lead.dropFirst(Self.openTag.count))
                    mode = .reasoning
                } else if lead.isEmpty || Self.openTag.hasPrefix(lead) {
                    // Only whitespace, or the start of a tag: wait for more.
                    return piece
                } else {
                    mode = .answer
                }
            case .reasoning:
                if let close = pending.range(of: Self.closeTag) {
                    piece.reasoning += pending[..<close.lowerBound]
                    pending = String(pending[close.upperBound...])
                    mode = .opening
                } else {
                    // Hold back a tail that could be the start of the close tag.
                    let held = Self.heldSuffixLength(pending, tag: Self.closeTag)
                    let cut = pending.index(pending.endIndex, offsetBy: -held)
                    piece.reasoning += pending[..<cut]
                    pending = String(pending[cut...])
                    return piece
                }
            }
        }
    }

    /// The length of the longest suffix of `text` that is a proper prefix of `tag`.
    private static func heldSuffixLength(_ text: String, tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) where tag.hasPrefix(text.suffix(length)) {
            return length
        }
        return 0
    }
}
