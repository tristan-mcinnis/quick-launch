import Foundation
import Testing
@testable import QuickLaunch

@Suite("Reasoning")
struct ReasoningTests {

    private static func run(_ chunks: [String]) -> ThinkTagSplitter.Piece {
        var splitter = ThinkTagSplitter()
        var total = ThinkTagSplitter.Piece()
        for chunk in chunks {
            let piece = splitter.feed(chunk)
            total.answer += piece.answer
            total.reasoning += piece.reasoning
        }
        let tail = splitter.finish()
        total.answer += tail.answer
        total.reasoning += tail.reasoning
        return total
    }

    // MARK: - Think tags

    @Test func plainAnswerPassesThroughUntouched() {
        #expect(Self.run(["Hello ", "world"]) == .init(answer: "Hello world"))
    }

    @Test func aLaterThinkTagIsTheAnswersOwnWords() {
        let piece = Self.run(["Use the <think> tag ", "like this."])
        #expect(piece == .init(answer: "Use the <think> tag like this."))
    }

    @Test func aLeadingBlockIsReasoningWhateverTheChunking() {
        let whole = "\n<think>step one\nstep two</think>\n\nThe answer."
        // Every way to cut the stream in two gives the same split.
        for cut in 0...whole.count {
            let index = whole.index(whole.startIndex, offsetBy: cut)
            let piece = Self.run([String(whole[..<index]), String(whole[index...])])
            #expect(piece == .init(answer: "The answer.", reasoning: "step one\nstep two"), "cut at \(cut)")
        }
    }

    @Test func noHalfTagReachesTheScreenMidStream() {
        var splitter = ThinkTagSplitter()
        #expect(splitter.feed("<th") == .init())
        #expect(splitter.feed("ink>abc</thi") == .init(reasoning: "abc"))
        #expect(splitter.feed("nk>Done") == .init(answer: "Done"))
    }

    @Test func anUnclosedBlockStaysReasoning() {
        #expect(Self.run(["<think>still going"]) == .init(reasoning: "still going"))
    }

    @Test func aShortAnswerThatLooksLikeATagStartIsKept() {
        #expect(Self.run(["<"]) == .init(answer: "<"))
        #expect(Self.run(["<b>bold</b>"]) == .init(answer: "<b>bold</b>"))
    }

    // MARK: - Turn state

    @Test func thinkingTimeRunsFromFirstReasoningToFirstAnswerText() {
        var turn = ActiveTurnState()
        let start = Date(timeIntervalSince1970: 1_000)
        turn.noteReasoning("a", at: start)
        turn.noteReasoning("b", at: start.addingTimeInterval(2))
        turn.noteAnswerText(at: start.addingTimeInterval(7.4))
        turn.noteAnswerText(at: start.addingTimeInterval(20))
        #expect(turn.reasoningTrace?.text == "ab")
        #expect(abs((turn.reasoningTrace?.seconds ?? 0) - 7.4) < 0.001)
    }

    @Test func noReasoningMeansNoTrace() {
        var turn = ActiveTurnState()
        turn.noteAnswerText()
        turn.noteReasoning("")
        #expect(turn.reasoningTrace == nil)
        turn.noteReasoning("  \n")
        #expect(turn.reasoningTrace == nil)
    }

    @Test func resetForgetsTheReasoning() {
        var turn = ActiveTurnState()
        turn.noteReasoning("x")
        turn.reset()
        #expect(turn.liveReasoning.isEmpty)
        #expect(turn.reasoningStartedAt == nil)
    }

    // MARK: - Wording and storage

    @Test func headlineWording() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ReasoningFold.headline(seconds: 12.4, startedAt: nil, now: start) == "Thought for 12 s")
        #expect(ReasoningFold.headline(seconds: 0.2, startedAt: nil, now: start) == "Thought for 1 s")
        #expect(ReasoningFold.headline(seconds: nil, startedAt: start, now: start.addingTimeInterval(0.5)) == "Thinking…")
        #expect(ReasoningFold.headline(seconds: nil, startedAt: start, now: start.addingTimeInterval(4)) == "Thinking… 4 s")
        #expect(ReasoningFold.headline(seconds: nil, startedAt: nil, now: start) == "Reasoning")
    }

    @Test func aMessageSavedBeforeReasoningStillLoads() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","role":"assistant","content":"Hi"}"#
        let message = try JSONDecoder().decode(QuickMessage.self, from: Data(json.utf8))
        #expect(message.reasoning == nil)
        let withTrace = QuickMessage(role: .assistant, content: "Hi", reasoning: ReasoningTrace(text: "r", seconds: 3))
        let roundTrip = try JSONDecoder().decode(QuickMessage.self, from: JSONEncoder().encode(withTrace))
        #expect(roundTrip.reasoning == withTrace.reasoning)
    }
}
