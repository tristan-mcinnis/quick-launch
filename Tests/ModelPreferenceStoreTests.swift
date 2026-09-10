import Testing
import Foundation
@testable import QuickLaunch

@Suite("Model preferences")
@MainActor
struct ModelPreferenceStoreTests {
    private let providerID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let otherProviderID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!

    /// A reasoning model the curated table ships support for.
    private let reasoningModel = "deepseek-v4-flash"
    /// A second reasoning model, so carry-over can be observed.
    private let otherReasoningModel = "kimi-k3"
    /// A model the curated table ships no reasoning effort for.
    private let plainModel = "gemma-it"

    private func freshFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-model-prefs-\(UUID().uuidString)")
    }

    private func provider(
        _ id: UUID,
        _ name: String,
        models: [String],
        selected: String = ""
    ) -> InferenceProvider {
        InferenceProvider(
            id: id,
            name: name,
            kind: .openAICompatible,
            location: .cloud,
            models: models,
            selectedModel: selected
        )
    }

    @Test func aModelTheUserNeverTouchedIsOnAndUnknown() {
        let store = ModelPreferenceStore(fileURL: nil)

        let profile = store.profile(providerID: providerID, model: "some-unknown-model")

        #expect(store.isEnabled(providerID: providerID, model: "some-unknown-model"))
        #expect(profile.enabled)
        #expect(profile.contextWindowLabel == "Unknown")
        #expect(profile.speed == nil)
        #expect(!profile.supportsReasoningEffort)
        #expect(profile.reasoningEffort == .modelDefault)
    }

    @Test func choicesRoundTripThroughTheOwnedFile() {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("model-preferences.json")

        let first = ModelPreferenceStore(fileURL: url)
        first.setEnabled(false, providerID: providerID, model: plainModel)
        first.setReasoningEffort(.high, providerID: providerID, model: reasoningModel)
        first.waitForPendingWrites()

        let second = ModelPreferenceStore(fileURL: url)
        #expect(!second.isEnabled(providerID: providerID, model: plainModel))
        #expect(second.profile(providerID: providerID, model: plainModel).enabled == false)
        #expect(second.profile(providerID: providerID, model: reasoningModel).reasoningEffort == .high)

        let permissions = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func aProfileIsPerProviderAndModel() {
        let store = ModelPreferenceStore(fileURL: nil)

        store.setEnabled(false, providerID: providerID, model: reasoningModel)

        #expect(!store.isEnabled(providerID: providerID, model: reasoningModel))
        #expect(store.isEnabled(providerID: otherProviderID, model: reasoningModel))
        #expect(store.isEnabled(providerID: providerID, model: plainModel))
    }

    @Test func disabledModelsAreHiddenFromTheVisibleModelAPI() {
        let store = ModelPreferenceStore(fileURL: nil)
        let provider = provider(
            providerID,
            "DeepSeek API",
            models: [plainModel, reasoningModel, otherReasoningModel]
        )
        store.setEnabled(false, providerID: providerID, model: plainModel)

        let visible = ModelCatalogService.visibleModels(for: provider, preferences: store)

        #expect(visible == [reasoningModel, otherReasoningModel])
        #expect(!visible.contains(plainModel))
    }

    @Test func theCurrentSelectionStaysInTheListEvenWhenItIsOff() {
        let store = ModelPreferenceStore(fileURL: nil)
        let provider = provider(
            providerID,
            "DeepSeek API",
            models: [plainModel, reasoningModel],
            selected: plainModel
        )
        store.setEnabled(false, providerID: providerID, model: plainModel)

        let visible = ModelCatalogService.visibleModels(
            for: provider,
            currentModel: provider.selectedModel,
            preferences: store
        )

        #expect(visible == [reasoningModel, plainModel])
    }

    @Test func aModelWithoutReasoningSupportAlwaysReadsModelDefault() {
        let store = ModelPreferenceStore(fileURL: nil)

        store.setReasoningEffort(.high, providerID: providerID, model: reasoningModel)

        #expect(store.profile(providerID: providerID, model: plainModel).reasoningEffort == .modelDefault)
    }

    @Test func theReasoningChoiceCarriesOverToTheNextModelThatSupportsIt() {
        let store = ModelPreferenceStore(fileURL: nil)

        #expect(store.profile(providerID: providerID, model: otherReasoningModel).reasoningEffort == .modelDefault)

        store.setReasoningEffort(.high, providerID: providerID, model: reasoningModel)

        #expect(store.profile(providerID: providerID, model: reasoningModel).reasoningEffort == .high)
        // The model that was never given a choice of its own carries it over.
        #expect(store.profile(providerID: providerID, model: otherReasoningModel).reasoningEffort == .high)
        #expect(store.carriedReasoningEffort == .high)
    }

    @Test func switchingToAModelWithoutReasoningResetsTheCarriedChoice() {
        let store = ModelPreferenceStore(fileURL: nil)
        store.setReasoningEffort(.high, providerID: providerID, model: reasoningModel)

        store.noteModelSelection(providerID: providerID, model: plainModel)

        #expect(store.carriedReasoningEffort == .modelDefault)
        // The reset does not touch a choice the user made for one model.
        #expect(store.profile(providerID: providerID, model: reasoningModel).reasoningEffort == .high)
        // A model that only borrowed the choice starts back at the default.
        #expect(store.profile(providerID: providerID, model: otherReasoningModel).reasoningEffort == .modelDefault)
    }

    @Test func switchingBetweenReasoningModelsDoesNotResetTheChoice() {
        let store = ModelPreferenceStore(fileURL: nil)
        store.setReasoningEffort(.high, providerID: providerID, model: reasoningModel)

        store.noteModelSelection(providerID: providerID, model: otherReasoningModel)

        #expect(store.carriedReasoningEffort == .high)
    }

    @Test func theCarriedChoiceSurvivesAReload() {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("model-preferences.json")

        let first = ModelPreferenceStore(fileURL: url)
        first.setReasoningEffort(.high, providerID: providerID, model: reasoningModel)
        first.waitForPendingWrites()

        let second = ModelPreferenceStore(fileURL: url)

        #expect(second.carriedReasoningEffort == .high)
        #expect(second.profile(providerID: otherProviderID, model: reasoningModel).reasoningEffort == .high)
    }

    @Test func entriesCoverEveryModelInProviderOrder() {
        let store = ModelPreferenceStore(fileURL: nil)
        let providers = [
            provider(providerID, "DeepSeek API", models: [reasoningModel, plainModel]),
            provider(otherProviderID, "Moonshot", models: [otherReasoningModel]),
        ]
        store.setEnabled(false, providerID: otherProviderID, model: otherReasoningModel)

        let entries = store.entries(for: providers)

        #expect(entries.map(\.providerName) == ["DeepSeek API", "DeepSeek API", "Moonshot"])
        #expect(entries.map(\.model) == [reasoningModel, plainModel, otherReasoningModel])
        #expect(entries.last?.profile.enabled == false)
        #expect(entries.first?.profile.supportsReasoningEffort == true)
    }

    @Test func resetForgetsEveryChoice() {
        let store = ModelPreferenceStore(fileURL: nil)
        store.setEnabled(false, providerID: providerID, model: plainModel)
        store.setReasoningEffort(.high, providerID: providerID, model: reasoningModel)

        store.reset()

        #expect(store.profiles.isEmpty)
        #expect(store.carriedReasoningEffort == .modelDefault)
        #expect(store.isEnabled(providerID: providerID, model: plainModel))
    }
}
