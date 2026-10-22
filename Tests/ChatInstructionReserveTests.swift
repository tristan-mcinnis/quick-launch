// ChatInstructionReserveTests — the attachment budget and the provider body
// must measure the same system instruction.
//
// The budget's reserve counts what the request sends besides the question.
// It counted `QuickSettings.surfaceSystemPrompt` alone, while the wire carried
// `ChatContextGate.systemPrompt` (that prompt plus the grounding sentence on a
// grounded turn) and, with an assistant, that message joined in front of it
// with a blank line. A grounded turn's attachment share was therefore
// measured against an instruction the model never received.
//
// Each test drives the production submit path with an injected mock transport
// and a synthetic source, reads the share the turn persisted in an isolated
// archive, and rebuilds the provider service with `makeService` from the
// messages the send path actually handed its service. That is a rebuild, not
// a capture of the service the turn used: production builds the service
// before the archive write, and the injected mock stands in for the network.
// `toolOverride`, `attachmentTrim` and `textOnly` can differ between the two
// builds; none of them changes the system instruction.
//
// The receipt's `budgetCharacters` is a derived share, not a quality score.
// This fix changes it by construction, so a receipt written before the fix
// cannot be compared with one written after it.
//
// No provider is dialled and no preferences, Keychain item, history file, or
// skill file is read or written.

import Foundation
import HouseChatCore
import Testing
@testable import QuickLaunch

@Suite("Chat instruction reserve", .serialized)
@MainActor
struct ChatInstructionReserveTests {

    // MARK: - Fixtures

    /// A chat window host, so the view model reads as the AI Chat surface
    /// without any window.
    @MainActor
    private final class FakeChatWindowHost: AIChatWindowHosting {
        var windowSurfaceActions: [QuickAISurfaceAction] { [] }
        func performWindowSurfaceAction(_ action: QuickAISurfaceAction) {}
        func beginRenamingChat(id: UUID) {}
    }

    private final class Rig {
        let vm: QuickViewModel
        let service: MockQuickService
        let extractor: FakeAttachmentExtractor
        let provider: InferenceProvider
        let directory: URL
        /// Held so the weak `chatWindowHost` stays alive.
        let host: FakeChatWindowHost?

        init(
            vm: QuickViewModel,
            service: MockQuickService,
            extractor: FakeAttachmentExtractor,
            provider: InferenceProvider,
            directory: URL,
            host: FakeChatWindowHost?
        ) {
            self.vm = vm
            self.service = service
            self.extractor = extractor
            self.provider = provider
            self.directory = directory
            self.host = host
        }

        var model: String { provider.selectedModel }

        /// The question every test asks: one byte, so the share arithmetic is
        /// about the instruction and not the wording.
        let question = "q"
    }

    private func stubProvider() -> InferenceProvider {
        InferenceProvider(
            name: "Stub API",
            kind: .openAICompatible,
            location: .cloud,
            baseURL: "https://stub.invalid/v1",
            models: ["stub-model"],
            selectedModel: "stub-model"
        )
    }

    private func makeRig(
        chat: Bool = false,
        configure: (inout QuickSettings) -> Void = { _ in }
    ) -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-instruction-reserve-\(UUID())")
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        settings.newChatInterval = .never
        let provider = stubProvider()
        settings.providers = [provider]
        settings.selectedProviderID = provider.id
        configure(&settings)
        let service = MockQuickService()
        let extractor = FakeAttachmentExtractor()
        let host = chat ? FakeChatWindowHost() : nil
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            pasteboard: FakePasteboard(),
            archiveRootURL: directory,
            attachmentExtractor: extractor,
            apiKeyProvider: { _ in nil }
        )
        // An in-memory preference store: the curated window for `stub-model`
        // and nothing from this Mac.
        vm.modelPreferences = ModelPreferenceStore(fileURL: nil)
        vm.chatWindowHost = host
        return Rig(
            vm: vm,
            service: service,
            extractor: extractor,
            provider: provider,
            directory: directory,
            host: host
        )
    }

    /// A synthetic document on the tray: the fake reader answers with text,
    /// so nothing is read from disk.
    private func attach(_ rig: Rig, name: String = "plan.txt", text: String? = nil) async {
        if let text {
            let ref = ChatAttachmentRef(
                kind: .text,
                name: name,
                byteCount: text.utf8.count,
                characterCount: text.count,
                contentHash: String(repeating: "0f", count: 32),
                extractorVersion: 1,
                path: "/tmp/quick-launch-instruction-reserve/\(name)"
            )
            await rig.extractor.set(.content(AttachmentContent(ref: ref, text: text)), for: name)
        }
        rig.vm.attachmentTray.add(.file(URL(fileURLWithPath: "/tmp/quick-launch-instruction-reserve/\(name)")))
        await rig.vm.attachmentTray.waitForDrop()
        await rig.vm.attachmentTray.waitUntilRead()
    }

    private func ask(_ rig: Rig, _ question: String? = nil) async {
        await rig.service.setResponses([StreamDelta(text: "Answer.", finishReason: "stop")])
        rig.vm.input = question ?? rig.question
        await rig.vm.submit()
    }

    /// The provider body the send path's own service produces for the
    /// messages it was handed: the system content is the instruction the
    /// model reads.
    private func wireSystemInstruction(
        _ rig: Rig,
        messages: [QuickMessage],
        grounded: Bool
    ) throws -> String {
        let injected = rig.vm.service
        // Production's own service, built by the same call the send path
        // makes; the injected mock stands aside for it and comes back.
        rig.vm.service = nil
        defer { rig.vm.service = injected }
        let service = try #require(
            rig.vm.makeService(provider: rig.provider, model: rig.model, grounded: grounded)
                as? OpenAICompatibleService
        )
        let body = try #require(
            try service.buildRequest(messages: messages, turnImages: [:]).httpBody
        )
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try #require(json["messages"] as? [[String: Any]])
        return try #require(sent.first?["content"] as? String)
    }

    /// The share the attachments were fitted into, as the turn recorded it.
    private func persistedShare(_ rig: Rig) async throws -> Int {
        let archive = try #require(rig.vm.chatArchive)
        let record = try #require(try await archive.loadAll().last)
        let turn = try #require(record.turns.last { $0.role == .user })
        let context = try #require(turn.request?.context)
        return try #require(context.budgetCharacters)
    }

    /// The share the same limit yields when the reserve is measured against
    /// the instruction the wire actually carries.
    private func shareFromWire(_ rig: Rig, question: String, wire: String) -> Int {
        let budget = rig.vm.attachmentContextBudget(provider: rig.provider, model: rig.model)
        return AttachmentRequestComposer.share(
            characterLimit: budget.characterLimit,
            reserved: question.utf8.count + wire.utf8.count
        )
    }

    // MARK: - Grounded turns

    @Test func aGroundedQuickAITurnReservesTheInstructionOnTheWire() async throws {
        let rig = makeRig { settings in
            settings.systemPrompt = "SURFACE-RULES-1"
        }
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        await attach(rig)
        await ask(rig)

        let sent = await rig.service.lastMessages
        let lastUser = try #require(sent.last { $0.role == .user })
        #expect(lastUser.content.hasSuffix(rig.question), "the question is the last user turn")
        let wire = try wireSystemInstruction(rig, messages: sent, grounded: true)
        #expect(wire.hasPrefix("SURFACE-RULES-1"))
        #expect(wire.contains(ChatContextGate.groundingDirective))

        #expect(
            try await persistedShare(rig) == shareFromWire(rig, question: rig.question, wire: wire),
            "the share is measured against the instruction the model reads"
        )
    }

    @Test func aGroundedTurnWithNoSurfaceInstructionReservesTheDirective() async throws {
        let rig = makeRig { settings in
            settings.systemPrompt = ""
        }
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        await attach(rig)
        await ask(rig)

        let sent = await rig.service.lastMessages
        let wire = try wireSystemInstruction(rig, messages: sent, grounded: true)
        #expect(wire == ChatContextGate.groundingDirective)

        #expect(
            try await persistedShare(rig) == shareFromWire(rig, question: rig.question, wire: wire)
        )
    }

    @Test func aGroundedAIChatTurnReservesTheChatInstruction() async throws {
        let rig = makeRig(chat: true) { settings in
            settings.systemPrompt = "SURFACE-RULES-1"
            settings.chatSystemPrompt = "CHAT-RULES-1"
        }
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        await attach(rig)
        await ask(rig)

        let sent = await rig.service.lastMessages
        let wire = try wireSystemInstruction(rig, messages: sent, grounded: true)
        #expect(wire.hasPrefix("CHAT-RULES-1"), "the chat surface sends its own instruction")
        #expect(wire.contains(ChatContextGate.groundingDirective))

        #expect(
            try await persistedShare(rig) == shareFromWire(rig, question: rig.question, wire: wire)
        )
    }

    /// A source from an earlier turn grounds the next question without a new
    /// attachment: the wire still carries the sentence, so the reserve must.
    @Test func aRetainedSourceStillCountsTheGroundingSentence() async throws {
        let rig = makeRig { settings in
            settings.systemPrompt = "SURFACE-RULES-1"
        }
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        await attach(rig)
        await ask(rig)
        await ask(rig, "q2")

        let sent = await rig.service.lastMessages
        let wire = try wireSystemInstruction(rig, messages: sent, grounded: true)
        #expect(wire.contains(ChatContextGate.groundingDirective))

        #expect(
            try await persistedShare(rig) == shareFromWire(rig, question: "q2", wire: wire)
        )
    }

    /// The assistant's message rides in front of the surface instruction in
    /// the one system message, separated by a blank line: both separators and
    /// both instructions are on the wire, so both are in the reserve.
    @Test func anAssistantInstructionIsCountedInFull() async throws {
        let provider = stubProvider()
        let assistant = SavedPrompt(
            name: "Researcher",
            alias: "res",
            prompt: "",
            providerID: provider.id,
            model: provider.selectedModel,
            systemPrompt: "ASSISTANT-RULES-1"
        )
        let rig = makeRig { settings in
            settings.systemPrompt = "SURFACE-RULES-1"
            settings.savedPrompts = [assistant]
        }
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        rig.vm.currentConversation = QuickConversation(
            providerID: provider.id,
            model: provider.selectedModel,
            assistantID: assistant.id
        )
        await attach(rig)
        await ask(rig)

        let sent = await rig.service.lastMessages
        let wire = try wireSystemInstruction(rig, messages: sent, grounded: true)
        #expect(
            wire == "ASSISTANT-RULES-1\n\nSURFACE-RULES-1\n\n" + ChatContextGate.groundingDirective,
            "the assistant's message, the surface instruction and the sentence, one blank line apart"
        )

        #expect(
            try await persistedShare(rig) == shareFromWire(rig, question: rig.question, wire: wire)
        )
    }

    // MARK: - Composition

    /// The one system message is the assistant's instructions and the
    /// lane's instruction, one blank line apart, an empty part left out: the
    /// rule `OpenAICompatibleService` and `CommandQuickService` join by.
    @Test func theCompositionIsTheProvidersJoin() {
        func composed(
            _ surface: String,
            grounded: Bool,
            lane: ChatContextGate.InstructionLane = .model,
            assistant: String? = nil
        ) -> String {
            ChatContextGate.systemInstruction(
                surfacePrompt: surface,
                grounded: grounded,
                lane: lane,
                assistantInstruction: assistant
            )
        }
        let sentence = ChatContextGate.groundingDirective

        #expect(composed("SURFACE", grounded: true, assistant: "ASSISTANT")
            == "ASSISTANT\n\nSURFACE\n\n" + sentence)
        #expect(composed("SURFACE", grounded: true) == "SURFACE\n\n" + sentence)
        #expect(composed("SURFACE", grounded: false) == "SURFACE")
        // No surface instruction: the assistant's message, or the sentence
        // alone.
        #expect(composed("", grounded: true) == sentence)
        #expect(composed("", grounded: false, assistant: "ASSISTANT") == "ASSISTANT")
        #expect(composed("", grounded: false).isEmpty)
        #expect(composed("   \n", grounded: false).isEmpty, "a blank instruction is no instruction")
        // The command-line lane has never carried the grounding sentence.
        #expect(composed("SURFACE", grounded: true, lane: .commandLine) == "SURFACE")
    }

    /// The provider body composes the message exactly as `systemInstruction`
    /// does, so the reserve and the wire cannot drift apart.
    @Test func theProviderBodyCarriesExactlyTheComposedInstruction() throws {
        let service = OpenAICompatibleService(
            baseURL: URL(string: "https://stub.invalid/v1")!,
            modelName: "stub-model",
            systemPrompt: ChatContextGate.systemInstruction(
                surfacePrompt: "SURFACE",
                grounded: true,
                lane: .model
            )
        )
        let messages = [
            QuickMessage(role: .system, content: "ASSISTANT"),
            QuickMessage(role: .user, content: "q"),
        ]
        let body = try #require(try service.buildRequest(messages: messages, turnImages: [:]).httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try #require(json["messages"] as? [[String: Any]])
        #expect(
            sent.first?["content"] as? String == ChatContextGate.systemInstruction(
                surfacePrompt: "SURFACE",
                grounded: true,
                lane: .model,
                assistantInstruction: "ASSISTANT"
            )
        )
    }

    // MARK: - The strip's estimate

    /// The strip resolves the route once and measures that route's provider,
    /// model and instruction, so its "Will be cut to fit" line agrees with
    /// the share the send path actually fits into. A document far over the
    /// share draws the line and loses its tail on send; far under it, neither
    /// happens.
    ///
    /// Written for the builder path only: the assistant's message and a
    /// question the send path expands or enriches are not visible to the
    /// synchronous estimate, so this does not claim an upper bound.
    @Test func theStripAndTheSendPathAgreeOnWhatFits() async throws {
        let rig = makeRig { settings in
            settings.systemPrompt = "SURFACE-RULES-1"
        }
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let wire = ChatContextGate.systemInstruction(
            surfacePrompt: "SURFACE-RULES-1",
            grounded: true,
            lane: .model
        )
        let share = shareFromWire(rig, question: rig.question, wire: wire)
        let tail = "TAIL-MARKER-7"

        await attach(rig, name: "big.txt", text: Self.body(count: share + 5_000, tail: tail))
        #expect(rig.vm.attachmentRoutingLine == "Will be cut to fit Stub API")
        await ask(rig)
        let cut = try #require(await rig.service.lastMessages.last { $0.role == .user }?.content)
        #expect(!cut.contains(tail), "the send path fitted the block")

        // The same state, far under the share.
        let small = makeRig { settings in
            settings.systemPrompt = "SURFACE-RULES-1"
        }
        defer { try? FileManager.default.removeItem(at: small.directory) }
        await attach(small, name: "small.txt", text: Self.body(count: share - 5_000, tail: tail))
        #expect(small.vm.attachmentRoutingLine != "Will be cut to fit Stub API")
        await ask(small)
        let kept = try #require(await small.service.lastMessages.last { $0.role == .user }?.content)
        #expect(kept.contains(tail), "nothing was cut")
    }

    /// `count` characters of filler ending in `tail`.
    private static func body(count: Int, tail: String) -> String {
        String(repeating: "x", count: max(0, count - tail.count)) + tail
    }

    // MARK: - Control

    /// An ungrounded turn carries the surface instruction and nothing else,
    /// so its reserve is that instruction: the fix must not over-reserve.
    @Test func anUngroundedTurnReservesOnlyTheSurfaceInstruction() async throws {
        let rig = makeRig { settings in
            settings.systemPrompt = "SURFACE-RULES-1"
        }
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        await ask(rig)

        let sent = await rig.service.lastMessages
        let wire = try wireSystemInstruction(rig, messages: sent, grounded: false)
        #expect(wire == "SURFACE-RULES-1")

        #expect(
            try await persistedShare(rig) == shareFromWire(rig, question: rig.question, wire: wire)
        )
    }
}
