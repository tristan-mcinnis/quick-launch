import Foundation
import Testing
@testable import QuickLaunch

/// The service's tool loop with the chat tools: the memory call end to end,
/// the six-round cap, the wall-clock budget, and the context budget, on
/// canned SSE rounds and fake tool backends.
@Suite("Tool loop", .serialized)
struct ToolLoopTests {

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LoopStubHTTP.self]
        return URLSession(configuration: configuration)
    }

    private static func service(
        tools: ChatToolbox = ChatToolbox(),
        contextBudget: ContextBudget = .unlimited,
        toolTimeBudget: Duration = OpenAICompatibleService.defaultToolTimeBudget,
        askUserQuestion: (@Sendable (AskUserQuestion) async -> AskUserQuestionAnswer?)? = nil
    ) -> OpenAICompatibleService {
        OpenAICompatibleService(
            baseURL: URL(string: "http://127.0.0.1:11451/v1")!,
            modelName: "test-model",
            askUserQuestion: askUserQuestion,
            tools: tools,
            contextBudget: contextBudget,
            toolTimeBudget: toolTimeBudget,
            session: session()
        )
    }

    private static func toolCallRound(_ id: String, name: String, arguments: String) -> [String] {
        let escaped = arguments
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":""# + id
                + #"","function":{"name":""# + name + #"","arguments":""# + escaped + #""}}]}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]",
        ]
    }

    private static func answerRound(_ text: String) -> [String] {
        [
            #"data: {"choices":[{"delta":{"content":""# + text + #""}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ]
    }

    private struct Collected {
        var text = ""
        var statuses: [String] = []
        var records: [ChatToolRecord] = []
    }

    private static func collect(_ stream: AsyncThrowingStream<StreamDelta, Error>) async throws -> Collected {
        var collected = Collected()
        for try await delta in stream {
            if let text = delta.text { collected.text += text }
            if let status = delta.status { collected.statuses.append(status) }
            if let record = delta.toolRecord { collected.records.append(record) }
        }
        return collected
    }

    private static func body(_ index: Int) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: LoopStubHTTP.recordedBodies[index]) as? [String: Any])
    }

    private static func toolNames(in body: [String: Any]) -> [String] {
        (body["tools"] as? [[String: Any]] ?? [])
            .compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    }

    // MARK: - A memory call end to end

    @Test func aMemoryCallRunsAndLeavesItsLineAndSources() async throws {
        LoopStubHTTP.reset([
            Self.toolCallRound("call_m", name: "recall_memory", arguments: #"{"query":"long deck"}"#),
            Self.answerRound("You chose the long deck."),
        ])
        let memory = FakeMemory(hits: [FakeMemory.hit("state/decisions/dec-01.md")])
        let service = Self.service(tools: ChatToolbox(enabled: [.memory], memory: memory))

        let collected = try await Self.collect(service.send(messages: [QuickMessage(role: .user, content: "which deck did I pick?")]))

        #expect(collected.text == "You chose the long deck.")
        #expect(collected.statuses == ["Searching memory…"])
        #expect(collected.records.map(\.summary) == ["Searched memory: 1 hit"])
        #expect(collected.records.first?.sources.first?.path == "/Users/test/memory/state/decisions/dec-01.md")
        #expect(await memory.queries == ["long deck"])

        let first = try Self.body(0)
        #expect(Self.toolNames(in: first) == ["recall_memory", "recall_today"])
        #expect(first["tool_choice"] == nil)
        let second = try Self.body(1)
        let messages = try #require(second["messages"] as? [[String: Any]])
        let result = messages.first { $0["role"] as? String == "tool" }
        #expect(result?["tool_call_id"] as? String == "call_m")
        #expect((result?["content"] as? String)?.contains("<memory_results>") == true)
    }

    @Test func aCallToAToolThatIsNotOfferedIsAnsweredNotDropped() async throws {
        LoopStubHTTP.reset([
            Self.toolCallRound("call_x", name: "search_vault", arguments: #"{"query":"q"}"#),
            Self.answerRound("Answered without it."),
        ])
        let collected = try await Self.collect(
            Self.service(tools: ChatToolbox(enabled: [.memory], memory: FakeMemory()))
                .send(messages: [QuickMessage(role: .user, content: "q")])
        )
        #expect(collected.text == "Answered without it.")
        let messages = try #require(try Self.body(1)["messages"] as? [[String: Any]])
        let result = messages.first { $0["role"] as? String == "tool" }
        #expect(result?["content"] as? String == "The search_vault tool is unavailable.")
    }

    // MARK: - The round cap

    @Test func afterSixToolRoundsTheModelIsToldToAnswer() async throws {
        #expect(OpenAICompatibleService.maxToolRounds == 6)
        var rounds = (1...6).map { Self.toolCallRound("call_\($0)", name: "recall_memory", arguments: #"{"query":"x"}"#) }
        rounds.append(Self.answerRound("Best I have."))
        LoopStubHTTP.reset(rounds)
        let memory = FakeMemory(hits: [FakeMemory.hit("a.md")])

        let collected = try await Self.collect(
            Self.service(tools: ChatToolbox(enabled: [.memory], memory: memory))
                .send(messages: [QuickMessage(role: .user, content: "dig")])
        )

        #expect(collected.text == "Best I have.")
        #expect(LoopStubHTTP.recordedBodies.count == 7, "six tool rounds, then one answer round")
        #expect(await memory.queries.count == 6)
        for index in 0..<6 {
            #expect(try Self.body(index)["tool_choice"] == nil, "round \(index + 1) may call tools")
        }
        let last = try Self.body(6)
        #expect(last["tool_choice"] as? String == "none")
        #expect(!Self.toolNames(in: last).isEmpty, "the tools stay on the request that has tool calls in it")
        let messages = try #require(last["messages"] as? [[String: Any]])
        let lastResult = messages.last { $0["role"] as? String == "tool" }
        #expect((lastResult?["content"] as? String)?.hasSuffix(OpenAICompatibleService.answerNowNote) == true)
    }

    @Test func aFinalRoundThatStillCallsToolsEndsTheLoop() async throws {
        var rounds = (1...7).map { Self.toolCallRound("call_\($0)", name: "recall_memory", arguments: #"{"query":"x"}"#) }
        rounds.append(Self.answerRound("never requested"))
        LoopStubHTTP.reset(rounds)
        let memory = FakeMemory()
        _ = try await Self.collect(
            Self.service(tools: ChatToolbox(enabled: [.memory], memory: memory))
                .send(messages: [QuickMessage(role: .user, content: "dig")])
        )
        #expect(LoopStubHTTP.recordedBodies.count == 7)
        #expect(await memory.queries.count == 6, "the seventh call is never run")
    }

    // MARK: - The wall-clock budget

    @Test func aSlowToolIsCutAtTheBudgetAndTheModelAnswers() async throws {
        LoopStubHTTP.reset([
            Self.toolCallRound("call_slow", name: "recall_memory", arguments: #"{"query":"x"}"#),
            Self.answerRound("Memory was slow."),
        ])
        let memory = FakeMemory(hits: [FakeMemory.hit("a.md")])
        await memory.setDelay(.seconds(30))
        let clock = ContinuousClock()
        let started = clock.now

        let collected = try await Self.collect(
            Self.service(
                tools: ChatToolbox(enabled: [.memory], memory: memory),
                toolTimeBudget: .milliseconds(300)
            ).send(messages: [QuickMessage(role: .user, content: "q")])
        )

        #expect(clock.now - started < .seconds(10), "the loop never waits out a stuck tool")
        #expect(collected.text == "Memory was slow.")
        #expect(collected.records.map(\.summary) == ["Memory search ran out of time"])
        let second = try Self.body(1)
        #expect(second["tool_choice"] as? String == "none", "out of time: answer with what you have")
        let messages = try #require(second["messages"] as? [[String: Any]])
        let result = messages.last { $0["role"] as? String == "tool" }
        #expect((result?["content"] as? String)?.contains("ran out of time") == true)
    }

    @Test func timeOnTheQuestionCardDoesNotCountAgainstTheBudget() async throws {
        let ask = #"{"question":"Which one?","options":[{"label":"A"},{"label":"B"}]}"#
        LoopStubHTTP.reset([
            Self.toolCallRound("call_q", name: "ask_user_question", arguments: ask),
            Self.toolCallRound("call_m", name: "recall_memory", arguments: #"{"query":"A"}"#),
            Self.answerRound("Done."),
        ])
        let memory = FakeMemory(hits: [FakeMemory.hit("a.md")])
        let collected = try await Self.collect(
            Self.service(
                tools: ChatToolbox(enabled: [.memory], memory: memory),
                toolTimeBudget: .milliseconds(400),
                askUserQuestion: { _ in
                    // The user takes longer to pick than the whole budget.
                    try? await Task.sleep(for: .milliseconds(700))
                    return AskUserQuestionAnswer(label: "A", detail: nil)
                }
            ).send(messages: [QuickMessage(role: .user, content: "q")])
        )
        #expect(collected.text == "Done.")
        #expect(try Self.body(1)["tool_choice"] == nil, "the pick took the time, not the tools")
        #expect(collected.records.map(\.summary) == ["Searched memory: 1 hit"])
    }

    // MARK: - The context budget

    @Test func aLongChatIsCutBeforeTheRequestAndTheThreadIsTold() async throws {
        LoopStubHTTP.reset([Self.answerRound("Fine.")])
        let long = String(repeating: "word ", count: 200)
        let history: [QuickMessage] = [
            QuickMessage(role: .user, content: "first question " + long),
            QuickMessage(role: .assistant, content: "first answer " + long),
            QuickMessage(role: .user, content: "second question " + long),
            QuickMessage(role: .assistant, content: "second answer " + long),
            QuickMessage(role: .user, content: "the current question"),
        ]
        let collected = try await Self.collect(
            Self.service(contextBudget: ContextBudget(characterLimit: 2_500)).send(messages: history)
        )
        #expect(collected.text == "Fine.")
        #expect(collected.records.map(\.kind) == [.context])
        #expect(collected.records.first?.summary == "Left out 2 older messages to fit the context window")
        let messages = try #require(try Self.body(0)["messages"] as? [[String: Any]])
        let contents = messages.compactMap { $0["content"] as? String }
        #expect(contents.count == 4, "system, the first exchange, and the current question")
        #expect(contents.last == "the current question")
        #expect(contents[1].hasPrefix("first question"))
        #expect(!contents.contains { $0.hasPrefix("second") })
    }

    @Test func aResultJustFetchedIsReadEvenWhenItPushesTheChatOverTheBudget() async throws {
        let long = String(repeating: "word ", count: 200)
        let history: [QuickMessage] = [
            QuickMessage(role: .user, content: "first question " + long),
            QuickMessage(role: .assistant, content: "first answer " + long),
            QuickMessage(role: .user, content: "which deck did I pick?"),
        ]
        let hit = FakeMemory.hit("state/decisions/dec-01.md", line: "long deck " + String(repeating: "detail ", count: 150))
        let rounds = [
            Self.toolCallRound("call_m", name: "recall_memory", arguments: #"{"query":"deck"}"#),
            Self.answerRound("The long deck."),
        ]

        // Measure the second request with no budget.
        LoopStubHTTP.reset(rounds)
        _ = try await Self.collect(
            Self.service(tools: ChatToolbox(enabled: [.memory], memory: FakeMemory(hits: [hit]))).send(messages: history)
        )
        let unlimited = try #require(try Self.body(1)["messages"] as? [[String: Any]])
        let firstRound = try #require(try Self.body(0)["messages"] as? [[String: Any]])
        let needed = ContextBudget.characters(in: unlimited)
        #expect(ContextBudget.characters(in: firstRound) < needed - 1)

        // One character short: the first request fits, the second does not.
        LoopStubHTTP.reset(rounds)
        let collected = try await Self.collect(
            Self.service(
                tools: ChatToolbox(enabled: [.memory], memory: FakeMemory(hits: [hit])),
                contextBudget: ContextBudget(characterLimit: needed - 1)
            ).send(messages: history)
        )
        #expect(collected.text == "The long deck.")
        let messages = try #require(try Self.body(1)["messages"] as? [[String: Any]])
        let result = try #require(messages.first { $0["role"] as? String == "tool" }?["content"] as? String)
        #expect(result.contains("long deck detail"), "the model reads what it fetched")
        #expect(!messages.contains { ($0["content"] as? String)?.hasPrefix("first answer") == true })
        #expect(collected.records.map(\.summary) == ["Searched memory: 1 hit", "Left out 1 older message to fit the context window"])
    }
}

/// Serves canned SSE rounds in order and records every request body. Its
/// own class, so its state never mixes with another suite's stub.
private final class LoopStubHTTP: URLProtocol {
    // Guarded by `lock`; the suite is serialized.
    nonisolated(unsafe) static var responses: [[String]] = []
    nonisolated(unsafe) static var recordedBodies: [Data] = []
    private static let lock = NSLock()

    static func reset(_ rounds: [[String]]) {
        lock.lock()
        responses = rounds
        recordedBodies = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let lines = Self.responses.isEmpty ? [] : Self.responses.removeFirst()
        if let body = Self.body(of: request) { Self.recordedBodies.append(body) }
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((lines.joined(separator: "\n\n") + "\n").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16_384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
