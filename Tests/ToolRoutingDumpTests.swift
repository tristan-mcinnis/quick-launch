import Foundation
import Testing
@testable import QuickLaunch

/// Opt-in: writes the tool list and system prompt a chat sends, so an eval
/// outside the repo can ask a real model which tool it would call.
/// `QUICK_LAUNCH_TOOL_DUMP=/path/tools.json swift test --filter ToolRoutingDump`
@Suite("Tool routing dump")
struct ToolRoutingDumpTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QUICK_LAUNCH_TOOL_DUMP"] != nil))
    func dumpTheToolsAChatSends() throws {
        let path = try #require(ProcessInfo.processInfo.environment["QUICK_LAUNCH_TOOL_DUMP"])
        let toolbox = ChatToolbox(
            enabled: Set(ChatToolKind.allCases),
            memory: FakeMemory(),
            skills: SkillLibrary(root: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/skills")),
            pages: FakePages(),
            workFiles: WorkItemResolver(root: FileManager.default.temporaryDirectory),
            opener: FakeFileOpener(),
            harness: FakeHarness()
        )
        let tools = [OpenAICompatibleService.searchToolDefinition] + toolbox.definitions
        let dump: [String: Any] = ["system": QuickSettings.defaultSystemPrompt, "tools": tools]
        let data = try JSONSerialization.data(withJSONObject: dump, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
