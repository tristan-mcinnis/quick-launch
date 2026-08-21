import Testing
import Foundation
@testable import apfel_quick

@Suite("Local model discovery")
struct LocalModelDiscoveryTests {
    @Test func parsesOnlyLMStudioLanguageModels() {
        let data = Data(#"[{"type":"llm","modelKey":"google/gemma-4-e2b"},{"type":"embedding","modelKey":"embed"},{"type":"llm","modelKey":"qwen3.5-2b"}]"#.utf8)

        #expect(LocalModelDiscovery.parseLMStudioModels(data) == [
            "google/gemma-4-e2b",
            "qwen3.5-2b",
        ])
    }
}
