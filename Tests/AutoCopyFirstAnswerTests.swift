// AutoCopyFirstAnswerTests: "Copy the first answer of each chat
// automatically" copies only a Quick AI chat's first answer, never a
// follow-up and never an AI Chat window answer, and every copy of an AI
// answer is transient so the Clipboard History skips it.

import AppKit
import Foundation
import Testing
@testable import QuickLaunch

@Suite("Auto-copy takes the first answer, transient", .serialized)
@MainActor
struct AutoCopyFirstAnswerTests {

    private func make(
        autoCopy: Bool = true,
        pasteboard: FakePasteboard,
        service: MockQuickService,
        configure: (inout QuickSettings) -> Void = { _ in }
    ) -> QuickViewModel {
        var settings = QuickSettings()
        settings.autoCopy = autoCopy
        settings.historyEnabled = false
        configure(&settings)
        return QuickViewModel(settings: settings, service: service, pasteboard: pasteboard)
    }

    private func ask(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String, reply: String) async {
        await mock.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    // MARK: - Quick AI: the first answer only

    @Test func theFirstAnswerOfAQuickAIChatIsCopiedAsTransient() async {
        let pasteboard = FakePasteboard(string: "mine")
        let mock = MockQuickService()
        let vm = make(pasteboard: pasteboard, service: mock)
        vm.openQuickAI()

        await ask(vm, mock, "hello", reply: "Bonjour")

        #expect(pasteboard.string == "Bonjour")
        #expect(pasteboard.isTransient, "an AI answer never lands in Clipboard History")
        #expect(pasteboard.transientWriteCount == 1)
        #expect(vm.justCopied)
    }

    @Test func aFollowUpNeverReplacesTheClipboard() async {
        let pasteboard = FakePasteboard()
        let mock = MockQuickService()
        let vm = make(pasteboard: pasteboard, service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "hello", reply: "Bonjour")
        // The user copies something of their own after the first answer.
        pasteboard.writeString("my own copy")

        await ask(vm, mock, "and in Spanish?", reply: "Hola")

        #expect(vm.output == "Hola")
        #expect(pasteboard.string == "my own copy", "a follow-up leaves the clipboard alone")
        #expect(pasteboard.transientWriteCount == 1)
    }

    @Test func aNewChatCopiesItsFirstAnswerAgain() async {
        let pasteboard = FakePasteboard()
        let mock = MockQuickService()
        let vm = make(pasteboard: pasteboard, service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "hello", reply: "Bonjour")
        await ask(vm, mock, "again", reply: "Encore")
        #expect(pasteboard.string == "Bonjour")

        vm.startNewConversation()
        await ask(vm, mock, "thanks", reply: "Merci")

        #expect(pasteboard.string == "Merci")
        #expect(pasteboard.transientWriteCount == 2)
    }

    @Test func askingTheFirstTurnAgainCopiesTheNewAnswer() async {
        let pasteboard = FakePasteboard()
        let mock = MockQuickService()
        let vm = make(pasteboard: pasteboard, service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "hello", reply: "Bonjour")

        await mock.setResponses([StreamDelta(text: "Salut", finishReason: "stop")])
        await vm.regenerateLastAnswer()

        #expect(vm.output == "Salut")
        #expect(pasteboard.string == "Salut", "the first answer, asked again, is still the first")
        #expect(pasteboard.isTransient)
    }

    @Test func autoCopyOffCopiesNothing() async {
        let pasteboard = FakePasteboard(string: "mine")
        let mock = MockQuickService()
        let vm = make(autoCopy: false, pasteboard: pasteboard, service: mock)
        vm.openQuickAI()

        await ask(vm, mock, "hello", reply: "Bonjour")

        #expect(pasteboard.string == "mine")
        #expect(pasteboard.writeCount == 0)
    }

    // MARK: - Local and command answers follow the same rule

    @Test func aLocalAnswerInAChatIsCopiedOnlyWhenItIsTheFirst() async {
        let pasteboard = FakePasteboard()
        let vm = make(pasteboard: pasteboard, service: MockQuickService())
        vm.openQuickAI()

        vm.input = "2+2"
        await vm.submit()
        #expect(vm.output == "4")
        #expect(pasteboard.string == "4")
        #expect(pasteboard.isTransient)

        vm.input = "3+3"
        await vm.submit()
        #expect(vm.output == "6")
        #expect(pasteboard.string == "4", "the second answer in the chat is a follow-up")
        #expect(pasteboard.transientWriteCount == 1)
    }

    @Test func aRootAnswerIsCopiedAsTransient() async {
        let pasteboard = FakePasteboard()
        let vm = make(pasteboard: pasteboard, service: MockQuickService())

        vm.input = "10/2"
        await vm.submit()

        #expect(vm.rootAnswer?.answer == "5")
        #expect(pasteboard.string == "5")
        #expect(pasteboard.isTransient)
    }

    @Test func aCommandAfterAnAnswerIsAFollowUp() async {
        let pasteboard = FakePasteboard()
        let mock = MockQuickService()
        let vm = make(pasteboard: pasteboard, service: mock) { settings in
            settings.savedPrompts.append(SavedPrompt(
                name: "Echo It",
                alias: "echo-it",
                prompt: "{input}",
                commandExecutable: "/bin/echo",
                commandArguments: ["{input}"]
            ))
        }
        vm.openQuickAI()
        await ask(vm, mock, "first", reply: "One.")
        #expect(pasteboard.string == "One.")

        vm.input = "/echo-it hello"
        await vm.submit()

        #expect(vm.output.contains("hello"))
        #expect(pasteboard.string == "One.", "a command in a chat with an answer is a follow-up")
        #expect(pasteboard.transientWriteCount == 1)
    }

    // MARK: - The AI Chat window never auto-copies

    @Test func theAIChatWindowNeverAutoCopies() async {
        let launcherPasteboard = FakePasteboard()
        let chatPasteboard = FakePasteboard(string: "mine")
        let mock = MockQuickService()
        let launcher = make(pasteboard: launcherPasteboard, service: mock)
        let chat = QuickViewModel(store: launcher.store, service: mock, pasteboard: chatPasteboard)
        let suite = "AutoCopyFirstAnswerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        #expect(chat.isAIChatWindow)
        #expect(chat.settings.autoCopy, "the setting is on; the window still does not copy")

        await ask(chat, mock, "hello", reply: "Bonjour")
        await ask(chat, mock, "again", reply: "Encore")

        #expect(chat.output == "Encore")
        #expect(chatPasteboard.string == "mine")
        #expect(chatPasteboard.writeCount == 0)

        // Return on the finished answer (Copy Response) copies, transient.
        chat.input = ""
        await chat.runPrimaryAnswerAction()
        #expect(chatPasteboard.string == "Encore")
        #expect(chatPasteboard.isTransient)
        _ = window
    }

    // MARK: - Copy Answer, Copy Chat, Copy Last Answer are transient

    @Test func copyAnswerAndCopyChatAreTransient() async {
        let pasteboard = FakePasteboard()
        let mock = MockQuickService()
        let vm = make(autoCopy: false, pasteboard: pasteboard, service: mock)
        vm.openQuickAI()
        await ask(vm, mock, "hello", reply: "Bonjour")

        vm.copyAnswerOnSurface()
        #expect(pasteboard.string == "Bonjour")
        #expect(pasteboard.isTransient)

        vm.copyChatTranscript()
        #expect(pasteboard.string?.contains("Bonjour") == true)
        #expect(pasteboard.string?.contains("hello") == true)
        #expect(pasteboard.isTransient)
        #expect(pasteboard.transientWriteCount == 2)
    }

    @Test func copyLastAnswerIsTransientAndASnippetIsKept() async {
        let pasteboard = FakePasteboard()
        let vm = make(pasteboard: pasteboard, service: MockQuickService())

        let chat = LauncherCatalogItem(
            kind: .conversation,
            itemID: UUID().uuidString,
            title: "Greeting",
            detail: "",
            value: "Bonjour"
        )
        #expect(await vm.copyLauncherItem(chat))
        #expect(pasteboard.string == "Bonjour")
        #expect(pasteboard.isTransient, "Copy Last Answer copies an AI answer")

        // A snippet is the user's own text: Clipboard History records it.
        let snippet = LauncherCatalogItem(
            kind: .snippet,
            itemID: "sig",
            title: "Signature",
            detail: "",
            value: "Best, T."
        )
        #expect(await vm.copyLauncherItem(snippet))
        #expect(pasteboard.string == "Best, T.")
        #expect(!pasteboard.isTransient)
    }

    // MARK: - The real pasteboard: markers the Clipboard History honours

    private func scratchPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-launch-autocopy-\(UUID().uuidString)"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func scratchStore() -> (ClipboardHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-autocopy-\(UUID().uuidString)")
            .appendingPathComponent("clipboard-history.json")
        return (ClipboardHistoryStore(fileURL: url), url)
    }

    @Test func aTransientWriteCarriesBothMarkersAndIsNotRecorded() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        let (store, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        SystemPasteboard(pasteboard: pasteboard).writeTransientString("Bonjour")

        #expect(pasteboard.string(forType: .string) == "Bonjour", "still one Command-V away")
        let types = pasteboard.types ?? []
        #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")))
        #expect(types.contains(NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")))
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.isEmpty, "the Clipboard History skips an AI answer")

        // A kept write afterwards records as usual.
        SystemPasteboard(pasteboard: pasteboard).writeString("my own copy")
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.map(\.value) == ["my own copy"])
    }

    @Test func aCodeBlockCopyIsTransient() {
        let pasteboard = scratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        let (store, url) = scratchStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        CodeBlockView.writeToPasteboard("let x = 42", pasteboard: pasteboard)

        #expect(pasteboard.string(forType: .string) == "let x = 42")
        store.capture(from: pasteboard, limit: 10)
        #expect(store.entries.isEmpty)
    }
}
