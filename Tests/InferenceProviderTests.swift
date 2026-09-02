import Testing
import Foundation
@testable import QuickLaunch

@Suite("Inference providers")
struct InferenceProviderTests {
    @Test func defaultsIncludeDeepSeekAndLMStudio() {
        let providers = InferenceProvider.defaults

        #expect(providers.contains { $0.id == InferenceProvider.deepSeekID })
        #expect(!providers.contains { $0.name.localizedCaseInsensitiveContains("apfel") })
        #expect(providers.contains { $0.kind == .openAICompatible && $0.baseURL == "http://127.0.0.1:1234/v1" })
        #expect(providers.contains {
            $0.id == InferenceProvider.mlxVisionID
                && $0.baseURL == InferenceProvider.localModelsBaseURL
                && $0.selectedModel == InferenceProvider.localModelsDefaultModel
        })
    }

    @Test func providerSelectionHasStableFallback() {
        let settings = QuickSettings()

        #expect(settings.selectedProviderID == InferenceProvider.deepSeekID)
        #expect(settings.selectedProvider?.kind == .openAICompatible)
        #expect(settings.selectedModel == InferenceProvider.deepSeekVisionModel)
    }

    @Test func localProvidersAreClearlyMarked() {
        let lmStudio = InferenceProvider.defaults.first { $0.id == InferenceProvider.lmStudioID }

        #expect(lmStudio?.location == .local)
        #expect(lmStudio?.discovery == .lmStudio)
    }

    @Test func cliProvidersUseDirectOneShotArguments() {
        let providers = InferenceProvider.defaults
        let claude = providers.first { $0.id == InferenceProvider.claudeCodeID }
        let pi = providers.first { $0.id == InferenceProvider.piID }

        #expect(claude?.command?.arguments.contains("--no-session-persistence") == true)
        #expect(claude?.command?.arguments.contains("--tools") == true)
        #expect(pi?.command?.arguments.contains("--no-session") == true)
        #expect(pi?.command?.arguments.contains("--no-builtin-tools") == true)
    }
}
