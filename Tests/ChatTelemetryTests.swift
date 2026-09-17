import Testing
import Foundation
import HouseChatCore
@testable import QuickLaunch

/// The turn's real telemetry, end to end: every model round's exact body made
/// durable before its network call, each tool round recorded with its calls,
/// arguments, results, statuses, adapters and timing, and the token usage a
/// provider actually reported. Nothing here is inferred from prose or filled
/// in with a plausible zero.
@Suite("Chat telemetry", .serialized)
struct ChatTelemetryTests {

    // MARK: - Stub transport

    /// One canned SSE round per request, and every request body kept.
    private final class TelemetryStubHTTP: URLProtocol {
        nonisolated(unsafe) static var responses: [[String]] = []
        nonisolated(unsafe) static var recordedBodies: [Data] = []
        private static let lock = NSLock()

        static func reset(_ rounds: [[String]]) {
            lock.lock()
            responses = rounds
            recordedBodies = []
            lock.unlock()
        }

        static func bodyCount() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return recordedBodies.count
        }

        static func body(_ index: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return recordedBodies.indices.contains(index) ? recordedBodies[index] : nil
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

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryStubHTTP.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - Canned rounds

    private static func line(_ object: [String: Any]) -> String {
        "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func toolCallRound(id: String, name: String, arguments: String) -> [String] {
        [
            line(["choices": [[
                "delta": ["tool_calls": [[
                    "index": 0,
                    "id": id,
                    "function": ["name": name, "arguments": arguments],
                ]]],
            ]]]),
            line(["choices": [[
                "delta": [:],
                "finish_reason": "tool_calls",
            ]]]),
            "data: [DONE]",
        ]
    }

    private static func answerRound(_ text: String, usage: [String: Any]? = nil) -> [String] {
        var lines = [
            line(["choices": [["delta": ["content": text]]]]),
            line(["choices": [["delta": [:], "finish_reason": "stop"]]]),
        ]
        if let usage {
            lines.append(line(["choices": [], "usage": usage]))
        }
        lines.append("data: [DONE]")
        return lines
    }

    // MARK: - Fixtures

    private func archive() throws -> (ChatArchive, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-telemetry-\(UUID())")
        return (try ChatArchive(root: root), root)
    }

    /// Commits one user turn the way the app does before inference, so round 0
    /// has a turn to write against and the body it carries is the real one.
    private func submitUserTurn(
        _ archive: ChatArchive,
        text: String = "what is on my plate?",
        snapshot: Data
    ) async throws -> (conversationID: String, turnID: String) {
        let conversation = QuickConversation(providerID: UUID(), model: "test-model")
        let message = QuickMessage(role: .user, content: text)
        var provisional = conversation
        provisional.messages.append(message)
        _ = try await archive.submit(TurnSubmission(
            conversation: provisional,
            requestSnapshot: snapshot,
            requestSnapshotKind: "requestSansKey",
            startedAt: Date()
        ))
        return (conversation.id.uuidString, message.id.uuidString)
    }

    private func service(
        tools: ChatToolbox = ChatToolbox(),
        webSearch: (@Sendable (String) async throws -> String)? = nil,
        recorder: ChatRoundRecorder? = nil
    ) -> OpenAICompatibleService {
        var beforeRequest: (@Sendable (ProviderRequestRound) async throws -> Void)?
        if let recorder {
            beforeRequest = { round in
                try await recorder.beforeRequest(round)
            }
        }
        return OpenAICompatibleService(
            baseURL: URL(string: "http://127.0.0.1:11451/v1")!,
            modelName: "test-model",
            webSearch: webSearch,
            tools: tools,
            beforeRequest: beforeRequest,
            session: Self.session()
        )
    }

    private struct Collected {
        var text = ""
        var rounds: [ToolRound] = []
        var usage: TokenUsage?
        var records: [ChatToolRecord] = []
    }

    /// Yields the deltas it was given and then fails, like a provider whose
    /// connection dropped after it had already reported a tool round.
    private actor FailsAfterDeltasService: QuickService {
        nonisolated let deltas: [StreamDelta]

        init(_ deltas: [StreamDelta]) {
            self.deltas = deltas
        }

        nonisolated func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
            send(messages: messages, images: [])
        }

        nonisolated func send(
            messages: [QuickMessage],
            images: [QuickImageAttachment]
        ) -> AsyncThrowingStream<StreamDelta, Error> {
            AsyncThrowingStream { continuation in
                for delta in self.deltas { continuation.yield(delta) }
                continuation.finish(throwing: MockQuickService.MockError.intentional)
            }
        }

        nonisolated func healthCheck() async throws -> Bool { true }
    }

    private func collect(_ stream: AsyncThrowingStream<StreamDelta, Error>) async throws -> Collected {
        var collected = Collected()
        for try await delta in stream {
            if let text = delta.text { collected.text += text }
            if let round = delta.toolRound { collected.rounds.append(round) }
            if let usage = delta.usage { collected.usage = usage }
            if let record = delta.toolRecord { collected.records.append(record) }
        }
        return collected
    }

    private func snapshotRefs(_ archive: ChatArchive, conversationID: String) async throws -> [String: Data] {
        let record = try await archive.load(id: conversationID)
        let turn = try #require(record.turns.first { $0.role == .user })
        var bodies: [String: Data] = [:]
        for ref in turn.request?.attachmentRefs ?? [] {
            guard let kind = ref.kind, let hash = ref.snapshotHash else { continue }
            let data = try await archive.readArtifact(ArtifactRef(
                kind: .requestSnapshot,
                sha256: hash,
                byteCount: ref.byteCount ?? 0
            ))
            bodies[kind] = data
        }
        return bodies
    }

    private func canonical(_ data: Data?) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: try #require(data))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Per-round snapshots

    @Test func everyRoundBodyIsArchivedBeforeItsRequestAndMatchesWhatWasSent() async throws {
        let (archive, root) = try archive()
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = [QuickMessage(role: .user, content: "which deck?")]
        let memory = FakeMemory(hits: [FakeMemory.hit("state/decisions/dec-01.md")])
        let tools = ChatToolbox(enabled: [.memory], memory: memory)
        // Round 0's body, built by the same request builder the client uses,
        // exactly as the app's pre-Send snapshot is.
        let roundZero = try #require(try service(tools: tools).buildRequest(messages: messages).httpBody)
        let submitted = try await submitUserTurn(archive, text: "which deck?", snapshot: roundZero)
        let recorder = ChatRoundRecorder(archive: archive)
        await recorder.attach(conversationID: submitted.conversationID, turnID: submitted.turnID)

        Self.TelemetryStubHTTP.reset([
            Self.toolCallRound(id: "call_1", name: "recall_memory", arguments: #"{"query":"deck"}"#),
            Self.answerRound("You picked the long deck.", usage: [
                "prompt_tokens": 1200,
                "completion_tokens": 30,
                "total_tokens": 1230,
                "prompt_tokens_details": ["cached_tokens": 900],
            ]),
        ])
        let service = service(tools: tools, recorder: recorder)
        let collected = try await collect(service.send(messages: messages))

        #expect(collected.text == "You picked the long deck.")
        // Two requests reached the transport, and both bodies were made
        // durable before their request.
        #expect(Self.TelemetryStubHTTP.bodyCount() == 2)
        #expect(await recorder.requestedRounds == 2)
        #expect(await recorder.recordedRounds == [1])

        let refs = try await snapshotRefs(archive, conversationID: submitted.conversationID)
        #expect(refs.keys.sorted() == ["requestSansKey", "requestSansKey-round1"])
        // The archived bytes are exactly what the provider received.
        #expect(try canonical(refs["requestSansKey"]) == canonical(Self.TelemetryStubHTTP.body(0)))
        #expect(try canonical(refs["requestSansKey-round1"]) == canonical(Self.TelemetryStubHTTP.body(1)))
        // The second body carries the tool result, which is what makes it a
        // different request from the first.
        let secondBody = try #require(Self.TelemetryStubHTTP.body(1))
        let second = try #require(String(data: secondBody, encoding: .utf8))
        #expect(second.contains("tool_call_id"))
        #expect(second.contains("<memory_results>"))

        // The tool round, with its call recorded fact by fact.
        let round = try #require(collected.rounds.first)
        #expect(collected.rounds.count == 1)
        #expect(round.index == 1)
        #expect(round.status == .succeeded)
        #expect(round.startedAt != nil)
        #expect(round.finishedAt != nil)
        let call = try #require(round.calls.first)
        #expect(call.id == "call_1")
        #expect(call.name == "recall_memory")
        #expect(call.arguments == #"{"query":"deck"}"#)
        #expect(call.status == .succeeded)
        #expect(call.extra["adapter"]?.stringValue == "memory")
        #expect((call.durationSeconds ?? -1) >= 0)

        // Usage exactly as the provider reported it, and nothing invented.
        let usage = try #require(collected.usage)
        #expect(usage.inputTokens == 1200)
        #expect(usage.outputTokens == 30)
        #expect(usage.totalTokens == 1230)
        #expect(usage.cachedInputTokens == 900)
    }

    @Test func aSourceOnlyTurnRecordsNoToolRoundAndNoUsage() async throws {
        let (archive, root) = try archive()
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = [QuickMessage(role: .user, content: "hello")]
        let roundZero = try #require(try service().buildRequest(messages: messages).httpBody)
        let submitted = try await submitUserTurn(archive, text: "hello", snapshot: roundZero)
        let recorder = ChatRoundRecorder(archive: archive)
        await recorder.attach(conversationID: submitted.conversationID, turnID: submitted.turnID)

        Self.TelemetryStubHTTP.reset([Self.answerRound("Just an answer.")])
        let service = service(tools: ChatToolbox(), recorder: recorder)
        let collected = try await collect(service.send(messages: messages))

        #expect(collected.text == "Just an answer.")
        #expect(collected.rounds.isEmpty, "no tool call means no tool round")
        #expect(collected.usage == nil, "a provider that reported none gets none recorded")
        #expect(Self.TelemetryStubHTTP.bodyCount() == 1)
        #expect(await recorder.requestedRounds == 1)
        let refs = try await snapshotRefs(archive, conversationID: submitted.conversationID)
        #expect(refs.keys.sorted() == ["requestSansKey"], "one request, one body: the initial snapshot is not duplicated")
    }

    // MARK: - Failure and refusal

    @Test func aFailedWebSearchIsARecordedFailedRound() async throws {
        Self.TelemetryStubHTTP.reset([
            Self.toolCallRound(id: "call_w", name: "search_web", arguments: #"{"query":"today"}"#),
            Self.answerRound("I could not check."),
        ])
        let service = service(webSearch: { _ in throw QuickServiceError.connectionFailed("offline") })
        let collected = try await collect(service.send(messages: [QuickMessage(role: .user, content: "news?")]))

        let round = try #require(collected.rounds.first)
        #expect(round.status == .failed)
        let call = try #require(round.calls.first)
        #expect(call.name == "search_web")
        #expect(call.status == .failed)
        #expect(call.extra["adapter"]?.stringValue == "web")
        #expect(call.resultSummary == "Web search failed")
        #expect(call.error == "Web search failed")
    }

    @Test func anUnofferedToolCallIsARecordedRefusal() async throws {
        Self.TelemetryStubHTTP.reset([
            Self.toolCallRound(id: "call_v", name: "search_vault", arguments: #"{"query":"q","mode":"current"}"#),
            Self.answerRound("Answered without it."),
        ])
        let service = service(tools: ChatToolbox(enabled: [.memory], memory: FakeMemory()))
        let collected = try await collect(service.send(messages: [QuickMessage(role: .user, content: "q")]))

        let round = try #require(collected.rounds.first)
        #expect(round.status == .refused)
        let call = try #require(round.calls.first)
        #expect(call.status == .refused)
        #expect(call.extra["adapter"]?.stringValue == "unavailable", "no backend ran this call")
        #expect(collected.text == "Answered without it.", "a refused call does not end the turn")
    }

    // MARK: - A snapshot failure blocks the network

    @Test func aSnapshotFailureBlocksTheNextRoundBeforeItsRequest() async throws {
        // A real archive that does not hold this conversation: the round-1
        // snapshot cannot be committed, so round 1 must never be sent.
        let (realArchive, realRoot) = try archive()
        defer { try? FileManager.default.removeItem(at: realRoot) }
        let (otherArchive, otherRoot) = try archive()
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        _ = try await submitUserTurn(
            otherArchive,
            text: "a conversation the recorder does not know",
            snapshot: Data("{}".utf8)
        )

        let recorder = ChatRoundRecorder(archive: realArchive)
        await recorder.attach(conversationID: UUID().uuidString, turnID: UUID().uuidString)

        Self.TelemetryStubHTTP.reset([
            Self.toolCallRound(id: "call_1", name: "recall_memory", arguments: #"{"query":"q"}"#),
            Self.answerRound("should never arrive"),
        ])
        let service = service(
            tools: ChatToolbox(enabled: [.memory], memory: FakeMemory()),
            recorder: recorder
        )
        await #expect(throws: (any Error).self) {
            _ = try await collect(service.send(messages: [QuickMessage(role: .user, content: "q")]))
        }
        #expect(Self.TelemetryStubHTTP.bodyCount() == 1, "the blocked round never reached the transport")
        #expect(await recorder.requestedRounds == 2, "the hook was asked about the round it refused")
    }

    // MARK: - Cancellation

    @Test func cancellationStopsTheLoopBeforeTheSecondRequest() async throws {
        Self.TelemetryStubHTTP.reset([
            Self.toolCallRound(id: "call_1", name: "recall_memory", arguments: #"{"query":"q"}"#),
            Self.answerRound("second round"),
        ])
        let memory = FakeMemory()
        // A tool that never finishes on its own: the loop is cancelled while
        // it waits, so the next round must never be requested.
        await memory.setDelay(.seconds(5))
        let service = service(tools: ChatToolbox(enabled: [.memory], memory: memory))
        let stream = service.send(messages: [QuickMessage(role: .user, content: "q")])

        let consumer = Task {
            for try await _ in stream {}
        }
        var waited = 0
        while Self.TelemetryStubHTTP.bodyCount() < 1, waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(Self.TelemetryStubHTTP.bodyCount() == 1, "the first round went out")
        consumer.cancel()
        _ = try? await consumer.value
        #expect(Self.TelemetryStubHTTP.bodyCount() == 1, "cancelling stopped the turn before its second request")
    }

    // MARK: - The toolbox's own status, not a guess from its prose

    @Test func aVaultUnavailableOutcomeIsARecordedFailure() async throws {
        let vault = FakeVault(outcome: .success(VaultSearchOutcome(
            text: "",
            resultCount: 0,
            sources: [],
            status: .unavailable(reason: "the vault reader is down")
        )))
        Self.TelemetryStubHTTP.reset([
            Self.toolCallRound(
                id: "call_v",
                name: "search_vault",
                arguments: #"{"query":"personal/stack","mode":"current"}"#
            ),
            Self.answerRound("The vault did not respond."),
        ])
        let service = service(tools: ChatToolbox(enabled: [.vault], vault: vault))
        let collected = try await collect(service.send(messages: [QuickMessage(role: .user, content: "stack?")]))

        let round = try #require(collected.rounds.first)
        #expect(round.status == .failed, "an unavailable vault is never recorded as a success")
        let call = try #require(round.calls.first)
        #expect(call.status == .failed)
        #expect(call.extra["adapter"]?.stringValue == "vault")
        #expect(call.resultSummary?.contains("unavailable") == true)
        #expect(collected.text == "The vault did not respond.", "a failed tool never ends the turn")
    }

    @Test func aMemoryFailureIsARecordedFailure() async throws {
        let memory = FakeMemory()
        await memory.setSearchResult(.failure(RecallError.failed("no store")))
        Self.TelemetryStubHTTP.reset([
            Self.toolCallRound(id: "call_m", name: "recall_memory", arguments: #"{"query":"deck"}"#),
            Self.answerRound("Memory did not answer."),
        ])
        let service = service(tools: ChatToolbox(enabled: [.memory], memory: memory))
        let collected = try await collect(service.send(messages: [QuickMessage(role: .user, content: "deck?")]))

        let round = try #require(collected.rounds.first)
        #expect(round.status == .failed)
        let call = try #require(round.calls.first)
        #expect(call.status == .failed)
        #expect(call.extra["adapter"]?.stringValue == "memory")
        #expect(call.resultSummary == "Memory search failed")
    }

    @Test func aZeroResultSearchIsASuccessfulRound() async throws {
        // A reader that answered with nothing is a successful read: the empty
        // answer is the fact, not a failure.
        let vault = FakeVault(outcome: .success(VaultSearchOutcome(
            text: "No evidence for that.",
            resultCount: 0,
            sources: [],
            status: .noMatch
        )))
        Self.TelemetryStubHTTP.reset([
            Self.toolCallRound(id: "call_v", name: "search_vault", arguments: #"{"query":"q","mode":"current"}"#),
            Self.answerRound("Nothing found."),
        ])
        let service = service(tools: ChatToolbox(enabled: [.vault], vault: vault))
        let collected = try await collect(service.send(messages: [QuickMessage(role: .user, content: "q")]))

        let round = try #require(collected.rounds.first)
        #expect(round.status == .succeeded)
        #expect(round.calls.first?.status == .succeeded)
        #expect(round.calls.first?.resultSummary?.contains("no results") == true)

        // A memory read with no hits is the same kind of success.
        Self.TelemetryStubHTTP.reset([
            Self.toolCallRound(id: "call_m", name: "recall_memory", arguments: #"{"query":"nothing"}"#),
            Self.answerRound("Nothing found."),
        ])
        let memoryService = self.service(tools: ChatToolbox(enabled: [.memory], memory: FakeMemory()))
        let memory = try await collect(memoryService.send(messages: [QuickMessage(role: .user, content: "nothing?")]))
        let memoryRound = try #require(memory.rounds.first)
        #expect(memoryRound.status == .succeeded)
        #expect(memoryRound.calls.first?.resultSummary == "Searched memory: no hits")
    }

    // MARK: - The view model carries the same telemetry to the archive

    @Test @MainActor func theViewModelArchivesToolRoundsUsageAndTimings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-telemetry-vm-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MockQuickService()
        let round = ToolRound(
            index: 1,
            calls: [
                ToolCall(
                    id: "call_m",
                    name: "recall_memory",
                    arguments: #"{"query":"deck"}"#,
                    resultSummary: "Searched memory: 1 hit",
                    status: .succeeded,
                    durationSeconds: 0.25,
                    extra: ExtraFields(["adapter": .string("memory")])
                )
            ],
            status: .succeeded,
            durationSeconds: 0.5
        )
        await service.setResponses([
            StreamDelta(text: nil, finishReason: nil, toolRound: round),
            StreamDelta(
                text: nil,
                finishReason: nil,
                usage: TokenUsage(inputTokens: 10, outputTokens: 2, totalTokens: 12)
            ),
            StreamDelta(text: "the answer", finishReason: "stop"),
        ])
        let vm = QuickViewModel(service: service, archiveRootURL: directory)
        vm.settings.autoCopy = false
        vm.settings.historyEnabled = true
        vm.input = "which deck?"
        await vm.submit()

        let archive = try #require(vm.chatArchive)
        let record = try #require(try await archive.loadAll().first)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        let receipt = try #require(answer.request)
        #expect(receipt.status == .completed)
        #expect(receipt.toolRounds.count == 1)
        let call = try #require(receipt.toolRounds.first?.calls.first)
        #expect(call.id == "call_m")
        #expect(call.arguments == #"{"query":"deck"}"#)
        #expect(call.status == .succeeded)
        #expect(call.extra["adapter"]?.stringValue == "memory")
        #expect(call.durationSeconds == 0.25)
        #expect(receipt.usage?.inputTokens == 10)
        #expect(receipt.usage?.totalTokens == 12)
        #expect(receipt.timings.totalSeconds != nil, "the turn's real total, not a zero")
        #expect(receipt.timings.firstTokenSeconds != nil, "measured from the real first token")
        #expect(receipt.timings.extra["persistenceSeconds"]?.doubleValue != nil)
        #expect(receipt.timings.extra["entryToRequestSeconds"]?.doubleValue != nil)
        #expect(answer.timings == TurnTimings(), "no fake turn-level timings are written")
    }

    @Test @MainActor func aFailedTurnStillCarriesItsToolRoundsAndUsage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-telemetry-fail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let round = ToolRound(index: 1, calls: [
            ToolCall(id: "call_w", name: "search_web", status: .failed, extra: ExtraFields(["adapter": .string("web")]))
        ], status: .failed)
        let service = FailsAfterDeltasService([
            StreamDelta(text: nil, finishReason: nil, toolRound: round),
            StreamDelta(text: nil, finishReason: nil, usage: TokenUsage(totalTokens: 7)),
        ])
        let vm = QuickViewModel(service: service, archiveRootURL: directory)
        vm.settings.autoCopy = false
        vm.settings.historyEnabled = true
        vm.input = "fail please"
        await vm.submit()

        let archive = try #require(vm.chatArchive)
        let record = try #require(try await archive.loadAll().first)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.request?.status == .failed)
        #expect(answer.request?.toolRounds.count == 1)
        #expect(answer.request?.usage?.totalTokens == 7)
    }
}
