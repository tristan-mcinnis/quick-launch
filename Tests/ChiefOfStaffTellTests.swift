import AppKit
import Foundation
import Testing
@testable import QuickLaunch

// `cos tell`: the pinned chat's every message goes to it (with the card it
// is about), an answer shows as a reply and a proposal as its card, focused,
// under the message; a Discuss chat keeps the ordinary chat with the Discuss
// instruction and adds Tell Chief of Staff. Built against the contract shape
// `{kind: answer|proposal, text, card?}` with `RecordingCosRunner.tellJSON`.

@Suite("Chief of Staff tell: the contract")
struct ChiefOfStaffTellContractTests {
    @Test func tellIsAnArgumentArrayWithTheTextOnStdin() throws {
        let pinned = CosCommand.tell(text: "Charlie approved; close it", card: "ee55ff66", surface: .pinned)
        #expect(try pinned.arguments() == ["tell", "-", "--surface", "quick-launch", "--card", "ee55ff66", "--json"])
        #expect(pinned.stdin == Data("Charlie approved; close it".utf8))
        #expect(pinned.timeout == 200)
        let discuss = CosCommand.tell(text: "x", card: nil, surface: .discuss)
        #expect(try discuss.arguments() == ["tell", "-", "--surface", "discuss", "--json"])
    }

    @Test func theReplyReadsAsAnAnswerOrAProposal() throws {
        let answer = try CosTellReply.parse(CosResult(exitCode: 0, stdout: #"{"kind": "answer", "text": "Two wait."}"#, stderr: ""))
        #expect(answer == CosTellReply(kind: .answer, text: "Two wait."))
        let proposal = try CosTellReply.parse(CosResult(
            exitCode: 0, stdout: #"{"kind": "proposal", "text": "I will close it.", "card": "ab12cd34"}"#, stderr: ""
        ))
        #expect(proposal == CosTellReply(kind: .proposal, text: "I will close it.", card: "ab12cd34"))
        // A proposal without a card, or a kind this app does not know, is an answer.
        #expect(try CosTellReply.parse(CosResult(exitCode: 0, stdout: #"{"kind": "proposal", "text": "Hm."}"#, stderr: "")).kind == .answer)
        #expect(try CosTellReply.parse(CosResult(exitCode: 0, stdout: #"{"kind": "note", "text": "Hm."}"#, stderr: "")).kind == .answer)
        // An empty reply still answers the question.
        #expect(try CosTellReply.parse(CosResult(exitCode: 0, stdout: #"{"kind": "proposal", "text": "", "card": "c"}"#, stderr: "")).text
            == "I made a card for this.")
    }

    @Test func aFailedTellSaysWhyInOneLine() {
        #expect(throws: QuickServiceError.self) {
            try CosTellReply.parse(CosResult(exitCode: 1, stdout: "", stderr: "Traceback\nbudget spent: 40 maker calls today\n"))
        }
        do {
            _ = try CosTellReply.parse(CosResult(exitCode: 1, stdout: "", stderr: "budget spent: 40 maker calls today\n"))
        } catch {
            #expect(error.localizedDescription == "budget spent: 40 maker calls today")
        }
        #expect(throws: QuickServiceError.self) { try CosTellReply.parse(CosResult(exitCode: 0, stdout: "not json", stderr: "")) }
    }

    @Test func attachedFilesAndLinksGoInAsAttachedLines() {
        let file = ChatAttachmentRef(kind: .pdf, name: "costing.pdf", path: "/Users/user/Downloads/costing.pdf")
        let link = ChatAttachmentRef(kind: .link, name: "Brief", url: URL(string: "https://example.com/brief"))
        let picture = ChatAttachmentRef(kind: .image, name: "Screenshot", path: "/tmp/shot.png")
        #expect(CosTellReply.message("  Charlie approved the costing.  ", attachments: [file, link, picture]) == """
        Charlie approved the costing.

        Attached: /Users/user/Downloads/costing.pdf
        Attached: https://example.com/brief
        """)
        #expect(CosTellReply.message("Close it.", attachments: []) == "Close it.")
    }

    /// A Tell reply after an answer never reaches a model: turns alternate.
    @Test @MainActor func aChiefOfStaffReplyAfterAnAnswerIsLeftOutOfModelRequests() {
        let messages = [
            QuickMessage(role: .user, content: "Charlie approved it."),
            QuickMessage(role: .assistant, content: "I will close the costing card."),
            QuickMessage(role: .assistant, content: "Made a card.", cosTell: CosTold(card: "ee55ff66")),
            QuickMessage(role: .user, content: "Thanks. What next?"),
        ]
        #expect(QuickViewModel.answeredTurns(messages).map(\.content) == [
            "Charlie approved it.", "I will close the costing card.", "Thanks. What next?",
        ])
        // Told from the draft, the reply is that question's answer.
        let told = [
            QuickMessage(role: .user, content: "Close it."),
            QuickMessage(role: .assistant, content: "Made a card.", cosTell: CosTold(card: "ee55ff66")),
        ]
        #expect(QuickViewModel.answeredTurns(told).count == 2)
    }

    @Test func theDiscussInstructionTakesTristanAtHisWord() {
        let text = ChiefOfStaffPrompt.discussInstructions
        #expect(text.contains("Tristan's statements are true."))
        #expect(text.contains("Never ask him to prove what he says"))
        #expect(text.contains("say in one line what you will do"))
        #expect(text.contains("Tell Chief of Staff"))
        #expect(!text.contains("—"))
        let card = Proposal(id: "ee55ff66", message: "Alex asks who owns the ops rota.", tier: "today")
        #expect(ChiefOfStaffPrompt.discussMessage(card: card).contains("[ee55ff66]"))
    }

    @Test func typingOrReturnOnACardStartsAMessageAboutIt() {
        func route(_ key: VirtualKey?, _ characters: String?, _ modifiers: NSEvent.ModifierFlags = [], conflict: Bool = false) -> ChiefOfStaffKeys.Action? {
            ChiefOfStaffKeys.route(key: key, characters: characters, modifiers: modifiers, place: .card(board: false), hasCards: true, onConflict: conflict)
        }
        #expect(route(.return, "\r") == .reply(nil))
        #expect(route(nil, "w") == .reply("w"))
        #expect(route(nil, "W", [.shift]) == .reply("W"))
        #expect(route(nil, "3") == .reply("3"))
        // A conflict card's 1 and 2 still forget; ⌘ keys are still the card's.
        #expect(route(nil, "1", conflict: true) == .forgetConflict(0))
        #expect(route(.return, "\r", [.command]) == .doIt)
        #expect(route(nil, "e", [.command]) == .edit)
        // Space, tab, delete and the arrows never start a message.
        #expect(route(nil, " ") == nil)
        #expect(route(nil, "\t") == nil)
        #expect(route(.delete, "\u{7F}") == nil)
        #expect(route(.upArrow, "\u{F700}") == .move(-1))
    }

    @Test func discussKeysAreTellAndTheToldCardsOwn() {
        func route(_ key: VirtualKey?, _ characters: String?, _ modifiers: NSEvent.ModifierFlags, _ place: ChiefOfStaffKeys.Place) -> ChiefOfStaffKeys.Action? {
            ChiefOfStaffKeys.routeDiscuss(key: key, characters: characters, modifiers: modifiers, place: place)
        }
        #expect(route(.return, "\r", [.command, .shift], .composer(draftIsEmpty: false)) == .tell)
        #expect(route(.return, "\r", [.command], .composer(draftIsEmpty: false)) == nil)
        #expect(route(.upArrow, nil, [], .composer(draftIsEmpty: true)) == nil)
        #expect(route(.return, "\r", [.command], .card(board: false)) == .doIt)
        #expect(route(.downArrow, nil, [], .card(board: false)) == .toComposer)
        #expect(route(nil, "d", [.command], .card(board: false)) == .discuss)
        // The pinned conversation's own keys do nothing here.
        #expect(route(nil, "1", [.command, .option], .card(board: false)) == nil)
        #expect(route(nil, "n", [.command], .card(board: false)) == nil)
    }
}

@Suite("Chief of Staff tell: the window", .serialized)
@MainActor
struct ChiefOfStaffTellWindowTests {
    private struct Rig {
        let window: AIChatWindowModel
        let service: MockQuickService
        let runner: RecordingCosRunner
        let cos: ChiefOfStaffModel
        let loop: Task<Void, Never>
    }

    private func rig() async throws -> Rig {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let service = MockQuickService()
        let chat = QuickViewModel(settings: settings, service: service)
        let suite = "ChiefOfStaffTellWindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        window.window = FakeAIChatWindow()
        let runner = RecordingCosRunner()
        let cos = ChiefOfStaffModel(paths: try CosFixture.home(), runner: runner, clock: { cosNow })
        await cos.reload(force: true)
        chat.chiefOfStaff = cos
        chat.chiefOfStaffOpener = { window.openChiefOfStaff(proposalID: $0) }
        // The command loop, for Discuss's Tell (the CLI is `/usr/bin/true`).
        let loop = Task { await cos.run() }
        return Rig(window: window, service: service, runner: runner, cos: cos, loop: loop)
    }

    private func ask(_ rig: Rig, _ text: String) async {
        let before = rig.window.chat.currentConversation?.messages.count ?? 0
        rig.window.chat.input = text
        await rig.window.chat.submit()
        _ = await cosWaitFor {
            let messages = rig.window.chat.currentConversation?.messages ?? []
            return messages.count >= before + 2 && messages.last?.role == .assistant && !rig.window.chat.isStreaming
        }
    }

    /// A question is answered as a reply, and the keyboard stays in the composer.
    @Test func aQuestionIsAnsweredAsAReply() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        rig.window.openChiefOfStaff()
        await ask(rig, "What waits for me?")
        let answer = try #require(rig.window.chat.currentConversation?.messages.last)
        #expect(answer.content == "Two cards wait on you: the quote date and the ops rota.")
        #expect(answer.cosTell?.card == nil)
        #expect(rig.cos.focusedCardID == nil)
        #expect(rig.window.focus == .composer)
        #expect(await rig.service.lastMessages.isEmpty)
    }

    /// A statement becomes a card, drawn under the reply and focused, so ⌘↩
    /// does it; from the Board the view goes back to the List to show it.
    @Test func aStatementBecomesAFocusedCardUnderTheReply() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        rig.window.openChiefOfStaff()
        rig.cos.viewMode = .board
        await ask(rig, "Charlie approved the costing at 12,400. Close the costing task.")
        #expect(await rig.runner.writes.contains(.tell(
            text: "Charlie approved the costing at 12,400. Close the costing task.", card: nil, surface: .pinned
        )))
        let reply = try #require(rig.window.chat.currentConversation?.messages.last)
        #expect(reply.content == "I will add the task and close the costing card.")
        #expect(reply.cosTell == CosTold(card: "ee55ff66"))
        #expect(rig.cos.viewMode == .list)
        #expect(rig.cos.focusedCardID == "ee55ff66")
        #expect(rig.window.focus == .cards)
        #expect(rig.window.handleChiefOfStaffKey(key: .return, characters: "\r", modifiers: [.command]))
        #expect(await cosWaitFor { rig.cos.card("ee55ff66").outcome != nil })
        #expect(await rig.runner.writes.contains(.doIt(id: "ee55ff66")))
    }

    /// Typing on a card writes about it: the text goes to `cos tell --card`.
    @Test func typingOnACardSendsTheCardWithTheMessage() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        rig.window.openChiefOfStaff(proposalID: "cc33dd44")
        #expect(rig.window.focus == .cards)
        #expect(rig.window.handleChiefOfStaffKey(key: nil, characters: "S", modifiers: [.shift]))
        #expect(rig.window.focus == .composer)
        #expect(rig.window.chat.input == "S")
        #expect(rig.cos.subject?.id == "cc33dd44")
        await ask(rig, "Sam confirmed the date is Friday.")
        #expect(await rig.runner.writes.contains(.tell(text: "Sam confirmed the date is Friday.", card: "cc33dd44", surface: .pinned)))
        #expect(rig.cos.subjectCardID == nil)
        // Esc clears a subject before it is used.
        rig.window.focusCards("cc33dd44")
        #expect(rig.window.handleChiefOfStaffKey(key: .return, characters: "\r", modifiers: []))
        #expect(rig.cos.subjectCardID == "cc33dd44")
        #expect(rig.window.handleEscape())
        #expect(rig.cos.subjectCardID == nil)
    }

    /// Discuss keeps the ordinary chat (its provider, tools and model call)
    /// with the Discuss instruction on every request.
    @Test func aDiscussChatCarriesTheDiscussInstruction() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        rig.window.openChiefOfStaff(proposalID: "ee55ff66")
        rig.cos.discussFocused()
        #expect(rig.window.discussedCardID == "ee55ff66")
        await rig.service.setResponses([StreamDelta(text: "I will close the costing task.", finishReason: "stop")])
        await ask(rig, "Charlie approved the costing. Close it.")
        let sent = await rig.service.lastMessages
        #expect(sent.first?.role == .system)
        #expect(sent.first?.content.contains("Tristan's statements are true.") == true)
        #expect(sent.first?.content.contains("[ee55ff66]") == true)
        #expect(sent.last?.content.hasSuffix("Charlie approved the costing. Close it.") == true)
        #expect(!(await rig.runner.writes.contains { if case .tell = $0 { true } else { false } }))
    }

    /// Tell Chief of Staff (⇧⌘↩) sends the last message about the card and
    /// shows the card it made, focused, under the Chief of Staff's reply.
    @Test func tellChiefOfStaffFromDiscussShowsTheCardFocused() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        rig.window.openChiefOfStaff(proposalID: "ee55ff66")
        rig.cos.discussFocused()
        let chatID = try #require(rig.window.chat.currentConversation?.id)
        await rig.service.setResponses([StreamDelta(text: "I will close the costing task.", finishReason: "stop")])
        await ask(rig, "Charlie approved the costing. Close it.")
        #expect(rig.window.handleChiefOfStaffKey(key: .return, characters: "\r", modifiers: [.command, .shift]))
        #expect(await cosWaitFor { rig.window.chat.currentConversation?.messages.last?.cosTell != nil })
        #expect(await rig.runner.writes.contains(.tell(text: "Charlie approved the costing. Close it.", card: "ee55ff66", surface: .discuss)))
        let reply = try #require(rig.window.chat.currentConversation?.messages.last)
        #expect(reply.cosTell == CosTold(card: "ee55ff66"))
        #expect(rig.window.chat.currentConversation?.id == chatID)
        #expect(rig.cos.focusedCardID == "ee55ff66")
        #expect(rig.window.focus == .cards)
        // The card's own keys work here; the pinned conversation's do not.
        #expect(!rig.window.handleChiefOfStaffKey(key: nil, characters: "2", modifiers: [.command, .option]))
        #expect(rig.window.handleChiefOfStaffKey(key: .return, characters: "\r", modifiers: [.command]))
        #expect(await cosWaitFor { rig.cos.card("ee55ff66").outcome != nil })
        #expect(await rig.runner.writes.contains(.doIt(id: "ee55ff66")))
    }

    /// With a draft, Tell sends the draft instead, as Tristan's message.
    @Test func tellSendsTheDraftWhenThereIsOne() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        rig.window.openChiefOfStaff(proposalID: "ee55ff66")
        rig.cos.discussFocused()
        rig.window.chat.input = "Alex owns the rota from Monday."
        rig.window.tellChiefOfStaff()
        #expect(rig.window.chat.input.isEmpty)
        #expect(await cosWaitFor { rig.window.chat.currentConversation?.messages.count == 2 })
        let messages = try #require(rig.window.chat.currentConversation?.messages)
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages[0].content == "Alex owns the rota from Monday.")
        #expect(await rig.runner.writes.contains(.tell(text: "Alex owns the rota from Monday.", card: "ee55ff66", surface: .discuss)))
        #expect(await rig.service.lastMessages.isEmpty)
    }

    /// An ordinary chat has no Tell and no Discuss instruction.
    @Test func anOrdinaryChatHasNoTell() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        rig.window.open(handoff: nil)
        #expect(rig.window.discussedCardID == nil)
        rig.window.chat.input = "Ship Friday?"
        #expect(!rig.window.handleChiefOfStaffKey(key: .return, characters: "\r", modifiers: [.command, .shift]))
        rig.window.tellChiefOfStaff()
        #expect(rig.window.chat.input == "Ship Friday?")
        #expect(await rig.runner.writes.isEmpty)
        #expect(rig.cos.systemMessage(forChat: UUID(), discussing: nil) == nil)
    }
}
