import Testing
import Foundation
import HouseChatCore
@testable import QuickLaunch

/// The production turn path end to end: the question is durable before the
/// provider is called, the credential-free provider-body snapshot is archived
/// before inference, and the answer reaches a terminal state.
@Suite("Durable chat turn", .serialized)
@MainActor
struct DurableChatTurnTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("durable-chat-\(UUID())")
    }

    @Test func aTurnIsDurableBeforeInferenceAndTerminalAfter() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "the answer", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service, archiveRootURL: directory)
        vm.settings.autoCopy = false
        vm.settings.historyEnabled = true
        vm.input = "hello there"
        await vm.submit()
        #expect(vm.output == "the answer")

        let archive = try #require(vm.chatArchive)
        let records = try await archive.loadAll()
        #expect(records.count == 1)
        let record = try #require(records.first)

        let question = try #require(record.turns.first { $0.role == .user })
        #expect(question.model?.chosen != nil, "the chat's route is frozen on the user turn")
        #expect(
            question.request?.attachmentRefs.contains { $0.kind == "requestSansKey" } == true,
            "the provider-body snapshot is archived before inference"
        )

        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.text == "the answer")
        #expect(answer.request?.status == .completed)
        #expect(record.turns.filter { $0.role == .assistant }.count == 1, "one assistant turn, not a duplicate")
    }

    @Test func theSnapshotIsTheRealProviderBody() throws {
        let service = OpenAICompatibleService(
            baseURL: URL(string: "https://api.example.com/v1")!,
            modelName: "test-model",
            apiKey: "sk-secret-should-not-appear",
            systemPrompt: "SYSTEM-MARKER-9C1"
        )
        let messages = [QuickMessage(role: .user, content: "hi")]
        let data = try #require(QuickViewModel.requestSnapshotData(
            service: service,
            model: "test-model",
            messages: messages,
            turnImages: [:]
        ))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("SYSTEM-MARKER-9C1"), "the real body carries the service's system prompt")
        #expect(text.contains("stream"), "the real body carries the stream flag")
        #expect(text.contains("test-model"))
        #expect(!text.contains("sk-secret-should-not-appear"), "the key is a header, never in the body")
    }

    @Test func theDestinationSeamNamesTheResolvedRoute() {
        let vm = QuickViewModel()
        let route = vm.resolvedNextRoute()
        #expect(vm.chatDestinationLabel == route.label)
        #expect(!vm.chatDestinationLabel.isEmpty)
        #expect(vm.chatDestinationIsCloud == route.isCloud)
        if let warning = vm.chatRouteWarning { #expect(!warning.isEmpty) }
    }

    @Test func aProviderFailureLeavesAFailedTurnNotAStreamingOne() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = MockQuickService()
        await service.setShouldThrow(true)
        let vm = QuickViewModel(service: service, archiveRootURL: directory)
        vm.settings.autoCopy = false
        vm.settings.historyEnabled = true
        vm.input = "will fail"
        await vm.submit()

        let archive = try #require(vm.chatArchive)
        let record = try #require(try await archive.loadAll().first)
        let answer = try #require(record.turns.first { $0.role == .assistant })
        #expect(answer.request?.status == .failed)
        #expect(answer.request?.error != nil)
    }
}
