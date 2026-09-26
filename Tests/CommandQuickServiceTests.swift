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

    /// A pipe read can end in the middle of a character. The CLI's answer
    /// must arrive whole, not lose the chunk that ended mid-character.
    @Test(.timeLimit(.minutes(1)))
    func aCharacterSplitAcrossReadsArrivesWhole() async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-cli-\(UUID().uuidString).sh")
        // "中" is E4 B8 AD: the first two bytes, a pause so they are read
        // on their own, then the last byte and the rest.
        try """
        #!/bin/sh
        cat > /dev/null
        printf 'A\\344\\270'
        sleep 0.3
        printf '\\255B'
        """.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let service = try #require(CommandQuickService(
            configuration: CommandConfiguration(executable: "/bin/sh", arguments: [script.path]),
            model: "m",
            systemPrompt: ""
        ))
        var text = ""
        for try await delta in service.send(messages: [QuickMessage(role: .user, content: "hi")]) {
            text += delta.text ?? ""
        }
        #expect(text == "A中B")
    }

    @Test func utf8ChunksKeepAnIncompleteTailForTheNextRead() {
        var decoder = UTF8ChunkDecoder()
        let bytes = Array("é中😀".utf8)
        var text = ""
        for byte in bytes { text += decoder.decode(Data([byte])) }
        text += decoder.flush()
        #expect(text == "é中😀")
        // A stream that ends mid-character keeps what it had, marked.
        var cut = UTF8ChunkDecoder()
        #expect(cut.decode(Data([0x41, 0xE4, 0xB8])) == "A")
        #expect(cut.flush() == "\u{FFFD}")
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
