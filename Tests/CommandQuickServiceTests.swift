import Testing
import Foundation
@testable import QuickLaunch

@Suite("Command quick service")
struct CommandQuickServiceTests {
    @Test func expandsModelAndSystemPromptPlaceholders() {
        let arguments = CommandQuickService.expandedArguments(
            ["-p", "--model", "{{model}}", "--system-prompt", "{{systemPrompt}}"],
            model: "sonnet",
            systemPrompt: "Return only the answer"
        )

        #expect(arguments == ["-p", "--model", "sonnet", "--system-prompt", "Return only the answer"])
    }

    @Test func resolvesInstalledClaudeExecutable() {
        let resolved = ExecutableResolver.resolve("claude")

        // This assertion is conditional so the upstream test suite stays portable.
        if FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/claude").path) {
            #expect(resolved != nil)
        }
    }
}
