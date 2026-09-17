import Testing
import Foundation
import HouseChatCore
@testable import QuickLaunch

/// A turn's route is frozen at Send: a later provider edit or model change
/// cannot rewrite what the turn actually used.
@Suite("Chat model freeze")
struct ChatModelFreezeTests {
    private func provider(
        name: String = "DeepSeek",
        location: InferenceProviderLocation = .cloud,
        baseURL: String = "https://u:secret@api.deepseek.com/v1/chat?api_key=sk-1",
        selectedModel: String = "deepseek-chat"
    ) -> InferenceProvider {
        InferenceProvider(
            name: name,
            kind: .openAICompatible,
            location: location,
            baseURL: baseURL,
            selectedModel: selectedModel
        )
    }

    @Test func theRouteSurvivesALaterProviderEdit() {
        var live = provider()
        let frozen = ChatModelFreeze.freeze(provider: live, model: live.selectedModel, thinking: .low)
        live.selectedModel = "deepseek-reasoner"
        live.name = "Renamed"
        #expect(frozen.model == "deepseek-chat")
        #expect(frozen.providerName == "DeepSeek")
        #expect(frozen.thinking == "low")
    }

    @Test func thinkingValuesMapToTheWireForm() {
        #expect(ChatModelFreeze.thinkingValue(.modelDefault) == nil)
        #expect(ChatModelFreeze.thinkingValue(.low) == "low")
        #expect(ChatModelFreeze.thinkingValue(.high) == "high")
    }

    @Test func theDestinationLabelNamesTheCloudProvider() {
        #expect(ChatModelFreeze.destinationLabel(for: provider()) == "Sent to DeepSeek")
        #expect(ChatModelFreeze.destinationLabel(for: provider(name: "Local", location: .local)) == "Only on this Mac")
    }

    @Test func theEndpointIsSanitized() throws {
        let frozen = ChatModelFreeze.freeze(provider: provider(), model: "deepseek-chat", thinking: .modelDefault)
        let endpoint = try #require(frozen.endpoint)
        #expect(endpoint.sanitized == "https://api.deepseek.com/v1/chat")
        #expect(endpoint.sanitized.contains("secret") == false)
        #expect(endpoint.sanitized.contains("api_key") == false)
    }

    @Test func theSelectionCarriesBothSides() {
        let frozen = ChatModelFreeze.freeze(provider: provider(), model: "deepseek-chat", thinking: .high)
        let selection = frozen.selection(effective: ModelChoice(provider: "DeepSeek", model: "deepseek-vision"))
        #expect(selection.chosen?.thinking == "high")
        #expect(selection.effective?.model == "deepseek-vision", "a labelled fallback is recorded, not hidden")
    }
}
