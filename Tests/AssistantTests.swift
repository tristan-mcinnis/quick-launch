// AssistantTests — plan Phase D (docs/ai-chat-plan-20260911.md section 6):
// a saved prompt with instructions and no command is an assistant. Its
// alias alone, ⌘K › Change Assistant, or its hotkey starts or switches the
// Quick AI chat to it; its instructions and context skills ride every
// request as the system message, its tools become the chat's tool set, and
// its provider and model apply. Text after the alias keeps the transform.

import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

// MARK: - Decoding and seeding

@Suite("Assistants: model and settings")
struct AssistantModelTests {

    @Test func aSavedPromptWrittenBeforeAssistantsDecodesAsAPlainTransform() throws {
        let legacy = #"{"id":"3D43B22A-EC62-4A78-92AE-99C30191A404","alias":"old","prompt":"Do this","outputBehavior":"replaceSelection"}"#
        let decoded = try JSONDecoder().decode(SavedPrompt.self, from: Data(legacy.utf8))
        #expect(decoded.systemPrompt == nil)
        #expect(decoded.enabledTools == nil)
        #expect(decoded.contextRefs.isEmpty)
        #expect(!decoded.isAssistant)
        #expect(decoded.outputBehavior == .replaceSelection)
    }

    @Test func assistantFieldsRoundTrip() throws {
        let assistant = SavedPrompt(
            name: "Researcher",
            alias: "res",
            prompt: "",
            providerID: InferenceProvider.deepSeekID,
            model: "deepseek-v4-pro",
            systemPrompt: "Cite sources.",
            enabledTools: [.vault, .memory],
            contextRefs: ["costing", "email-ops"]
        )
        let back = try JSONDecoder().decode(SavedPrompt.self, from: JSONEncoder().encode(assistant))
        #expect(back == assistant)
        #expect(back.isAssistant)
        // An empty tool set is a choice (no tools), not the defaults.
        var none = assistant
        none.enabledTools = []
        let noneBack = try JSONDecoder().decode(SavedPrompt.self, from: JSONEncoder().encode(none))
        #expect(noneBack.enabledTools == [])
    }

    @Test func onlyInstructionsWithoutACommandMakeAnAssistant() {
        #expect(!SavedPrompt(alias: "a", prompt: "p").isAssistant)
        #expect(!SavedPrompt(alias: "a", prompt: "p", systemPrompt: "  \n ").isAssistant)
        #expect(!SavedPrompt(alias: "a", prompt: "p", commandExecutable: "recall", systemPrompt: "Rules").isAssistant)
        #expect(SavedPrompt(alias: "a", prompt: "p", commandExecutable: "", systemPrompt: "Rules").isAssistant)
        #expect(SavedPrompt(alias: "a", prompt: "p", systemPrompt: "Rules").isAssistant)
    }

    @Test func aChatWrittenBeforeAssistantsHasNone() throws {
        let chat = QuickConversation(providerID: InferenceProvider.deepSeekID, model: "m")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as? [String: Any])
        json.removeValue(forKey: "assistantID")
        let old = try JSONDecoder().decode(
            QuickConversation.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(old.assistantID == nil)

        let id = UUID()
        let assisted = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "m",
            enabledTools: [],
            assistantID: id
        )
        let back = try JSONDecoder().decode(QuickConversation.self, from: JSONEncoder().encode(assisted))
        #expect(back.assistantID == id)
        #expect(back.enabledTools == [])
    }

    @Test func aFreshInstallHasTheTwoDefaultAssistantsAndNoMore() {
        let assistants = QuickSettings().savedPrompts.filter(\.isAssistant)
        #expect(assistants.map(\.name) == ["Vault researcher", "STE editor"])
        let vault = assistants.first
        #expect(vault?.alias == "vault")
        #expect(vault?.enabledTools == [.vault, .memory])
        #expect(vault?.systemPrompt?.contains("Cite the source") == true)
        let ste = assistants.last
        #expect(ste?.alias == "ste")
        #expect(ste?.enabledTools == [], "the STE editor offers no tools")
        #expect(ste?.systemPrompt?.contains("ASD-STE100") == true)
        // Neither default pins a model or grabs a global hotkey.
        #expect(assistants.allSatisfy { $0.providerID == nil && $0.model == nil && $0.hotkey == nil })
    }

    /// A settings blob from version 24 with its own saved prompts.
    private func v24Blob(prompts: [SavedPrompt], version: Int = 24) throws -> Data {
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(QuickSettings())) as? [String: Any]
        )
        json["configurationVersion"] = version
        json["savedPrompts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prompts))
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test func version25AddsTheAssistantsOnceAndNeverTwice() throws {
        let mine = [SavedPrompt(alias: "translate", prompt: "Translate:\n\n{selection}")]
        let upgraded = try JSONDecoder().decode(QuickSettings.self, from: v24Blob(prompts: mine))
        #expect(upgraded.configurationVersion == 25)
        #expect(upgraded.savedPrompts.map(\.alias).filter { ["vault", "ste"].contains($0) } == ["vault", "ste"])

        // Decoding the upgraded blob again adds nothing.
        let again = try JSONDecoder().decode(QuickSettings.self, from: JSONEncoder().encode(upgraded))
        #expect(again.savedPrompts.count == upgraded.savedPrompts.count)
        #expect(again.savedPrompts.filter { $0.alias == "vault" }.count == 1)
    }

    @Test func version25KeepsTheUsersOwnAliasAndADeletedAssistantStaysDeleted() throws {
        let ownVault = SavedPrompt(alias: "vault", prompt: "", commandExecutable: "recall", commandArguments: ["search", "{input}"])
        let upgraded = try JSONDecoder().decode(QuickSettings.self, from: v24Blob(prompts: [ownVault]))
        let vaults = upgraded.savedPrompts.filter { $0.alias == "vault" }
        #expect(vaults.count == 1)
        #expect(vaults.first?.commandExecutable == "recall", "the user's /vault command is kept")
        #expect(upgraded.savedPrompts.contains { $0.alias == "ste" })

        // On version 25, the user removed both assistants: they stay gone.
        let deleted = try JSONDecoder().decode(
            QuickSettings.self,
            from: v24Blob(prompts: [SavedPrompt(alias: "tldr", prompt: "TL;DR")], version: 25)
        )
        #expect(!deleted.savedPrompts.contains { $0.isAssistant })
    }

    @Test func theSystemMessageIsTheInstructionsThenTheSkills() {
        #expect(AssistantContext.systemMessage(instructions: "  ", skills: []) == nil)
        #expect(AssistantContext.systemMessage(instructions: "Rules.", skills: []) == "Rules.")
        let message = AssistantContext.systemMessage(
            instructions: "Rules.",
            skills: [AssistantSkill(name: "costing", text: "# costing\nBody\n")]
        )
        #expect(message?.hasPrefix("Rules.\n\nContext skills for this chat.") == true)
        #expect(message?.hasSuffix("<skill name=\"costing\">\n# costing\nBody\n</skill>") == true)
    }

    @Test func loadingSkillsSkipsUnlistedNamesAndRepeats() async throws {
        let (library, root) = try AssistantFixtures.skillLibrary(["costing": "# costing"])
        defer { try? FileManager.default.removeItem(at: root) }
        let skills = await AssistantContext.loadSkills(
            ["costing", "../costing", "/etc", "missing", "costing"],
            library: library
        )
        #expect(skills == [AssistantSkill(name: "costing", text: "# costing")])
    }
}

// MARK: - Resolution vs transform

@Suite("Assistants: resolution")
struct AssistantResolutionTests {
    private let prompts: [SavedPrompt] = [
        SavedPrompt(alias: "grammar", prompt: "Fix:\n\n{selection}"),
        SavedPrompt(alias: "vault", prompt: "Find:\n\n{selection}", systemPrompt: "Cite."),
        SavedPrompt(alias: "bare", prompt: "", systemPrompt: "Be brief."),
        SavedPrompt(alias: "run", prompt: "", commandExecutable: "recall", systemPrompt: "Ignored."),
    ]

    @Test func theAliasAloneNamesTheAssistant() {
        #expect(SavedPromptResolver.assistant(input: "/vault", prefix: "/", savedPrompts: prompts)?.alias == "vault")
        // Tab completion leaves a trailing space; it is still the alias alone.
        #expect(SavedPromptResolver.assistant(input: "/vault ", prefix: "/", savedPrompts: prompts)?.alias == "vault")
    }

    @Test func textAfterTheAliasIsATransform() {
        #expect(SavedPromptResolver.assistant(input: "/vault what is x", prefix: "/", savedPrompts: prompts) == nil)
        let transform = SavedPromptResolver.resolveAction(input: "/vault what is x", prefix: "/", savedPrompts: prompts)
        #expect(transform?.prompt == "Find:\n\nwhat is x")
        // An assistant with an empty transform prompt sends the text alone.
        let bare = SavedPromptResolver.resolveAction(input: "/bare hello there", prefix: "/", savedPrompts: prompts)
        #expect(bare?.prompt == "hello there")
    }

    @Test func plainPromptsCommandsAndUnknownAliasesAreNotAssistants() {
        #expect(SavedPromptResolver.assistant(input: "/grammar", prefix: "/", savedPrompts: prompts) == nil)
        #expect(SavedPromptResolver.assistant(input: "/run", prefix: "/", savedPrompts: prompts) == nil)
        #expect(SavedPromptResolver.assistant(input: "/nope", prefix: "/", savedPrompts: prompts) == nil)
        #expect(SavedPromptResolver.assistant(input: "vault", prefix: "/", savedPrompts: prompts) == nil)
        #expect(SavedPromptResolver.assistant(input: "/vault", prefix: "", savedPrompts: prompts) == nil)
    }
}

// MARK: - Picking and requests

@Suite("Assistants: Quick AI", .serialized)
@MainActor
struct AssistantQuickAITests {

    private func make(
        service: MockQuickService = MockQuickService(),
        configure: (inout QuickSettings) -> Void = { _ in }
    ) -> QuickViewModel {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        configure(&settings)
        return QuickViewModel(settings: settings, service: service, pasteboard: FakePasteboard())
    }

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, reply: String = "Done.") async {
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    private func vault(_ vm: QuickViewModel) throws -> SavedPrompt {
        try #require(vm.settings.savedPrompts.first { $0.alias == "vault" })
    }

    private func ste(_ vm: QuickViewModel) throws -> SavedPrompt {
        try #require(vm.settings.savedPrompts.first { $0.alias == "ste" })
    }

    @Test func theAliasAloneStartsAnAssistantChatAndSendsNothing() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let vault = try vault(vm)
        vm.input = "/vault"
        await vm.submitResolvingFuzzyAlias()

        #expect(await mock.sendCallCount == 0, "picking sends nothing")
        #expect(vm.isQuickAIPresented)
        #expect(vm.input.isEmpty)
        #expect(vm.activeAssistant?.id == vault.id)
        #expect(vm.currentConversation?.assistantID == vault.id)
        #expect(vm.currentConversation?.enabledTools == [.vault, .memory], "its tools are the chat's toggles")
        #expect(vm.currentConversation?.messages.isEmpty == true)
        #expect(vm.errorMessage == nil)
    }

    @Test func aFuzzyAliasCompletesToTheAssistant() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.input = "/vau"
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.activeAssistant?.alias == "vault")
        #expect(await mock.sendCallCount == 0)
    }

    @Test func theAssistantsInstructionsAreTheSystemMessageOfEveryRequest() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let vault = try vault(vm)
        vm.input = "/vault"
        await vm.submit()
        await ask(vm, mock, "What did we decide about pricing?")

        let messages = await mock.lastMessages
        #expect(messages.count == 2)
        #expect(messages.first?.role == .system)
        #expect(messages.first?.content == vault.systemPrompt)
        #expect(messages.last?.role == .user)
        #expect(messages.last?.content == "What did we decide about pricing?")

        // The saved chat keeps the turns only.
        #expect(vm.currentConversation?.messages.map(\.role) == [.user, .assistant])
        #expect(vm.currentConversation?.enabledTools == [.vault, .memory])

        // A follow-up carries it again, in front of the whole thread.
        await ask(vm, mock, "And for Q3?")
        let followUp = await mock.lastMessages
        #expect(followUp.map(\.role) == [.system, .user, .assistant, .user])
    }

    @Test func textAfterTheAliasKeepsTheTransformAndNoAssistant() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        await ask(vm, mock, "/vault pricing")
        let messages = await mock.lastMessages
        #expect(messages.map(\.role) == [.user], "no system message on a transform")
        #expect(messages.last?.content.hasPrefix("Find what my vault and memory say") == true)
        #expect(messages.last?.content.hasSuffix("pricing") == true)
        #expect(vm.currentConversation?.assistantID == nil)
        #expect(vm.activeAssistant == nil)
    }

    @Test func contextSkillsAreReadOnceAndSkippedWhenUnlisted() async throws {
        let (library, root) = try AssistantFixtures.skillLibrary(["costing": "# costing\nRates v1"])
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = MockQuickService()
        let assistant = SavedPrompt(
            name: "Desk",
            alias: "desk",
            prompt: "",
            systemPrompt: "Answer as the desk.",
            contextRefs: ["costing", "../../etc", "missing"]
        )
        let vm = make(service: mock) { $0.savedPrompts.append(assistant) }
        vm.skillLibrary = library
        vm.input = "/desk"
        await vm.submit()
        await ask(vm, mock, "Quote a day rate")

        let first = try #require(await mock.lastMessages.first)
        #expect(first.role == .system)
        #expect(first.content.hasPrefix("Answer as the desk."))
        #expect(first.content.contains("<skill name=\"costing\">\n# costing\nRates v1\n</skill>"))
        #expect(!first.content.contains("missing"))
        #expect(!first.content.contains("etc"))

        // Loaded once: an edit to the file does not reach this chat.
        try "# costing\nRates v2".write(
            to: root.appending(path: "costing/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        await ask(vm, mock, "And a half day?")
        let second = try #require(await mock.lastMessages.first)
        #expect(second.content.contains("Rates v1"))
        #expect(!second.content.contains("Rates v2"))

        // A new chat with the same assistant reads the skill again.
        vm.startNewConversation()
        vm.input = "/desk"
        await vm.submit()
        await ask(vm, mock, "Rates now?")
        let fresh = try #require(await mock.lastMessages.first)
        #expect(fresh.content.contains("Rates v2"))
    }

    @Test func aPinnedProviderAndModelApplyToTheChat() async throws {
        let assistant = SavedPrompt(
            name: "Pro",
            alias: "pro",
            prompt: "",
            providerID: InferenceProvider.deepSeekID,
            model: "deepseek-v4-pro",
            systemPrompt: "Think hard."
        )
        let vm = make { $0.savedPrompts.append(assistant) }
        vm.input = "/pro"
        await vm.submit()
        #expect(vm.activeModelID == "deepseek-v4-pro")
        #expect(vm.activeProvider?.id == InferenceProvider.deepSeekID)
        #expect(vm.currentConversation?.model == "deepseek-v4-pro")
        #expect(vm.currentConversation?.providerID == InferenceProvider.deepSeekID)
    }

    @Test func changeAssistantSwitchesTheOpenChatAndBackToPlain() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.openQuickAI()
        // On the empty surface ⌘K offers Change Assistant, before any answer.
        #expect(vm.paletteResultActions.contains(.changeAssistant))
        await ask(vm, mock, "Hello")
        let chatID = try #require(vm.currentConversation?.id)
        #expect(vm.resultActions.contains(.changeAssistant))

        await vm.performResultAction(.changeAssistant)
        #expect(vm.isAssistantChooserPresented)
        #expect(vm.topLayer == .assistantChooser)
        #expect(vm.quickAIComposerAction.label == QuickViewModel.assistantChooserConfirmTitle)
        #expect(vm.assistantChooserOptions.map(\.title) == ["No Assistant", "Vault researcher", "STE editor"])
        #expect(vm.assistantChooserIndex == 0, "a plain chat starts on No Assistant")

        vm.moveAssistantChooserSelection(2)
        await vm.submitResolvingFuzzyAlias()
        let ste = try ste(vm)
        #expect(!vm.isAssistantChooserPresented)
        #expect(vm.currentConversation?.id == chatID, "the open chat switches; no new chat")
        #expect(vm.activeAssistant?.id == ste.id)
        #expect(vm.currentConversation?.enabledTools == [])
        await ask(vm, mock, "Rewrite: the valve should be opened slowly")
        #expect(await mock.lastMessages.first?.content == ste.systemPrompt)

        // Back to a plain chat: no system message, default tools.
        vm.openAssistantChooser()
        #expect(vm.assistantChooserIndex == 2, "the chooser opens on the chat's assistant")
        vm.moveAssistantChooserSelection(1)
        #expect(vm.assistantChooserIndex == 0)
        vm.runAssistantChooserSelection()
        #expect(vm.activeAssistant == nil)
        #expect(vm.currentConversation?.enabledTools == nil)
        await ask(vm, mock, "Thanks")
        #expect(await mock.lastMessages.first?.role == .user)
    }

    @Test func escapeClosesTheChooserFirst() async {
        let vm = make()
        vm.openQuickAI()
        vm.openAssistantChooser()
        #expect(vm.handleEscapeKey())
        #expect(!vm.isAssistantChooserPresented)
        #expect(vm.isQuickAIPresented)
    }

    @Test func theHotkeyAndPaletteRowPickWithoutASelection() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let vault = try vault(vm)
        // `perform(action:)` is what the global hotkey and the ⌘K row run.
        await vm.perform(action: vault)
        #expect(vm.errorMessage == nil, "an assistant needs no selected text")
        #expect(vm.activeAssistant?.id == vault.id)
        #expect(vm.isQuickAIPresented)
        #expect(await mock.sendCallCount == 0)
    }

    @Test func aPickedAssistantSurvivesTheNewChatInterval() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock) { $0.newChatInterval = .always }
        let vault = try vault(vm)
        vm.input = "/vault"
        await vm.submit()
        await ask(vm, mock, "First question")
        let firstChat = try #require(vm.currentConversation?.id)
        #expect(vm.currentConversation?.assistantID == vault.id)
        #expect(await mock.lastMessages.first?.role == .system)
        // With a new chat every time, the next question starts one, and the
        // assistant the header names goes along to it.
        await ask(vm, mock, "Second question")
        #expect(vm.currentConversation?.id != firstChat, "the interval started a new chat")
        #expect(vm.currentConversation?.assistantID == vault.id)
        #expect(vm.currentConversation?.enabledTools == [.vault, .memory])
        #expect(vm.activeAssistant?.id == vault.id)
        let messages = await mock.lastMessages
        #expect(messages.map(\.role) == [.system, .user])
        #expect(messages.first?.content == vault.systemPrompt)
    }

    @Test func aStaleAssistantChatCarriesItsSkillsToTheNextChat() async throws {
        let (library, root) = try AssistantFixtures.skillLibrary(["costing": "# costing\nRates v1"])
        defer { try? FileManager.default.removeItem(at: root) }
        let mock = MockQuickService()
        let assistant = SavedPrompt(
            name: "Desk",
            alias: "desk",
            prompt: "",
            systemPrompt: "Answer as the desk.",
            enabledTools: [.skills],
            contextRefs: ["costing"]
        )
        let vm = make(service: mock) {
            $0.savedPrompts.append(assistant)
            $0.newChatInterval = .always
        }
        vm.skillLibrary = library
        vm.input = "/desk"
        await vm.submit()
        await ask(vm, mock, "Quote a day rate")
        try "# costing\nRates v2".write(
            to: root.appending(path: "costing/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        // The new chat is a new chat: it reads its skills once, afresh.
        await ask(vm, mock, "And now?")
        let system = try #require(await mock.lastMessages.first)
        #expect(system.role == .system)
        #expect(system.content.hasPrefix("Answer as the desk."))
        #expect(system.content.contains("Rates v2"))
        #expect(vm.currentConversation?.enabledTools == [.skills])
    }

    @Test func aTransformInAJustPickedAssistantChatStartsAPlainChat() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let vault = try vault(vm)
        vm.input = "/vault"
        await vm.submit()
        let pickedChat = try #require(vm.currentConversation?.id)
        #expect(vm.currentConversation?.assistantID == vault.id)

        await ask(vm, mock, "/ste the valve should be opened")
        let messages = await mock.lastMessages
        #expect(messages.map(\.role) == [.user], "a transform carries no assistant")
        #expect(messages.last?.content.hasPrefix("Rewrite the following text in ASD-STE100") == true)
        #expect(vm.currentConversation?.id != pickedChat, "the transform runs in a chat of its own")
        #expect(vm.currentConversation?.assistantID == nil)
        #expect(vm.currentConversation?.enabledTools == nil)
        #expect(vm.activeAssistant == nil)
    }

    @Test func aTransformAfterAnAssistantAnswerStartsAPlainChat() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.input = "/vault"
        await vm.submit()
        await ask(vm, mock, "What is x?")
        let assistantChat = try #require(vm.currentConversation?.id)
        await ask(vm, mock, "/ste the valve should be opened")
        #expect(await mock.lastMessages.map(\.role) == [.user])
        #expect(vm.currentConversation?.id != assistantChat)
        #expect(vm.currentConversation?.assistantID == nil)
    }

    @Test func theAliasAloneRunsThePromptOnSelectedText() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.launchSelection = QuickViewModel.LaunchSelection(text: "The valve should be opened slowly.", appName: "Notes")
        await ask(vm, mock, "/ste")
        #expect(await mock.sendCallCount == 1, "a selection makes the alias a transform")
        let messages = await mock.lastMessages
        #expect(messages.map(\.role) == [.user])
        #expect(messages.last?.content.hasPrefix("Rewrite the following text in ASD-STE100") == true)
        #expect(messages.last?.content.hasSuffix("The valve should be opened slowly.") == true)
        #expect(vm.activeAssistant == nil)
        #expect(vm.currentConversation?.assistantID == nil)
    }

    @Test func theHotkeyRunsThePromptOnASelection() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        let ste = try ste(vm)
        await mock.setResponses([StreamDelta(text: "Open the valve slowly.", finishReason: "stop")])
        // The hotkey captured the selection before the overlay opened.
        vm.launchSelection = QuickViewModel.LaunchSelection(text: "The valve should be opened slowly.", appName: "Notes")
        await vm.perform(action: ste)
        #expect(await mock.sendCallCount == 1)
        let messages = await mock.lastMessages
        #expect(messages.map(\.role) == [.user])
        #expect(messages.last?.content.hasSuffix("The valve should be opened slowly.") == true)
        #expect(vm.activeAssistant == nil)
        #expect(vm.errorMessage == nil)
    }

    @Test func withNoSkillLibraryTheInstructionsGoAlone() async throws {
        let mock = MockQuickService()
        let assistant = SavedPrompt(
            name: "Desk",
            alias: "desk",
            prompt: "",
            systemPrompt: "Answer as the desk.",
            contextRefs: ["costing"]
        )
        let vm = make(service: mock) { $0.savedPrompts.append(assistant) }
        #expect(vm.skillLibrary == nil, "tests and proofs have no skill library")
        vm.input = "/desk"
        await vm.submit()
        await ask(vm, mock, "Hello")
        #expect(await mock.lastMessages.first?.content == "Answer as the desk.")
    }

    @Test func aDeletedAssistantLeavesAPlainChat() async throws {
        let mock = MockQuickService()
        let vm = make(service: mock)
        vm.input = "/ste"
        await vm.submit()
        vm.settings.savedPrompts.removeAll { $0.alias == "ste" }
        #expect(vm.activeAssistant == nil)
        await ask(vm, mock, "Hello")
        #expect(await mock.lastMessages.first?.role == .user)
    }
}

// MARK: - Services fold the system message in

@Suite("Assistants: services")
struct AssistantServiceTests {

    @Test func theWireCarriesOneSystemMessageWithTheAssistantFirst() throws {
        let service = OpenAICompatibleService(
            baseURL: URL(string: "https://example.com/v1")!,
            modelName: "m",
            systemPrompt: "Base rules."
        )
        let request = try service.buildRequest(messages: [
            QuickMessage(role: .system, content: "Assistant rules."),
            QuickMessage(role: .user, content: "Hi"),
        ])
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "Assistant rules.\n\nBase rules.")
        #expect(messages[1]["role"] as? String == "user")
    }

    @Test func aCommandProviderGetsItInItsSystemPromptArgumentOrOnStdin() {
        let messages = [
            QuickMessage(role: .system, content: "Assistant rules."),
            QuickMessage(role: .user, content: "Hi"),
        ]
        let withPlaceholder = CommandQuickService.invocation(
            arguments: ["-p", "--system-prompt", "{{systemPrompt}}"],
            model: "m",
            systemPrompt: "Base rules.",
            messages: messages
        )
        #expect(withPlaceholder.arguments == ["-p", "--system-prompt", "Assistant rules.\n\nBase rules."])
        #expect(withPlaceholder.stdin == "Hi")

        let withoutPlaceholder = CommandQuickService.invocation(
            arguments: ["-p"],
            model: "m",
            systemPrompt: "Base rules.",
            messages: messages
        )
        #expect(withoutPlaceholder.arguments == ["-p"])
        #expect(withoutPlaceholder.stdin == "Assistant rules.\n\nHi")

        // No system message: exactly what the service sent before.
        let plain = CommandQuickService.invocation(
            arguments: ["{{systemPrompt}}"],
            model: "m",
            systemPrompt: "Base rules.",
            messages: [QuickMessage(role: .user, content: "Hi")]
        )
        #expect(plain.arguments == ["Base rules."])
        #expect(plain.stdin == "Hi")
    }
}

// MARK: - Settings editor round trip

@Suite("Assistants: editor", .serialized)
@MainActor
struct AssistantEditorTests {

    @Test func theEditorFieldsMakeAnAssistantThatSurvivesSaveAndLoad() throws {
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
        let id = try #require(vm.settings.savedPrompts.first { $0.alias == "explain" }?.id)
        let editor = SavedPromptsEditor(viewModel: vm)

        editor.bindingForInstructions(id).wrappedValue = "Explain like a patient teacher."
        #expect(editor.bindingForToolsUseDefaults(id).wrappedValue, "starts on the chat defaults")
        editor.bindingForToolsUseDefaults(id).wrappedValue = false
        #expect(editor.bindingForTool(.web, id).wrappedValue, "Choose starts with every tool on")
        editor.bindingForTool(.web, id).wrappedValue = false
        editor.bindingForTool(.vault, id).wrappedValue = false
        editor.addContextRef("costing", to: id)
        editor.addContextRef("costing", to: id)
        editor.addContextRef("email-ops", to: id)
        editor.removeContextRef("email-ops", from: id)

        let edited = try #require(vm.settings.savedPrompts.first { $0.id == id })
        #expect(edited.isAssistant)
        #expect(edited.systemPrompt == "Explain like a patient teacher.")
        #expect(edited.enabledTools == [.memory, .skills])
        #expect(edited.contextRefs == ["costing"])

        // What the editor saved is what the next launch reads.
        let reloaded = try JSONDecoder().decode(QuickSettings.self, from: JSONEncoder().encode(vm.settings))
        #expect(reloaded.savedPrompts.first { $0.id == id } == edited)

        // Chat defaults again, and blank instructions: a transform again.
        editor.bindingForToolsUseDefaults(id).wrappedValue = true
        editor.bindingForInstructions(id).wrappedValue = "   "
        let cleared = try #require(vm.settings.savedPrompts.first { $0.id == id })
        #expect(cleared.enabledTools == nil)
        #expect(cleared.systemPrompt == nil)
        #expect(!cleared.isAssistant)
    }
}

enum AssistantFixtures {
    /// A temporary skills folder: one folder per entry, each with a SKILL.md.
    static func skillLibrary(_ skills: [String: String]) throws -> (SkillLibrary, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "assistant-skills-\(UUID().uuidString)", directoryHint: .isDirectory)
        for (name, text) in skills {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: folder.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        return (SkillLibrary(root: root), root)
    }
}
