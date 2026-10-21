import AppKit
import Foundation
import HouseDesign
import SwiftUI
import Testing
@testable import QuickLaunch

/// One engine, two surfaces: Quick AI keeps the direct overlay instruction,
/// AI Chat gets its own conversational default. These tests cover the stored
/// defaults, the migration from the one-prompt era, independent edits, the
/// wire text each surface sends, and that a saved assistant and a grounding
/// directive are still composed as before.
@Suite("Prompt surface instructions", .serialized)
@MainActor
struct PromptSurfaceInstructionTests {

    private func decode(_ json: String) throws -> QuickSettings {
        try JSONDecoder().decode(QuickSettings.self, from: Data(json.utf8))
    }

    /// An old blob with one prompt, as the previous build wrote it.
    private func oldBlob(systemPrompt: String?) throws -> QuickSettings {
        var json: [String: Any] = ["configurationVersion": 27]
        if let systemPrompt { json["systemPrompt"] = systemPrompt }
        return try JSONDecoder().decode(
            QuickSettings.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    private func wirePrompt(
        of vm: QuickViewModel,
        settings: QuickSettings,
        grounded: Bool = false
    ) throws -> String {
        let provider = try #require(
            settings.providers.first { $0.kind == .openAICompatible }
        )
        let service = try #require(
            vm.makeService(
                provider: provider,
                model: InferenceProvider.deepSeekDefaultModel,
                grounded: grounded
            ) as? OpenAICompatibleService
        )
        return service.systemPrompt
    }

    private func chatWindowDefaults() -> UserDefaults {
        let suite = "PromptSurfaceInstructionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Budget reserve

    /// A 48,000-character window, a long chat instruction and a one-character
    /// quick instruction. A document of `characters` then sits between the
    /// share each prompt would leave, so the surface in use is visible in the
    /// result.
    private func budgetSettings(chatPromptLength: Int) -> QuickSettings {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        for index in settings.providers.indices {
            settings.providers[index].selectedModel = "small-test-model"
        }
        settings.systemPrompt = "q"
        settings.chatSystemPrompt = String(repeating: "c", count: chatPromptLength)
        return settings
    }

    private func budgetContent(characters: Int) -> AttachmentContent {
        let text = String(repeating: "a", count: characters)
        let name = "Between.txt"
        let kind = ChatAttachmentKind.text
        return AttachmentContent(
            ref: ChatAttachmentRef(
                kind: kind,
                name: name,
                byteCount: text.utf8.count,
                characterCount: text.count,
                contentHash: AttachmentExtractor.sha256(Data((name + text).utf8)),
                extractorVersion: 1,
                path: "/tmp/quick-launch-prompt-surface/\(name)"
            ),
            text: text,
            kindLabel: kind.displayName
        )
    }

    private static func budgetFileURL() -> URL {
        URL(fileURLWithPath: "/tmp/quick-launch-prompt-surface/Between.txt")
    }

    private func addBudgetAttachment(
        to vm: QuickViewModel,
        extractor: FakeAttachmentExtractor,
        characters: Int
    ) async {
        await extractor.set(
            .content(budgetContent(characters: characters)),
            for: "Between.txt"
        )
        vm.openQuickAI()
        vm.attachmentTray.add(.file(Self.budgetFileURL()))
        await vm.attachmentTray.waitForDrop()
        await vm.attachmentTray.waitUntilRead()
    }

    private func makeBudgetChat(
        characters: Int
    ) async -> (
        vm: QuickViewModel,
        note: String?,
        service: MockQuickService,
        window: AIChatWindowModel
    ) {
        let settings = budgetSettings(chatPromptLength: 4_000)
        let extractor = FakeAttachmentExtractor()
        let service = MockQuickService()
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            attachmentExtractor: extractor
        )
        let window = AIChatWindowModel(chat: vm, defaults: chatWindowDefaults())
        await addBudgetAttachment(to: vm, extractor: extractor, characters: characters)
        return (vm, vm.attachmentRoutingLine, service, window)
    }

    // MARK: - Defaults

    @Test func theTwoSurfacesStartOnDifferentDefaults() {
        let settings = QuickSettings()
        #expect(settings.systemPrompt == QuickSettings.defaultSystemPrompt)
        #expect(settings.chatSystemPrompt == QuickSettings.defaultChatSystemPrompt)
        #expect(settings.systemPrompt != settings.chatSystemPrompt)

        // Quick AI stays a direct result.
        #expect(settings.systemPrompt.contains("Return only the result"))
        #expect(settings.systemPrompt.contains("Spotlight-style action overlay"))
        // Chat may explain, and no longer carries the result-only rule.
        #expect(!settings.chatSystemPrompt.contains("Return only the result"))
        #expect(!settings.chatSystemPrompt.contains("Spotlight-style action overlay"))
        #expect(settings.chatSystemPrompt.contains("explanation"))

        #expect(settings.surfaceSystemPrompt(forChat: false) == settings.systemPrompt)
        #expect(settings.surfaceSystemPrompt(forChat: true) == settings.chatSystemPrompt)
    }

    // MARK: - Migration from one prompt to two

    @Test func aChangedInstructionFromTheOnePromptEraCarriesIntoChat() throws {
        let custom = "Answer in British English. Never use bullet points."
        let settings = try oldBlob(systemPrompt: custom)
        #expect(settings.systemPrompt == custom, "Quick AI keeps the user's words")
        #expect(
            settings.chatSystemPrompt == custom,
            "an explicit instruction is not silently replaced by the new chat default"
        )
        #expect(settings.configurationVersion == 28)
    }

    @Test func anEmptyInstructionFromTheOnePromptEraAlsoCarries() throws {
        let settings = try oldBlob(systemPrompt: "")
        #expect(settings.systemPrompt.isEmpty)
        #expect(settings.chatSystemPrompt.isEmpty, "clearing the instruction was a choice")
    }

    @Test func theUntouchedStockPromptLeavesChatOnItsNewDefault() throws {
        let stock = try oldBlob(systemPrompt: QuickSettings.defaultSystemPrompt)
        #expect(stock.chatSystemPrompt == QuickSettings.defaultChatSystemPrompt)

        // Surrounding whitespace does not turn the stock text into an edit.
        let spaced = try oldBlob(systemPrompt: "\n" + QuickSettings.defaultSystemPrompt + "\n")
        #expect(spaced.chatSystemPrompt == QuickSettings.defaultChatSystemPrompt)
        #expect(QuickSettings.isStockQuickAIPrompt(QuickSettings.defaultSystemPrompt))
        #expect(!QuickSettings.isStockQuickAIPrompt("Return only the result."))
    }

    @Test func anOldBlobWithNoPromptAtAllGetsBothDefaults() throws {
        let settings = try oldBlob(systemPrompt: nil)
        #expect(settings.systemPrompt == QuickSettings.defaultSystemPrompt)
        #expect(settings.chatSystemPrompt == QuickSettings.defaultChatSystemPrompt)
    }

    // MARK: - Persistence and independent edits

    @Test func independentEditsEncodeAndDecodeSeparately() throws {
        var settings = QuickSettings()
        settings.systemPrompt = "Quick only: one line."
        settings.chatSystemPrompt = "Chat only: explain in steps."

        let data = try JSONEncoder().encode(settings)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["systemPrompt"] as? String == "Quick only: one line.")
        #expect(object["chatSystemPrompt"] as? String == "Chat only: explain in steps.")

        var reloaded = try JSONDecoder().decode(QuickSettings.self, from: data)
        #expect(reloaded.systemPrompt == "Quick only: one line.")
        #expect(reloaded.chatSystemPrompt == "Chat only: explain in steps.")

        // An edit on one surface leaves the other exactly as it was, and a
        // cleared chat instruction stays cleared on the next load.
        reloaded.systemPrompt = "Quick only: second edit."
        let quickEdited = try JSONDecoder().decode(
            QuickSettings.self,
            from: JSONEncoder().encode(reloaded)
        )
        #expect(quickEdited.systemPrompt == "Quick only: second edit.")
        #expect(quickEdited.chatSystemPrompt == "Chat only: explain in steps.")

        var chatClearedEdit = quickEdited
        chatClearedEdit.chatSystemPrompt = ""
        let chatCleared = try JSONDecoder().decode(
            QuickSettings.self,
            from: JSONEncoder().encode(chatClearedEdit)
        )
        #expect(chatCleared.chatSystemPrompt.isEmpty, "an empty chat instruction is kept")
        #expect(chatCleared.systemPrompt == "Quick only: second edit.")
    }

    // MARK: - Wire text

    @Test func eachSurfaceSendsItsOwnInstructionOnTheWire() throws {
        var settings = QuickSettings()
        settings.systemPrompt = "QUICK-SURFACE-MARKER"
        settings.chatSystemPrompt = "CHAT-SURFACE-MARKER"
        let vm = QuickViewModel(settings: settings)

        #expect(try wirePrompt(of: vm, settings: settings) == "QUICK-SURFACE-MARKER")
        #expect(!vm.isAIChatWindow)

        // The AI Chat window's own view model is the chat surface.
        let window = AIChatWindowModel(chat: vm, defaults: chatWindowDefaults())
        defer { withExtendedLifetime(window) {} }
        #expect(vm.isAIChatWindow)
        #expect(try wirePrompt(of: vm, settings: settings) == "CHAT-SURFACE-MARKER")
    }

    @Test func theWireCarriesTheStockDefaultsWhenNothingWasEdited() throws {
        let settings = QuickSettings()
        let vm = QuickViewModel(settings: settings)
        #expect(try wirePrompt(of: vm, settings: settings) == QuickSettings.defaultSystemPrompt)

        let window = AIChatWindowModel(chat: vm, defaults: chatWindowDefaults())
        defer { withExtendedLifetime(window) {} }
        #expect(try wirePrompt(of: vm, settings: settings) == QuickSettings.defaultChatSystemPrompt)
    }

    @Test func aGroundedChatRequestAddsTheGroundingSentenceOnce() throws {
        var settings = QuickSettings()
        settings.chatSystemPrompt = "CHAT-RULES"
        let vm = QuickViewModel(settings: settings)
        let window = AIChatWindowModel(chat: vm, defaults: chatWindowDefaults())
        defer { withExtendedLifetime(window) {} }

        let prompt = try wirePrompt(of: vm, settings: settings, grounded: true)
        #expect(prompt == "CHAT-RULES\n\n" + ChatContextGate.groundingDirective)
        #expect(
            prompt.components(separatedBy: ChatContextGate.groundingDirective).count == 2,
            "the grounding sentence is appended once, and no default is layered under it"
        )
    }

    // MARK: - Saved assistants

    @Test func aSavedAssistantKeepsItsOwnPrecedenceBesideTheSurfaceInstruction() async throws {
        var settings = QuickSettings()
        settings.chatSystemPrompt = "CHAT-RULES"
        let vm = QuickViewModel(settings: settings)

        let assistant = SavedPrompt(
            alias: "desk",
            prompt: "",
            systemPrompt: "ASSISTANT-RULES"
        )
        let message = try #require(
            await vm.assistantSystemMessage(assistant, conversationID: UUID())
        )
        // The assistant's instructions are their own system message: the
        // surface instruction neither absorbs them nor is absorbed by them.
        #expect(message == "ASSISTANT-RULES")
        #expect(!message.contains("CHAT-RULES"))

        // In the AI Chat window the surface still sends its own instruction.
        let window = AIChatWindowModel(chat: vm, defaults: chatWindowDefaults())
        defer { withExtendedLifetime(window) {} }
        #expect(try wirePrompt(of: vm, settings: settings) == "CHAT-RULES")
    }

    // MARK: - Budget reserve

    /// The strip measures the document against the share the chat prompt
    /// leaves. The same fixture on the quick surface fits, so the difference
    /// comes from the selected surface instruction, not from the fixture.
    @Test func theStripReservesTheChatInstructionNotTheQuickOne() async throws {
        // Chat share ≈ 0.6 × (48,000 − 4,009) ≈ 26,394; quick ≈ 28,794.
        let chat = await makeBudgetChat(characters: 27_500)
        defer { withExtendedLifetime(chat.window) {} }
        #expect(chat.note?.hasPrefix("Will be cut to fit") == true)

        let quickSettings = budgetSettings(chatPromptLength: 4_000)
        let extractor = FakeAttachmentExtractor()
        let quick = QuickViewModel(
            settings: quickSettings,
            service: MockQuickService(),
            attachmentExtractor: extractor
        )
        await addBudgetAttachment(to: quick, extractor: extractor, characters: 27_500)
        #expect(!quick.isAIChatWindow)
        #expect(quick.attachmentRoutingLine == nil, "under the quick share, so no cut is promised")
    }

    /// The submitted request reserves the same surface instruction. The
    /// chat request is cut below the document's own length; the quick
    /// request carries it whole.
    @Test func theRequestBudgetReservesTheChatInstructionNotTheQuickOne() async throws {
        let chat = await makeBudgetChat(characters: 27_500)
        defer { withExtendedLifetime(chat.window) {} }
        let chatService = chat.service
        await chatService.setResponses([StreamDelta(text: "Answer.", finishReason: "stop")])
        chat.vm.input = "Summarize"
        await chat.vm.submit()
        let chatRequest = try #require(
            await chatService.lastMessages.last(where: { $0.role == .user })
        )
        #expect(
            chatRequest.content.utf8.count < 27_500,
            "the chat prompt is reserved when the share is measured"
        )

        let quickSettings = budgetSettings(chatPromptLength: 4_000)
        let extractor = FakeAttachmentExtractor()
        let quickService = MockQuickService()
        let quick = QuickViewModel(
            settings: quickSettings,
            service: quickService,
            attachmentExtractor: extractor
        )
        await addBudgetAttachment(to: quick, extractor: extractor, characters: 27_500)
        await quickService.setResponses([StreamDelta(text: "Answer.", finishReason: "stop")])
        quick.input = "Summarize"
        await quick.submit()
        let quickRequest = try #require(
            await quickService.lastMessages.last(where: { $0.role == .user })
        )
        #expect(
            quickRequest.content.utf8.count > 27_500,
            "the quick instruction is the reserve here, so the document fits"
        )
    }

    // MARK: - Settings search

    @Test func bothInstructionSettingsAreFindable() {
        #expect(
            SettingsDestinationIndex.matching("quick ai instruction")
                .contains { $0.id == "models.instruction" }
        )
        #expect(
            SettingsDestinationIndex.matching("chat instruction")
                .contains { $0.id == "models.chatInstruction" }
        )
        #expect(
            SettingsDestinationIndex.destination(id: "models.chatInstruction")?.anchor
                == "models.chatInstruction"
        )
    }

    // MARK: - Render proof

    /// Exactly the two instruction cards, offscreen, in both appearances and
    /// at the ordinary pane width. Only the cards are hosted: the provider
    /// pane's `onAppear` is never run, so no provider key is read from the
    /// Keychain. The proof is written to /tmp/quick-launch-render-proof.
    @Test func rendersBothInstructionCardsOffscreen() throws {
        let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        // The Models pane at the settings window's ideal width: window minus
        // the rail and the divider, less the pane's own horizontal gutter.
        let paneWidth = SettingsView.windowSize.width
            - House.Layout.settingsRail
            - AQDesign.hairline
            - 2 * SettingsMetrics.paneInset
        let fixture = QuickViewModel()
        let cards = VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
            ProviderSettingsView(viewModel: fixture).instructionCards
        }
        .padding(.horizontal, SettingsMetrics.paneInset)
        .frame(width: paneWidth + 2 * SettingsMetrics.paneInset, alignment: .leading)
        .background(AQDesign.ColorToken.windowSurface)
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let host = NSHostingView(rootView: cards)
            host.appearance = NSAppearance(named: appearance)
            let height = max(120, host.fittingSize.height)
            host.frame = NSRect(
                origin: .zero,
                size: NSSize(width: paneWidth + 2 * SettingsMetrics.paneInset, height: height)
            )
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(
                to: outputDir.appendingPathComponent("prompt-surfaces-models-\(suffix).png")
            )
        }
    }
}
