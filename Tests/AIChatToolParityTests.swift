import Foundation
import Testing
@testable import QuickLaunch

@Suite("AI Chat tool parity", .serialized)
@MainActor
struct AIChatToolParityTests {
    @Test func handoffKeepsToolDefinitionsOnTheActualFollowupRequest() throws {
        let (skills, root) = try TemporarySkills.make()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let provider = try #require(settings.providers.first { $0.kind == .openAICompatible })
        let selections: [Set<ChatToolKind>?] = [nil, [.web], []]
        for selection in selections {
            let search = ParityWebSearch()
            let vault = FakeVault(outcome: .failure(VaultSearchError.empty))
            let memory = FakeMemory()
            let launcher = QuickViewModel(settings: settings, webSearchService: search, vaultSearchService: vault)
            let chat = QuickViewModel(store: launcher.store, webSearchService: search, vaultSearchService: vault)
            for view in [launcher, chat] {
                view.memoryService = memory
                view.skillLibrary = skills
            }
            let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
            let window = AIChatWindowModel(chat: chat, defaults: defaults)
            launcher.openQuickAI()
            launcher.currentConversation = QuickConversation(
                providerID: provider.id,
                model: "deepseek-flash",
                messages: [QuickMessage(role: .user, content: "First question"), QuickMessage(role: .assistant, content: "First answer")],
                enabledTools: selection
            )
            let before = try toolNames(launcher, provider: provider)
            window.open(handoff: launcher.makeAIChatHandoff())
            chat.input = "Look something else up"
            let after = try toolNames(chat, provider: provider)
            let expected: Set<String> = selection == nil
                ? ["recall_memory", "recall_today", "search_vault", "read_skill", "search_web"]
                : (selection?.contains(.web) == true ? ["search_web"] : [])
            #expect(before == expected)
            #expect(after == expected)
            #expect(chat.activeModelID == "deepseek-flash")
            #expect(chat.chatTools == launcher.chatTools)
        }
    }

    private func toolNames(_ chat: QuickViewModel, provider: InferenceProvider) throws -> Set<String> {
        let service = try #require(chat.makeService(provider: provider, model: "deepseek-flash") as? OpenAICompatibleService)
        let messages = chat.conversationMessages + [QuickMessage(role: .user, content: "Follow-up")]
        let request = try service.buildRequest(messages: messages)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = body["tools"] as? [[String: Any]] ?? []
        return Set(tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
    }

    @Test func explicitWebSearchStillRunsAfterQuickChatMovesToTheWindow() async throws {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let search = ParityWebSearch()
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "A sourced answer", finishReason: "stop")])
        let launcher = QuickViewModel(settings: settings, service: service, webSearchService: search)
        let chat = QuickViewModel(store: launcher.store, service: service, webSearchService: search)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        launcher.openQuickAI()
        launcher.input = "search the web for first question"
        await launcher.submit()
        let id = try #require(launcher.currentConversation?.id)
        window.open(handoff: launcher.makeAIChatHandoff())
        chat.input = "search the web for follow-up question"
        await chat.submit()
        #expect(await search.queries == ["search the web for first question", "search the web for follow-up question"])
        #expect(chat.currentConversation?.id == id)
        #expect(chat.conversationMessages.filter { $0.role == .assistant }.count == 2)
        #expect(chat.conversationMessages.last?.tools.contains { $0.kind == .web } == true)
        #expect(await service.lastPrompt?.contains("https://example.com/source") == true)
    }
}

private actor ParityWebSearch: WebSearchServicing {
    var queries: [String] = []
    func search(_ query: String) async throws -> String {
        queries.append(query)
        return "## [1] Source\nURL: https://example.com/source\nSnippet: A verified fact."
    }
}
