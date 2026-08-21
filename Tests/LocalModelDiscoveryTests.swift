import Testing
import Foundation
@testable import QuickLaunch

@Suite("Local model discovery")
struct LocalModelDiscoveryTests {
    @Test func scansModelFilesWithoutCallingLMStudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("apfel-model-test-\(UUID().uuidString)")
        let gguf = root.appendingPathComponent("google/gemma-4-e2b/model.gguf")
        let mlx = root.appendingPathComponent("mlx/qwen3.5-2b/config.json")
        try FileManager.default.createDirectory(
            at: gguf.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: mlx.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: gguf)
        try Data("{}".utf8).write(to: mlx)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(LocalModelDiscovery.lmStudioModels(root: root) == [
            "google/gemma-4-e2b",
            "mlx/qwen3.5-2b",
        ])
    }
}
