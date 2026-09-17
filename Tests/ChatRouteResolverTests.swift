import Testing
import Foundation
import HouseChatCore
@testable import QuickLaunch

/// The approved routing rules: the model the user selected wins when it is
/// known to read images, the configured vision endpoint is a labelled
/// fallback used only when the selected model is not known to, a missing
/// credential blocks instead of swapping, an unknown capability is never
/// guessed, and the thinking a Fast turn puts on the wire is the thinking the
/// receipt records.
@Suite("Chat route resolver")
struct ChatRouteResolverTests {

    // MARK: - Endpoints

    private func endpoint(
        _ name: String,
        model: String,
        location: InferenceProviderLocation = .cloud,
        key: Bool = true
    ) -> ChatRouteEndpoint {
        ChatRouteEndpoint(
            provider: InferenceProvider(
                name: name,
                kind: .openAICompatible,
                location: location,
                baseURL: "https://example.test/v1",
                models: [model],
                selectedModel: model
            ),
            model: model
        )
    }

    private func request(
        selected: ChatRouteEndpoint,
        vision: ChatRouteEndpoint? = nil,
        hasImages: Bool = true,
        hasNewImages: Bool = true,
        allowsTextOnlyFallback: Bool = false,
        capability: [String: ModelImageCapability] = [:],
        unusable: Set<String> = []
    ) -> ChatRouteRequest {
        ChatRouteRequest(
            selected: selected,
            vision: vision,
            hasImages: hasImages,
            hasNewImages: hasNewImages,
            allowsTextOnlyFallback: allowsTextOnlyFallback,
            capability: { capability[$0.provider.name] ?? .unknown },
            isUsable: { !unusable.contains($0.provider.name) && !$0.model.isEmpty }
        )
    }

    // MARK: - The selected capable model wins

    @Test func theSelectedImageCapableModelWinsOverTheConfiguredFallback() {
        let selected = endpoint("Selected", model: "selected-vision")
        let fallback = endpoint("Fallback", model: "fallback-vision")
        let route = ChatRouteResolver.resolve(request(
            selected: selected,
            vision: fallback,
            capability: ["Selected": .acceptsImages, "Fallback": .acceptsImages]
        ))
        #expect(route.effective == selected)
        #expect(route.imageMode == .inline)
        #expect(!route.isVisionFallback)
        #expect(route.warning == nil)
        #expect(route.label == "Will send the image to Selected")
    }

    @Test func aTextOnlySelectedModelUsesTheLabelledFallback() {
        let selected = endpoint("Selected", model: "selected-text")
        let fallback = endpoint("Fallback", model: "fallback-vision")
        let route = ChatRouteResolver.resolve(request(
            selected: selected,
            vision: fallback,
            capability: ["Selected": .textOnly, "Fallback": .acceptsImages]
        ))
        #expect(route.effective == fallback)
        #expect(route.imageMode == .inline)
        #expect(route.isVisionFallback)
        #expect(route.chosenRejectsImages)
        #expect(route.label.contains("Selected cannot read images"))
        #expect(route.label.contains("Fallback"))
    }

    @Test func anUnknownCapabilityIsNotCalledTextOnly() {
        let selected = endpoint("Selected", model: "unknown")
        let fallback = endpoint("Fallback", model: "fallback-vision")
        let route = ChatRouteResolver.resolve(request(
            selected: selected,
            vision: fallback,
            capability: ["Fallback": .acceptsImages]
        ))
        #expect(route.effective == fallback)
        #expect(route.isVisionFallback)
        #expect(!route.chosenRejectsImages, "no claim is made that the unknown model rejects images")
        #expect(!route.label.contains("cannot read images"))
        #expect(route.label == "Will send the image to Fallback")
    }

    @Test func theConfiguredEndpointIsUsedWhenItIsTheSelectedOne() {
        let only = endpoint("Only", model: "one-model")
        let route = ChatRouteResolver.resolve(request(
            selected: only,
            vision: only,
            capability: ["Only": .unknown]
        ))
        #expect(route.effective == only)
        #expect(route.imageMode == .inline)
        #expect(!route.isVisionFallback)
    }

    // MARK: - Blocking, never swapping

    @Test func aMissingKeyBlocksInsteadOfSwappingProvider() {
        let selected = endpoint("Selected", model: "selected-vision")
        let fallback = endpoint("Fallback", model: "fallback-vision")
        let route = ChatRouteResolver.resolve(request(
            selected: selected,
            vision: fallback,
            capability: ["Selected": .acceptsImages, "Fallback": .acceptsImages],
            unusable: ["Selected"]
        ))
        #expect(route.effective == selected, "the route is never quietly moved to the fallback")
        #expect(route.warning?.contains("needs an API key") == true)
        #expect(!route.isUsable)
        #expect(route.label == "No vision model: this image cannot be sent")
    }

    @Test func aMissingKeyOnTheFallbackBlocksRatherThanReadingTheImageLocally() {
        let selected = endpoint("Selected", model: "selected-text")
        let fallback = endpoint("Fallback", model: "fallback-vision")
        let route = ChatRouteResolver.resolve(request(
            selected: selected,
            vision: fallback,
            capability: ["Selected": .textOnly, "Fallback": .acceptsImages],
            unusable: ["Fallback"]
        ))
        #expect(route.warning != nil)
        #expect(route.imageMode != .inline)
    }

    @Test func aNewImageWithNoRouteIsRefusedWithoutConsent() {
        let selected = endpoint("Selected", model: "selected-text")
        let route = ChatRouteResolver.resolve(request(
            selected: selected,
            capability: ["Selected": .textOnly]
        ))
        #expect(route.warning?.contains("cannot read images") == true)
        #expect(route.imageMode == .textOnly, "the mode is only reached once consent exists")
        #expect(!route.isUsable)
    }

    @Test func aNewImageWithNoRouteIsReadLocallyWithExplicitConsent() {
        let selected = endpoint("Selected", model: "selected-text")
        let route = ChatRouteResolver.resolve(request(
            selected: selected,
            allowsTextOnlyFallback: true,
            capability: ["Selected": .textOnly]
        ))
        #expect(route.warning == nil)
        #expect(route.imageMode == .textOnly)
        #expect(route.label == "Will send as text (read on this Mac)")
    }

    @Test func anImageCarriedFromAnEarlierTurnIsReadLocallyWithoutConsent() {
        let selected = endpoint("Selected", model: "selected-text")
        let route = ChatRouteResolver.resolve(request(
            selected: selected,
            hasNewImages: false,
            capability: ["Selected": .textOnly]
        ))
        #expect(route.warning == nil, "nothing new was attached, so nothing is refused")
        #expect(route.imageMode == .textOnly)
    }

    // MARK: - No images

    @Test func aTextTurnUsesTheSelectedRouteAndNeedsNoVision() {
        let selected = endpoint("Selected", model: "text-model")
        let route = ChatRouteResolver.resolve(request(selected: selected, hasImages: false))
        #expect(route.effective == selected)
        #expect(route.imageMode == .none)
        #expect(route.warning == nil)
        #expect(route.label == "Will send to Selected")
    }

    @Test func aTextTurnOnAMissingKeyStillBlocks() {
        let selected = endpoint("Selected", model: "text-model")
        let route = ChatRouteResolver.resolve(request(
            selected: selected,
            hasImages: false,
            unusable: ["Selected"]
        ))
        #expect(route.warning?.contains("needs an API key") == true)
        #expect(!route.hasImages)
        #expect(route.label == "No model available")
    }

    @Test func aLocalTextTurnReadsOnlyOnThisMac() {
        let selected = endpoint("Local", model: "local-model", location: .local)
        let route = ChatRouteResolver.resolve(request(selected: selected, hasImages: false))
        #expect(route.label == "Only on this Mac")
    }

    // MARK: - Fast thinking matches the wire

    @Test func fastThinkingIsWrittenAsAnExplicitOffWhereSupported() {
        let fields = ReasoningEffortWireFormat.deepSeek.fields(for: .modelDefault, thinkingSupported: true)
        #expect((fields["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(fields["reasoning_effort"] == nil)
        #expect(Set(fields.keys) == ["thinking"])
    }

    @Test func anExplicitOverrideIsPreserved() {
        let low = ReasoningEffortWireFormat.deepSeek.fields(for: .low, thinkingSupported: true)
        #expect((low["thinking"] as? [String: Any])?["type"] as? String == "enabled")
        #expect(low["reasoning_effort"] as? String == "low")

        let high = ReasoningEffortWireFormat.deepSeek.fields(for: .high, thinkingSupported: true)
        #expect(high["reasoning_effort"] as? String == "high")
    }

    @Test func nothingIsRetunedForEndpointsOrModelsWithoutTheDirective() {
        #expect(ReasoningEffortWireFormat.deepSeek.fields(for: .modelDefault, thinkingSupported: false).isEmpty)
        #expect(ReasoningEffortWireFormat.deepSeek.fields(for: nil, thinkingSupported: true).isEmpty)
        #expect(ReasoningEffortWireFormat.openAI.fields(for: .modelDefault, thinkingSupported: true).isEmpty)
    }

    @Test func theFrozenThinkingValueMatchesTheWire() {
        #expect(ChatModelFreeze.thinkingValue(.modelDefault, supported: true) == "disabled")
        #expect(ChatModelFreeze.thinkingValue(.modelDefault, supported: false) == nil)
        #expect(ChatModelFreeze.thinkingValue(.low, supported: true) == "low")
        #expect(ChatModelFreeze.thinkingValue(.high, supported: true) == "high")
        #expect(ChatModelFreeze.thinkingValue(.modelDefault) == nil, "the old signature is unchanged")
    }

    @Test func theServiceBodyCarriesTheFastDirectiveOnlyWhenSupported() throws {
        let supported = OpenAICompatibleService(
            baseURL: URL(string: "https://api.deepseek.com")!,
            modelName: "deepseek-flash",
            reasoningEffort: .modelDefault,
            thinkingSupported: true
        )
        let body = try #require(try supported.buildRequest(prompt: "hi").httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(json["reasoning_effort"] == nil)

        let plain = OpenAICompatibleService(
            baseURL: URL(string: "https://api.deepseek.com")!,
            modelName: "deepseek-flash",
            reasoningEffort: .modelDefault
        )
        let plainBody = try #require(try plain.buildRequest(prompt: "hi").httpBody)
        let plainJSON = try #require(JSONSerialization.jsonObject(with: plainBody) as? [String: Any])
        #expect(plainJSON["thinking"] == nil, "an unset directive is not invented")
    }

    @Test func theResolvedThinkingIsTheSameValueTheReceiptRecords() {
        let selected = endpoint("Selected", model: "selected-vision")
        var request = request(selected: selected, capability: ["Selected": .acceptsImages])
        request.effort = { _ in .modelDefault }
        request.supportsThinking = { _ in true }
        let route = ChatRouteResolver.resolve(request)
        #expect(route.thinking == .modelDefault)
        #expect(route.thinkingSupported)
        #expect(route.thinkingValue == "disabled")
        let fields = ReasoningEffortWireFormat.deepSeek.fields(
            for: route.thinking,
            thinkingSupported: route.thinkingSupported
        )
        #expect((fields["thinking"] as? [String: Any])?["type"] as? String == route.thinkingValue)
    }

    // MARK: - The view model resolves the same way

    @Test @MainActor func theSelectedModelIsPreferredOverTheGlobalVisionDefault() {
        var settings = QuickSettings()
        // The chat answers on DeepSeek's flash model, which reads images; the
        // global vision default names the local models instead.
        settings.selectedProviderID = InferenceProvider.deepSeekID
        settings.visionProviderID = InferenceProvider.mlxVisionID
        settings.visionModel = "qwen3-vl"
        let vm = QuickViewModel(settings: settings)

        let route = vm.resolveChatRoute(hasImages: true, hasNewImages: true)
        #expect(route.effective.provider.id == InferenceProvider.deepSeekID)
        #expect(route.effective.model == InferenceProvider.deepSeekDefaultModel)
        #expect(route.imageMode == .inline)
        #expect(!route.isVisionFallback)
        #expect(route.label == "Will send the image to DeepSeek API")
        #expect(route.isUsable)
        #expect(vm.resolveChatRoute(hasImages: false).label == "Will send to DeepSeek API")
    }

    @Test @MainActor func anUnknownSelectedModelUsesTheConfiguredVisionRoute() {
        var settings = QuickSettings()
        settings.selectedProviderID = InferenceProvider.deepSeekID
        if let index = settings.providers.firstIndex(where: { $0.id == InferenceProvider.deepSeekID }) {
            settings.providers[index].selectedModel = "an-unseen-model"
        }
        settings.visionProviderID = InferenceProvider.mlxVisionID
        settings.visionModel = "qwen3-vl"
        let vm = QuickViewModel(settings: settings)

        let route = vm.resolveChatRoute(hasImages: true, hasNewImages: true)
        #expect(route.effective.provider.id == InferenceProvider.mlxVisionID)
        #expect(route.effective.model == "qwen3-vl")
        #expect(route.imageMode == .inline)
        #expect(!route.chosenRejectsImages)
    }

    @Test @MainActor func theCuratedCapabilityFactsAreHonest() {
        let preferences = ModelPreferenceStore(fileURL: nil)
        let providerID = UUID()
        #expect(
            preferences.profile(providerID: providerID, model: "deepseek-flash").imageCapability == .acceptsImages
        )
        #expect(preferences.profile(providerID: providerID, model: "qwen3-vl").imageCapability == .acceptsImages)
        #expect(
            preferences.profile(providerID: providerID, model: "unlisted-model").imageCapability == .unknown,
            "a model with no curated fact is unknown, never guessed"
        )
    }
}
