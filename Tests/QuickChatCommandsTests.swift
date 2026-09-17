import Testing
import Foundation
@testable import QuickLaunch

/// The built-in slash commands, routed before any prompt alias.
@Suite("Quick chat commands")
struct QuickChatCommandsTests {
    private let router = QuickChatCommandRouter.standard

    @Test func newIsRecognizedCaseInsensitivelyAndTrimmed() {
        #expect(router.route("/new") == .newChat)
        #expect(router.route("/NEW") == .newChat)
        #expect(router.route("  /New  ") == .newChat)
    }

    @Test func clearIsRecognized() {
        #expect(router.route("/clear") == .clearChat)
        #expect(router.route("/Clear") == .clearChat)
    }

    @Test func anUnknownSlashLineStaysLocal() {
        guard case .unknownCommand(let raw, let message) = router.route("/notacommand extra") else {
            Issue.record("an unknown slash line must be refused locally")
            return
        }
        #expect(raw == "/notacommand")
        #expect(message.contains("/notacommand"))
        #expect(message.contains("/new"))
    }

    @Test func plainTextIsNotACommand() {
        #expect(router.route("hello there") == .notACommand)
        #expect(router.route("") == .notACommand)
        #expect(router.route("   ") == .notACommand)
    }

    @Test func aKnownAppCommandIsPassedThrough() {
        let rt = QuickChatCommandRouter(knownCommands: ["/meeting"])
        guard case .appCommand(let name, let arguments) = rt.route("/meeting weekly sync") else {
            Issue.record("a known app command must be routed")
            return
        }
        #expect(name == "/meeting")
        #expect(arguments == ["weekly", "sync"])
    }

    @Test func aBuiltinIsNeverShadowedByAnAlias() {
        let aliased = QuickChatCommandRouter(aliases: ["/reset": "/clear", "/new": "/meeting"])
        #expect(aliased.route("/reset") == .clearChat)
        #expect(aliased.route("/new") == .newChat, "a builtin wins over an alias")
    }
}

/// The view-model integration: `/new` and `/clear` stay local, keep history,
/// and the same refused line sent again becomes ordinary prompt text.
@Suite("Quick chat command integration", .serialized)
@MainActor
struct QuickChatCommandIntegrationTests {
    private func conversation() -> QuickConversation {
        QuickConversation(
            id: UUID(),
            providerID: UUID(),
            model: "deepseek-chat",
            messages: [QuickMessage(role: .user, content: "first question")]
        )
    }

    @Test func aPathQuestionIsNotACommand() {
        #expect(QuickViewModel.looksLikeCommand("/new"))
        #expect(QuickViewModel.looksLikeCommand("/run-echo"))
        #expect(QuickViewModel.looksLikeCommand("/translate"))
        #expect(!QuickViewModel.looksLikeCommand("/etc/hosts"))
        #expect(!QuickViewModel.looksLikeCommand("/"))
        #expect(!QuickViewModel.looksLikeCommand("hello"))
    }

    @Test func newKeepsTheOldChatInHistoryAndStartsFresh() async {
        let vm = QuickViewModel()
        vm.settings.autoCopy = false
        vm.settings.historyEnabled = true
        let open = conversation()
        vm.currentConversation = open
        vm.history = [open]

        vm.input = "/new"
        await vm.submit()

        #expect(vm.currentConversation == nil, "the surface starts fresh")
        #expect(vm.history.contains { $0.id == open.id }, "the old chat stays in history")
        #expect(vm.output.isEmpty)
        #expect(vm.threadNotice == "New chat")
    }

    @Test func clearClearsTheSurfaceAndKeepsHistory() async {
        let vm = QuickViewModel()
        vm.settings.autoCopy = false
        let open = conversation()
        vm.currentConversation = open
        vm.history = [open]

        vm.input = "/clear"
        await vm.submit()

        #expect(vm.currentConversation == nil)
        #expect(vm.history.contains { $0.id == open.id })
        #expect(vm.threadNotice == "Chat cleared")
    }

    @Test func anUnknownSlashLineIsNeverSentToTheModel() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "should not run", finishReason: .some("stop"))])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false

        vm.input = "/bogus"
        await vm.submit()

        #expect(vm.errorMessage?.contains("/bogus") == true)
        #expect(vm.output.isEmpty)
        #expect(await service.sendCallCount == 0)
    }

    @Test func anUnknownSlashLineStaysLocalOnEveryOrdinaryReturn() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "should not run", finishReason: .some("stop"))])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.settings.historyEnabled = true

        vm.input = "/bogus"
        await vm.submit()
        #expect(vm.errorMessage?.contains("/bogus") == true)
        #expect(vm.output.isEmpty)
        #expect(await service.sendCallCount == 0)

        // Ordinary Return again is still local; only the explicit action
        // sends the text.
        await vm.submit()
        #expect(vm.output.isEmpty)
        #expect(await service.sendCallCount == 0)
    }

    @Test func theExplicitSendAsTextActionSendsTheRefusedLine() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "answered as text", finishReason: .some("stop"))])
        let vm = QuickViewModel(service: service)
        vm.settings.autoCopy = false
        vm.settings.historyEnabled = true

        vm.input = "/bogus"
        await vm.submit()
        #expect(vm.output.isEmpty)

        vm.sendRefusedCommandAsText()
        // Give the spawned task a moment to reach the service.
        var waited = 0
        while await service.sendCallCount == 0, waited < 200 {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        #expect(await service.sendCallCount == 1, "exactly one model request, from the explicit action")
        #expect(vm.output == "answered as text")
    }
}
