import Foundation
import Testing
@testable import QuickLaunch

/// The context budget: what a long chat and its tool results lose first,
/// and what they never lose.
@Suite("Context budget")
struct ContextBudgetTests {

    private static func message(_ role: String, _ length: Int, tag: String = "") -> [String: Any] {
        ["role": role, "content": tag + String(repeating: "x", count: max(0, length - tag.count))]
    }

    private static func contents(_ messages: [[String: Any]]) -> [String] {
        messages.map { ($0["content"] as? String).map { String($0.prefix(3)) } ?? "nil" }
    }

    @Test func derivesTheLimitFromTheContextWindowWithAMargin() {
        #expect(ContextBudget(contextWindow: 1_000_000).characterLimit == 1_500_000)
        #expect(ContextBudget(contextWindow: 128_000).characterLimit == 192_000)
        // Unknown windows are treated as a small local model.
        #expect(ContextBudget(contextWindow: nil).characterLimit == 48_000)
        // Always less than the window itself at four characters a token.
        #expect(ContextBudget(contextWindow: 256_000).characterLimit < 256_000 * 4)
    }

    @Test func aTranscriptUnderTheBudgetIsUntouched() {
        let messages = [Self.message("system", 10), Self.message("user", 10)]
        let fitted = ContextBudget(characterLimit: 100).fit(messages)
        #expect(fitted.trim.isEmpty)
        #expect(fitted.messages.count == 2)
        #expect(fitted.trim.summary == nil)
    }

    private static func call(_ id: String) -> [String: Any] {
        ["role": "assistant", "content": NSNull(), "tool_calls": [["id": id, "type": "function", "function": ["name": "recall_memory", "arguments": "{}"]]]]
    }

    @Test func dropsTheOlderRoundsResultsFirstAndKeepsTheNewestRound() {
        let messages: [[String: Any]] = [
            Self.message("system", 10, tag: "sys"),
            Self.message("user", 10, tag: "u1-"),
            Self.message("assistant", 10, tag: "a1-"),
            Self.message("user", 10, tag: "cur"),
            Self.call("c1"),
            Self.message("tool", 400, tag: "t1-"),
            Self.call("c2"),
            Self.message("tool", 400, tag: "t2-"),
        ]
        let fitted = ContextBudget(characterLimit: 600).fit(messages)
        #expect(fitted.trim == ContextBudget.Trim(toolResults: 1, turns: 0))
        #expect(fitted.messages[5]["content"] as? String == ContextBudget.omittedToolResult)
        #expect((fitted.messages[7]["content"] as? String)?.hasPrefix("t2-") == true, "the newest result stays")
        #expect(fitted.messages.count == messages.count, "the call and its result keep their pairing")
        #expect(fitted.trim.summary == "Left out 1 earlier tool result to fit the context window")
    }

    @Test func aResultJustFetchedOutlastsTheOldTurns() {
        // Round 1 of the tool loop trims the chat to just under the limit.
        let history: [[String: Any]] = [
            Self.message("system", 10, tag: "sys"),
            Self.message("user", 400, tag: "q1-"),
            Self.message("assistant", 900, tag: "a1-"),
            Self.message("user", 400, tag: "q2-"),
            Self.message("assistant", 900, tag: "a2-"),
            Self.message("user", 200, tag: "cur"),
        ]
        let budget = ContextBudget(characterLimit: 2_500)
        var transcript = budget.fit(history).messages
        #expect(Self.contents(transcript) == ["sys", "q1-", "a1-", "cur"])

        // Round 2 adds the call and its fresh result, and goes over again.
        transcript.append(Self.call("c1"))
        transcript.append(Self.message("tool", 1_200, tag: "t1-"))
        let fitted = budget.fit(transcript)
        #expect(Self.contents(fitted.messages) == ["sys", "q1-", "cur", "nil", "t1-"])
        #expect((fitted.messages.last?["content"] as? String)?.count == 1_200, "the model reads what it fetched")
        #expect(fitted.trim == ContextBudget.Trim(toolResults: 0, turns: 1))
    }

    @Test func thenDropsTheOldestTurnsKeepingTheFirstQuestionAndTheCurrentOne() {
        let messages: [[String: Any]] = [
            Self.message("system", 10, tag: "sys"),
            Self.message("user", 100, tag: "u1-"),
            Self.message("assistant", 100, tag: "a1-"),
            Self.message("user", 100, tag: "u2-"),
            Self.message("assistant", 100, tag: "a2-"),
            Self.message("user", 100, tag: "u3-"),
            Self.message("assistant", 100, tag: "a3-"),
            Self.message("user", 100, tag: "cur"),
            Self.call("c1"),
            Self.message("tool", 100, tag: "t1-"),
        ]
        // Room for the system prompt, two questions, and the newest round.
        let fitted = ContextBudget(characterLimit: 360).fit(messages)
        #expect(Self.contents(fitted.messages) == ["sys", "u1-", "cur", "nil", "t1-"])
        #expect(fitted.trim == ContextBudget.Trim(toolResults: 0, turns: 5))
        #expect(fitted.trim.summary == "Left out 5 older messages to fit the context window")
    }

    @Test func theNewestRoundGoesOnlyWhenNothingElseCan() {
        let messages: [[String: Any]] = [
            Self.message("system", 10, tag: "sys"),
            Self.message("user", 100, tag: "u1-"),
            Self.message("assistant", 100, tag: "a1-"),
            Self.message("user", 100, tag: "cur"),
            Self.call("c1"),
            Self.message("tool", 400, tag: "t1-"),
            Self.message("tool", 400, tag: "t2-"),
        ]
        let fitted = ContextBudget(characterLimit: 700).fit(messages)
        #expect(Self.contents(fitted.messages) == ["sys", "u1-", "cur", "nil", "[Le", "t2-"])
        #expect(fitted.trim == ContextBudget.Trim(toolResults: 1, turns: 1))
    }

    @Test func theFirstAnswerGoesOnlyAfterEveryLaterTurn() {
        let messages: [[String: Any]] = [
            Self.message("system", 10, tag: "sys"),
            Self.message("user", 100, tag: "u1-"),
            Self.message("assistant", 100, tag: "a1-"),
            Self.message("user", 100, tag: "u2-"),
            Self.message("assistant", 100, tag: "a2-"),
            Self.message("user", 100, tag: "cur"),
        ]
        let fitted = ContextBudget(characterLimit: 250).fit(messages)
        #expect(Self.contents(fitted.messages) == ["sys", "u1-", "cur"])
        #expect(fitted.trim.turns == 3)
    }

    @Test func neverDropsTheCurrentQuestionEvenWhenItAloneIsTooLong() {
        let messages: [[String: Any]] = [
            Self.message("system", 10, tag: "sys"),
            Self.message("user", 100, tag: "u1-"),
            Self.message("assistant", 100, tag: "a1-"),
            Self.message("user", 5_000, tag: "cur"),
        ]
        let fitted = ContextBudget(characterLimit: 1_000).fit(messages)
        #expect(Self.contents(fitted.messages) == ["sys", "u1-", "cur"])
        #expect((fitted.messages.last?["content"] as? String)?.count == 5_000, "sent whole, never cut")
    }

    @Test func aFirstQuestionThatIsTheCurrentOneIsKept() {
        let messages: [[String: Any]] = [Self.message("system", 10), Self.message("user", 5_000)]
        let fitted = ContextBudget(characterLimit: 100).fit(messages)
        #expect(fitted.messages.count == 2)
        #expect(fitted.trim.isEmpty)
    }

    @Test func imagesCountAsAFixedSizeNotTheirDataURL() {
        let image: [String: Any] = [
            "role": "user",
            "content": [
                ["type": "text", "text": "what is this"],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + String(repeating: "A", count: 100_000)]],
            ],
        ]
        #expect(ContextBudget.characters(in: image) == "what is this".utf8.count + ContextBudget.imageCharacters)
    }
}
