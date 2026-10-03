import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Tools inside the chat, on the view model: tool lines kept with the
/// answer (and shown again when the chat reopens), the per-chat tool set
/// and `⌘K` › Tools, Open Source, and Capture to Memory.
@Suite("Chat tools in Quick AI", .serialized)
@MainActor
struct ChatToolsViewModelTests {

    private func make(
        service: MockQuickService = MockQuickService(),
        history: Bool = true,
        configure: (inout QuickSettings) -> Void = { _ in }
    ) -> QuickViewModel {
        var settings = QuickSettings()
        settings.autoCopy = false
        // History on, but with no file: kept in memory only.
        settings.historyEnabled = history
        configure(&settings)
        return QuickViewModel(settings: settings, service: service)
    }

    private static let memoryLine = ChatToolRecord(
        kind: .memory,
        summary: "Searched memory: 2 hits",
        sources: [
            ChatSource(title: "state/decisions/dec-01.md", day: "2026-09-03", path: "/Users/test/memory/state/decisions/dec-01.md"),
            ChatSource(title: "episodic/2026-09-06.md", day: "2026-09-06", path: "/Users/test/memory/episodic/2026-09-06.md"),
        ]
    )
    private static let vaultLine = ChatToolRecord(
        kind: .vault,
        summary: "Searched vault · current: 6 results",
        sources: [ChatSource(title: "Acme Launch status", day: "2026-08-24", path: "/Users/test/vault/kb/00-status.md")]
    )

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, deltas: [StreamDelta]) async {
        await mock.setResponses(deltas)
        vm.openQuickAI()
        vm.input = question
        await vm.submit()
    }

    // MARK: - Tool lines

    @Test func toolLinesAreKeptWithTheAnswerAndComeBackWhenTheChatReopens() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "which deck did I pick", deltas: [
            StreamDelta(text: nil, finishReason: nil, status: "Searching memory…"),
            StreamDelta(text: nil, finishReason: nil, toolRecord: Self.memoryLine),
            StreamDelta(text: nil, finishReason: nil, toolRecord: Self.vaultLine),
            StreamDelta(text: "The long deck.", finishReason: "stop"),
        ])

        let answer = try #require(vm.conversationMessages.last)
        #expect(answer.role == .assistant)
        #expect(answer.tools == [Self.memoryLine, Self.vaultLine])
        #expect(answer.sources.map(\.title) == ["state/decisions/dec-01.md", "episodic/2026-09-06.md", "Acme Launch status"])
        #expect(vm.liveToolRecords.isEmpty, "the lines live on the answer now")
        #expect(vm.conversationMessages.first?.toolRecords == nil, "questions carry no lines")

        // The chat is saved with its lines; reopening it shows them.
        let id = try #require(vm.currentConversation?.id)
        vm.startNewConversation()
        #expect(vm.conversationMessages.isEmpty)
        vm.loadConversation(id: id)
        #expect(vm.conversationMessages.last?.tools == [Self.memoryLine, Self.vaultLine])
    }

    @Test func toolLinesSurviveTheHistoryFile() throws {
        let conversation = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "deepseek-flash",
            messages: [
                QuickMessage(role: .user, content: "q"),
                QuickMessage(role: .assistant, content: "a", toolRecords: [Self.memoryLine]),
            ],
            enabledTools: [.memory, .web]
        )
        var withTasks = conversation
        withTasks.enabledTools = [.memory, .tasks, .web]
        let data = try JSONEncoder().encode([withTasks])
        let decoded = try JSONDecoder().decode([QuickConversation].self, from: data)
        #expect(decoded.first?.messages.last?.tools == [Self.memoryLine])
        #expect(decoded.first?.enabledTools == [.memory, .tasks, .web])
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect((json.first?["enabledTools"] as? [String])?.contains("tasks") == false)
        #expect(json.first?["tasksEnabled"] as? Bool == true)

        // A chat saved before v1.5.0 has no lines and still loads.
        let legacy = #"{"id":"6E1C6C3A-6A5E-4F5A-9E0B-2B9B7E5E7B11","role":"assistant","content":"old"}"#
        let message = try JSONDecoder().decode(QuickMessage.self, from: Data(legacy.utf8))
        #expect(message.toolRecords == nil)
        #expect(message.tools.isEmpty)
    }

    @Test func linesShowLiveWhileTheAnswerStreamsAndGoWithAFailedStream() async {
        let vm = make()
        vm.noteLiveToolRecord(Self.memoryLine)
        #expect(vm.liveToolRecords == [Self.memoryLine])
        // The context line is one per answer, with the running total.
        vm.noteLiveToolRecord(ChatToolRecord(kind: .context, summary: "Left out 2 older messages to fit the context window"))
        vm.noteLiveToolRecord(ChatToolRecord(kind: .context, summary: "Left out 4 older messages to fit the context window"))
        #expect(vm.liveToolRecords.map(\.summary) == [
            "Searched memory: 2 hits",
            "Left out 4 older messages to fit the context window",
        ])

        // A stream that finds something, then fails, leaves no lines.
        vm.service = LineThenFailService(record: Self.memoryLine)
        vm.openQuickAI()
        vm.input = "q"
        await vm.submit()
        // A provider error stays under its question in the thread (Phase A2).
        #expect(vm.threadError != nil)
        #expect(vm.liveToolRecords.isEmpty, "a failed answer leaves no lines behind")
        #expect(vm.conversationMessages.allSatisfy { $0.toolRecords == nil })
    }

    @Test func aWebAnswerStillRunningItsToolsIsNotCutByTheSilentModelWatchdog() async throws {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: ToolThenSlowAnswerService(record: Self.memoryLine, delay: .milliseconds(900)),
            webSearchService: ImmediateWebSearch()
        )
        // Shorter than the answer, longer than the first tool line.
        vm.webAnswerTimeout = .milliseconds(300)
        vm.openQuickAI()
        vm.input = "search web acme launch status"
        await vm.submit()

        #expect(vm.output == "Answer after tools.", "the model was working, not silent")
        #expect(vm.errorMessage == nil)
        let answer = try #require(vm.conversationMessages.last)
        #expect(answer.tools.map(\.kind) == [.web, .memory], "the explicit search first, then the call")
        #expect(answer.tools.first?.summary.hasPrefix("Search web: ") == true)
    }

    // MARK: - The chat's tools

    @Test func defaultsAreMemoryTasksVaultAndSkillsWithWebPerTheSetting() {
        let on = make { $0.modelWebSearchEnabled = true }
        #expect(on.chatTools == [.memory, .tasks, .vault, .skills, .web])
        let off = make { $0.modelWebSearchEnabled = false }
        #expect(off.chatTools == [.memory, .tasks, .vault, .skills])
    }

    @Test func toolsChosenBeforeTheFirstQuestionGoToTheChatItStarts() async {
        let mock = MockQuickService()
        let vm = make(service: mock) { $0.modelWebSearchEnabled = true }
        vm.openQuickAI()
        vm.toggleChatTool(.vault)
        vm.toggleChatTool(.web)
        #expect(vm.currentConversation == nil)
        #expect(vm.chatTools == [.memory, .tasks, .skills])

        await ask(vm, mock, "hello", deltas: [StreamDelta(text: "Hi.", finishReason: "stop")])
        #expect(vm.currentConversation?.enabledTools == [.memory, .tasks, .skills])
        #expect(vm.pendingChatTools == nil)

        // A new chat starts on the defaults again.
        vm.startNewConversation()
        #expect(vm.chatTools == [.memory, .tasks, .vault, .skills, .web])
    }

    @Test func toolsChosenOnTheOpenChatCarryIntoTheChatTheNextQuestionStarts() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock) { $0.newChatInterval = .always }
        await ask(vm, mock, "hello", deltas: [StreamDelta(text: "Hi.", finishReason: "stop")])
        let first = try #require(vm.currentConversation?.id)
        vm.toggleChatTool(.memory)

        await ask(vm, mock, "and now?", deltas: [StreamDelta(text: "Still here.", finishReason: "stop")])
        #expect(vm.currentConversation?.id != first, "the interval started a new chat")
        #expect(vm.currentConversation?.enabledTools?.contains(.memory) == false, "memory stays off")
        #expect(vm.chatTools.contains(.memory) == false)
    }

    @Test func togglingAToolOnAChatIsSavedWithIt() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "hello", deltas: [StreamDelta(text: "Hi.", finishReason: "stop")])
        vm.toggleChatTool(.memory)
        #expect(vm.currentConversation?.enabledTools?.contains(.memory) == false)
        let saved = try #require(vm.history.first { $0.id == vm.currentConversation?.id })
        #expect(saved.enabledTools?.contains(.memory) == false)
    }

    @Test func theServiceOffersOnlyTheChatsTools() throws {
        let (skills, root) = try TemporarySkills.make()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = QuickSettings()
        settings.modelWebSearchEnabled = true
        let vm = QuickViewModel(
            settings: settings,
            webSearchService: GatedWebSearchService(result: ""),
            vaultSearchService: FakeVault(outcome: .failure(VaultSearchError.empty))
        )
        vm.memoryService = FakeMemory()
        vm.skillLibrary = skills
        let provider = try #require(settings.providers.first { $0.kind == .openAICompatible })

        let all = try #require(vm.makeService(provider: provider, model: "deepseek-flash") as? OpenAICompatibleService)
        #expect(all.offeredToolNames == [
            "recall_memory", "recall_captures_today", "recall_tasks_today", "recall_open_tasks",
            "search_vault", "read_skill", "search_web",
        ])
        #expect(all.contextBudget == ContextBudget(contextWindow: ModelProfile.curated(forModelID: "deepseek-flash").contextWindow))

        vm.toggleChatTool(.vault)
        vm.toggleChatTool(.web)
        let fewer = try #require(vm.makeService(provider: provider, model: "deepseek-flash") as? OpenAICompatibleService)
        #expect(fewer.offeredToolNames == [
            "recall_memory", "recall_captures_today", "recall_tasks_today", "recall_open_tasks", "read_skill",
        ])

        // The Translator gets web search per the setting and no chat tools.
        let translator = try #require(vm.makeService(provider: provider, model: "deepseek-flash", chatTools: false) as? OpenAICompatibleService)
        #expect(translator.offeredToolNames == ["search_web"])
    }

    @Test func toolsOpensInTheCommandKPaletteOnTheEmptySurface() {
        let vm = make()
        vm.openQuickAI()
        vm.handleCommandK()
        #expect(vm.isActionPalettePresented)
        #expect(vm.paletteResultActions.contains(.tools), "Tools is there before the first answer")
        #expect(!vm.resultActions.contains(.tools), "no answer, no answer actions")

        vm.openActionPaletteSubmenu(.tools)
        #expect(vm.actionPaletteSubmenu == .tools)
        #expect(vm.paletteToolRows == ChatToolKind.allCases)
        #expect(vm.actionPaletteEntryCount == ChatToolKind.allCases.count)
        vm.actionQuery = "vau"
        #expect(vm.paletteToolRows == [.vault])

        // Escape goes back to the full list, then closes it.
        #expect(vm.handleEscapeKey())
        #expect(vm.isActionPalettePresented)
        #expect(vm.actionPaletteSubmenu == nil)
        #expect(vm.actionQuery.isEmpty)
        #expect(vm.handleEscapeKey())
        #expect(!vm.isActionPalettePresented)
    }

    @Test func optionCommandKOpensToolsDirectly() {
        let vm = make()
        vm.openQuickAI()
        #expect(vm.performShortcut(characters: "k", keyCode: 40, modifiers: [.command, .option]))
        #expect(vm.isActionPalettePresented)
        #expect(vm.actionPaletteSubmenu == .tools)
        #expect(vm.resultActionDetail(.tools) == "Memory, Tasks, Vault, Skills, Web search on")
    }

    @Test func answerActionKeysStayUniqueAndOffThePanelsOwnKeys() {
        let keys = ResultAction.allCases.map(\.defaultShortcut)
        #expect(Set(keys.map(\.keyCaps)).count == keys.count, "every answer action has its own key")
        // The panel consumes these before any answer action sees them.
        let reserved: [KeyShortcut] = [
            .command("k"), .command("c"), .commandShift("s"), .commandShift("d"), .commandShift("t"),
            QuickViewModel.recentChatsShortcut, QuickViewModel.transformChooserShortcut,
            QuickViewModel.transcriptCollapseShortcut,
        ]
        for action in [ResultAction.openSource, .captureToMemory, .tools] {
            #expect(!reserved.contains(action.defaultShortcut), "\(action.title) must not take a reserved key")
        }
        #expect(ResultAction.openSource.defaultShortcut.keyCaps == ["⌘", "O"])
        #expect(ResultAction.captureToMemory.defaultShortcut.keyCaps == ["⌥", "⌘", "M"])
        #expect(ResultAction.tools.defaultShortcut.keyCaps == ["⌥", "⌘", "K"])
    }

    // MARK: - Open Source

    @Test func openSourceOpensTheOneSourceThroughTheOpener() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "open-source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "dec-01.md")
        try "# Decision".write(to: note, atomically: true, encoding: .utf8)

        let mock = MockQuickService()
        let vm = make(service: mock)
        let opener = FakeFileOpener()
        vm.fileOpener = opener
        vm.sourceRoots = [folder]
        let line = ChatToolRecord(kind: .memory, summary: "Searched memory: 1 hit", sources: [
            ChatSource(title: "state/decisions/dec-01.md", day: "2026-09-03", path: note.path),
        ])
        await ask(vm, mock, "which deck", deltas: [
            StreamDelta(text: nil, finishReason: nil, toolRecord: line),
            StreamDelta(text: "The long deck.", finishReason: "stop"),
        ])

        #expect(vm.resultActions.contains(.openSource))
        #expect(vm.resultActionDetail(.openSource) == "state/decisions/dec-01.md")
        await vm.performResultAction(.openSource)
        #expect(await opener.opened.map(\.path) == [note.resolvingSymlinksInPath().path])
        #expect(vm.errorMessage == nil)
    }

    @Test func aSourceOutsideMemoryAndTheVaultIsNotOpened() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "open-source-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "dec-01.md")
        try "# Decision".write(to: note, atomically: true, encoding: .utf8)
        let jar = folder.appending(path: "Tool.jar")
        try "x".write(to: jar, atomically: true, encoding: .utf8)

        let vm = make()
        let opener = FakeFileOpener()
        vm.fileOpener = opener
        // The default roots are the memory and vault folders in the home
        // folder; a temp file is outside.
        await vm.openSource(ChatSource(title: "dec-01.md", path: note.path))
        #expect(vm.errorMessage == "dec-01.md is not a file on this Mac.")
        vm.sourceRoots = [folder]
        await vm.openSource(ChatSource(title: "Tool.jar", path: jar.path))
        #expect(vm.errorMessage == "Tool.jar is not a file on this Mac.")
        #expect(await opener.opened.isEmpty)
    }

    @Test func severalSourcesOpenTheSourcesList() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.fileOpener = FakeFileOpener()
        await ask(vm, mock, "which deck", deltas: [
            StreamDelta(text: nil, finishReason: nil, toolRecord: Self.memoryLine),
            StreamDelta(text: nil, finishReason: nil, toolRecord: Self.vaultLine),
            StreamDelta(text: "The long deck.", finishReason: "stop"),
        ])
        #expect(vm.resultActionDetail(.openSource) == "3 sources")
        await vm.performResultAction(.openSource)
        #expect(vm.isActionPalettePresented)
        #expect(vm.actionPaletteSubmenu == .sources)
        #expect(vm.paletteSourceRows.count == 3)
        vm.actionQuery = "acme"
        #expect(vm.paletteSourceRows.map(\.title) == ["Acme Launch status"])
    }

    @Test func aSourceThatIsNotALocalFileSaysSoAndOpensNothing() async {
        let vm = make()
        let opener = FakeFileOpener()
        vm.fileOpener = opener
        await vm.openSource(ChatSource(title: "Gone", day: nil, path: "/nonexistent/\(UUID().uuidString).md"))
        #expect(await opener.opened.isEmpty)
        #expect(vm.errorMessage == "Gone is not a file on this Mac.")
    }

    @Test func noOpenerOrNoPathMeansNoOpenSource() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "which deck", deltas: [
            StreamDelta(text: nil, finishReason: nil, toolRecord: Self.memoryLine),
            StreamDelta(text: "The long deck.", finishReason: "stop"),
        ])
        #expect(!vm.resultActions.contains(.openSource), "no opener on this Mac")
        vm.fileOpener = FakeFileOpener()
        #expect(vm.resultActions.contains(.openSource))

        let pathless = make(service: mock)
        pathless.fileOpener = FakeFileOpener()
        await ask(pathless, mock, "portfolio", deltas: [
            StreamDelta(text: nil, finishReason: nil, toolRecord: ChatToolRecord(
                kind: .vault, summary: "Searched vault · portfolio: 1 result",
                sources: [ChatSource(title: "Acme Launch")]
            )),
            StreamDelta(text: "One project.", finishReason: "stop"),
        ])
        #expect(pathless.conversationMessages.last?.sources.count == 1, "listed")
        #expect(!pathless.resultActions.contains(.openSource), "but nothing to open")
    }

    // MARK: - Capture to Memory

    @Test func captureSendsTheAnswerAndLeavesACheckmarkLine() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let memory = FakeMemory()
        vm.memoryCapture = memory
        await ask(vm, mock, "plan", deltas: [StreamDelta(text: "Ship on Friday.", finishReason: "stop")])

        #expect(vm.resultActions.contains(.captureToMemory))
        await vm.performResultAction(.captureToMemory)
        #expect(await memory.captured == ["Ship on Friday."])
        #expect(vm.composerConfirmation == "Captured")
        let answer = try #require(vm.conversationMessages.last)
        #expect(answer.tools == [ChatToolRecord(kind: .capture, summary: "Captured to memory")])
        #expect(!answer.tools[0].drawsAboveAnswer, "the checkmark sits under the answer")
        let saved = try #require(vm.history.first { $0.id == vm.currentConversation?.id })
        #expect(saved.messages.last?.tools.map(\.kind) == [.capture])

        // A second capture sends again but keeps one line.
        await vm.performResultAction(.captureToMemory)
        #expect(await memory.captured.count == 2)
        #expect(vm.conversationMessages.last?.tools.count == 1)
    }

    @Test func aFailedCaptureSaysSoAndLeavesNoLine() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let memory = FakeMemory()
        await memory.setCaptureError(RecallError.timedOut)
        vm.memoryCapture = memory
        await ask(vm, mock, "plan", deltas: [StreamDelta(text: "Ship on Friday.", finishReason: "stop")])
        await vm.performResultAction(.captureToMemory)
        #expect(vm.errorMessage == "Capture to Memory failed: recall did not answer in time")
        #expect(vm.conversationMessages.last?.tools.isEmpty == true)
    }

    @Test func captureIsNeverOfferedWithoutRecallOrWithoutAnAnswer() async {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.memoryCapture = FakeMemory()
        vm.openQuickAI()
        #expect(!vm.paletteResultActions.contains(.captureToMemory), "nothing to capture yet")
        let bare = make(service: mock)
        await ask(bare, mock, "plan", deltas: [StreamDelta(text: "Ship.", finishReason: "stop")])
        #expect(!bare.resultActions.contains(.captureToMemory))
    }
}

/// Streams one tool line, then fails, as a provider that drops mid-answer.
private struct LineThenFailService: QuickService {
    let record: ChatToolRecord

    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(StreamDelta(text: nil, finishReason: nil, toolRecord: record))
            continuation.finish(throwing: QuickServiceError.serverError("HTTP 500"))
        }
    }

    func healthCheck() async throws -> Bool { true }
}

/// A tool line at once, then the answer after `delay`: a model that works
/// through its tools before it writes.
private struct ToolThenSlowAnswerService: QuickService {
    let record: ChatToolRecord
    let delay: Duration

    func send(messages: [QuickMessage]) -> AsyncThrowingStream<StreamDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(StreamDelta(text: nil, finishReason: nil, toolRecord: record))
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    continuation.finish()
                    return
                }
                continuation.yield(StreamDelta(text: "Answer after tools.", finishReason: "stop"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func healthCheck() async throws -> Bool { true }
}

/// Web search that answers at once.
private struct ImmediateWebSearch: WebSearchServicing {
    func search(_ query: String) async throws -> String {
        "## [1] Acme Launch\nURL: https://example.com/acme\nSnippet: Status."
    }
}
