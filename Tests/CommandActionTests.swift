import Testing
import Foundation
@testable import QuickLaunch

/// Command-lane saved actions: a SavedPrompt with `commandExecutable` set
/// runs that binary directly (never through a shell) with `{input}`
/// substituted as a whole argv element, instead of calling a model provider.

@Suite("Command action model")
struct CommandActionModelTests {

    @Test func testLegacySavedPromptDecodesWithoutCommandFields() throws {
        let legacy = #"{"id":"3D43B22A-EC62-4A78-92AE-99C30191A404","alias":"tldr","prompt":"Summarize","outputBehavior":"showInOverlay"}"#
        let decoded = try JSONDecoder().decode(SavedPrompt.self, from: Data(legacy.utf8))
        #expect(decoded.alias == "tldr")
        #expect(decoded.commandExecutable == nil)
        #expect(decoded.commandArguments == nil)
    }

    @Test func testCommandFieldsRoundTrip() throws {
        let p = SavedPrompt(
            name: "Recall",
            alias: "recall",
            prompt: "",
            commandExecutable: "recall",
            commandArguments: ["search", "{input}"]
        )
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SavedPrompt.self, from: data)
        #expect(back.commandExecutable == "recall")
        #expect(back.commandArguments == ["search", "{input}"])
    }
}

@Suite("Command action runner")
struct CommandActionRunnerTests {

    @Test func testInputSubstitutedAsWholeArgvElement() {
        let argv = CommandActionRunner.substitutedArguments(
            ["search", "{input}", "--limit=3"],
            input: "hello world; rm -rf /"
        )
        #expect(argv == ["search", "hello world; rm -rf /", "--limit=3"])
    }

    @Test func testArgumentsWithoutPlaceholderAreUntouched() {
        let argv = CommandActionRunner.substitutedArguments(
            ["remember"],
            input: "note text"
        )
        #expect(argv == ["remember"])
    }

    @Test func testRunCapturesStdout() async throws {
        let text = try await CommandActionRunner.run(
            executable: "/bin/echo",
            arguments: ["{input}"],
            input: "hi there"
        )
        #expect(text == "hi there")
    }

    @Test func testNonZeroExitSurfacesStderrAsError() async {
        do {
            _ = try await CommandActionRunner.run(
                executable: "/bin/cat",
                arguments: ["/nonexistent-quick-launch-test-path"],
                input: ""
            )
            Issue.record("Expected a non-zero exit to throw")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("No such file"))
        }
    }

    @Test func testMissingExecutableThrows() async {
        do {
            _ = try await CommandActionRunner.run(
                executable: "definitely-not-installed-xyz",
                arguments: [],
                input: ""
            )
            Issue.record("Expected an unresolvable executable to throw")
        } catch {
            #expect(error.localizedDescription.contains("not installed"))
        }
    }
}

@MainActor
@Suite("Command action dispatch", .serialized)
struct CommandActionDispatchTests {

    @Test func testCommandActionRunsExecutableNotProvider() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "model output", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.settings.savedPromptPrefix = "/"
        vm.settings.savedPrompts = [
            SavedPrompt(
                alias: "echo",
                prompt: "",
                commandExecutable: "/bin/echo",
                commandArguments: ["{input}"]
            ),
        ]
        vm.input = "/echo hi there"
        await vm.submit()
        #expect(vm.output == "hi there")
        #expect(vm.errorMessage == nil)
        #expect(await service.sendCallCount == 0)
    }

    @Test func testPromptActionStillUsesProvider() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "model output", finishReason: .some("stop")),
        ])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.settings.savedPromptPrefix = "/"
        vm.settings.savedPrompts = [
            SavedPrompt(alias: "note", prompt: "Take note of the following."),
        ]
        vm.input = "/note remember the milk"
        await vm.submit()
        #expect(vm.output == "model output")
        #expect(await service.sendCallCount == 1)
    }

    /// Regression: the Return path (`submitResolvingFuzzyAlias`) routed typed
    /// input to the vault-search follow-up lane while an answer was on screen,
    /// before any alias resolution, so `/remember buy milk` reached a model
    /// instead of the command executable.
    @Test func testCommandAliasWinsOverAnswerFollowUpMode() async throws {
        let service = MockQuickService()
        await service.setResponses([
            StreamDelta(text: "model output", finishReason: .some("stop")),
        ])
        let vault = RecordingCommandDispatchVaultService()
        let vm = QuickViewModel(service: service, vaultSearchService: vault)
        vm.settings.autoCopy = false
        vm.settings.savedPromptPrefix = "/"
        vm.settings.savedPrompts = [
            SavedPrompt(
                alias: "remember",
                prompt: "",
                commandExecutable: "/bin/echo",
                commandArguments: ["remember", "{input}"]
            ),
        ]
        // A vault answer owns the panel; typing is normally a follow-up.
        vm.output = "Vault result"
        vm.activeVaultSearchMode = .current
        vm.vaultSearchAnchor = "old question"

        vm.input = "/remember buy milk"
        await vm.submitResolvingFuzzyAlias()

        #expect(vm.output == "remember buy milk")
        #expect(vm.errorMessage == nil)
        #expect(await service.sendCallCount == 0)
        #expect(await vault.callCount() == 0)
    }

    /// Prompt-type aliases keep the follow-up behavior: with a vault answer
    /// active, typed input (alias or not) stays in the vault conversation.
    @Test func testPromptAliasStillFollowsUpInVaultMode() async throws {
        let service = MockQuickService()
        let vault = RecordingCommandDispatchVaultService()
        let vm = QuickViewModel(service: service, vaultSearchService: vault)
        vm.settings.autoCopy = false
        vm.settings.savedPromptPrefix = "/"
        vm.settings.savedPrompts = [
            SavedPrompt(alias: "note", prompt: "Take note of the following."),
        ]
        vm.output = "Vault result"
        vm.activeVaultSearchMode = .current
        vm.vaultSearchAnchor = "old question"

        vm.input = "/note remember the milk"
        await vm.submitResolvingFuzzyAlias()

        #expect(await vault.callCount() == 1)
        #expect(await service.sendCallCount == 0)
    }

    @Test func testCommandFailureSurfacesErrorWithoutOutput() async throws {
        let service = MockQuickService()
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.settings.savedPromptPrefix = "/"
        vm.settings.savedPrompts = [
            SavedPrompt(
                alias: "fail",
                prompt: "",
                commandExecutable: "/bin/cat",
                commandArguments: ["/nonexistent-quick-launch-test-path"]
            ),
        ]
        vm.input = "/fail"
        await vm.submit()
        #expect(vm.output.isEmpty)
        #expect(vm.errorMessage?.contains("No such file") == true)
        #expect(await service.sendCallCount == 0)
    }
}

private actor RecordingCommandDispatchVaultService: VaultSearchServicing {
    private var calls = 0

    func callCount() -> Int { calls }

    func search(mode: VaultSearchMode, query: String) async throws -> String {
        calls += 1
        return "Vault result"
    }
}
