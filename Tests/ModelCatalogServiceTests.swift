import Testing
import Foundation
@testable import QuickLaunch

@Suite("Model catalogue")
struct ModelCatalogServiceTests {
    @Test func parsesOpenAIModelList() throws {
        let data = Data(#"{"object":"list","data":[{"id":"model-b"},{"id":"model-a"}]}"#.utf8)

        let models = try ModelCatalogService.parseModels(data)

        #expect(models == ["model-a", "model-b"])
    }

    @Test func parsesLMStudioDownloadedAndLoadedModels() throws {
        let data = Data(#"{"data":[{"id":"qwen-local","state":"not-loaded"},{"id":"gemma-local","state":"loaded"}]}"#.utf8)

        let models = try ModelCatalogService.parseModels(data)

        #expect(models == ["gemma-local", "qwen-local"])
    }

    @Test func parsesPiProviderAndModelPairs() {
        let output = """
        provider  model              context  max-out
        deepseek  deepseek-v4-flash  1M       384K
        xiaomi    mimo-v2.5-pro      1M       131K
        """

        #expect(ModelCatalogService.parsePiModels(output) == [
            "deepseek/deepseek-v4-flash",
            "xiaomi/mimo-v2.5-pro",
        ])
    }
}
