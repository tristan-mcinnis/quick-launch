import AppKit
import Foundation
import HouseChatCore
import Testing
@testable import QuickLaunch

// `cos tell`: the pinned chat's every message goes to it (with the card it
// is about), an answer shows as a reply and a proposal as its card, focused,
// under the message. Discuss opens a branch: an ordinary chat linked to the
// pinned conversation and the card, seeded with the card, its files, the
// charter core and the project; each branch message also goes to
// `cos tell --surface branch`, and the branch merges back as one line under
// the card. `RecordingCosRunner.tellJSON` stands in for the model.

@Suite("Chief of Staff tell: the contract")
struct ChiefOfStaffTellContractTests {
    @Test func tellIsAnArgumentArrayWithTheTextOnStdin() throws {
        let pinned = CosCommand.tell(text: "Charlie approved; close it", card: "ee55ff66", surface: .pinned)
        #expect(try pinned.arguments() == ["tell", "-", "--surface", "quick-launch", "--card", "ee55ff66", "--json"])
        #expect(pinned.stdin == Data("Charlie approved; close it".utf8))
        #expect(pinned.timeout == 200)
        let branch = CosCommand.tell(text: "x", card: nil, surface: .branch)
        #expect(try branch.arguments() == ["tell", "-", "--surface", "branch", "--json"])
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

    /// A card a branch made never reaches the model as a turn: its system
    /// message lists the cards instead.
    @Test @MainActor func aChiefOfStaffReplyIsLeftOutOfModelRequests() {
        let messages = [
            QuickMessage(role: .user, content: "Charlie approved it."),
            QuickMessage(role: .assistant, content: "I will close the costing card."),
            QuickMessage(role: .assistant, content: "Chief of Staff: Got it.", cosTell: CosTold(card: "ee55ff66")),
            QuickMessage(role: .user, content: "Thanks. What next?"),
        ]
        #expect(QuickViewModel.answeredTurns(messages).map(\.content) == [
            "Charlie approved it.", "I will close the costing card.", "Thanks. What next?",
        ])
    }

    @Test func theBranchInstructionTakesTristanAtHisWordWithFullContext() {
        let text = ChiefOfStaffPrompt.branchInstructions
        #expect(text.contains("Tristan's statements are true."))
        #expect(text.contains("Never ask him to prove what he says"))
        #expect(text.contains("say in one line what you will do"))
        #expect(!text.contains("—"))
        let card = Proposal(id: "ee55ff66", message: "Alex asks who owns the ops rota.", tier: "today")
        let made = Proposal(id: "ab12cd34", message: "Close the rota task.", tier: "today")
        let message = ChiefOfStaffPrompt.branchMessage(card: card, project: "Ops Desk", charter: "WATCH\n- Client mail", made: [made])
        #expect(message.contains("PROJECT\nOps Desk"))
        #expect(message.contains("THE CARD\n[ee55ff66]"))
        #expect(message.contains("- Client mail"))
        #expect(message.contains("CARDS THIS BRANCH MADE\n[ab12cd34]"))
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

    @Test func branchKeysAreCloseAndTheCardsOwn() {
        func route(_ key: VirtualKey?, _ characters: String?, _ modifiers: NSEvent.ModifierFlags, _ place: ChiefOfStaffKeys.Place) -> ChiefOfStaffKeys.Action? {
            ChiefOfStaffKeys.routeBranch(key: key, characters: characters, modifiers: modifiers, place: place)
        }
        #expect(route(nil, "w", [.command, .shift], .composer(draftIsEmpty: false)) == .closeBranch)
        #expect(route(nil, "W", [.command, .shift], .card(board: false)) == .closeBranch)
        #expect(route(.return, "\r", [.command, .shift], .composer(draftIsEmpty: false)) == nil)
        #expect(route(.return, "\r", [.command], .composer(draftIsEmpty: false)) == nil)
        #expect(route(.upArrow, nil, [], .composer(draftIsEmpty: true)) == nil)
        #expect(route(.return, "\r", [.command], .card(board: false)) == .doIt)
        #expect(route(.downArrow, nil, [], .card(board: false)) == .toComposer)
        #expect(route(nil, "d", [.command], .card(board: false)) == .discuss)
        // The pinned conversation's own keys do nothing here.
        #expect(route(nil, "1", [.command, .option], .card(board: false)) == nil)
        #expect(route(nil, "n", [.command], .card(board: false)) == nil)
    }

    /// The thread's branch turns: the link lists the card's branches, the
    /// merge-back line sits under its card, and a branch's own tell turns
    /// stay out of the pinned history.
    @Test func branchTurnsReadAsLinksAndMergeBackLines() throws {
        let branch = UUID()
        func turn(_ id: String, role: TurnRole = .assistant, _ text: String, _ values: [String: String]) -> TurnRecord {
            var fields = ExtraFields()
            for (key, value) in values { fields[key] = .string(value) }
            return TurnRecord(id: id, role: role, text: text, appPayload: AppPayload(namespace: ChiefOfStaffThread.namespace, values: fields))
        }
        var record = try ChiefOfStaffThread.decode(CosFixture.data())
        record.turns += [
            turn("b1", "Branch opened: Budget", ["kind": "branch", "card": "aa11bb22", "branch": branch.uuidString]),
            turn("b2", role: .user, "Charlie approved it.", ["kind": "chat", "surface": "branch"]),
            turn("b3", "Discussed: Budget approved · 2 actions done",
                 ["kind": "branch_summary", "card": "aa11bb22", "branch": branch.uuidString, "turns": "4"]),
        ]
        let items = ChiefOfStaffThread.items(in: record)
        #expect(ChiefOfStaffThread.branches(in: items) == ["aa11bb22": [branch]])
        let history = ChiefOfStaffThread.history(in: items)
        #expect(!history.contains { $0.id == "b1" || $0.id == "b2" })
        let earlier = ChiefOfStaffThread.earlier(history, in: items).map(\.id)
        let card = try #require(earlier.firstIndex(of: record.turns.first { $0.appPayload?.values["id"]?.stringValue == "aa11bb22" }?.id ?? ""))
        #expect(earlier[card + 1] == "b3")
    }

    /// A branch's archived record links to the pinned conversation and its
    /// card; an ordinary chat's links to nothing; a rewrite keeps the links.
    @Test func aBranchRecordCarriesItsSessionLinks() {
        let branch = QuickConversation(providerID: UUID(), model: "m", customTitle: "Budget", cosCard: "aa11bb22")
        let links = ChatArchive.record(for: branch).sessionLinks
        #expect(links == [
            SessionLink(kind: "cos-branch-of", id: ChiefOfStaffModel.conversationID.uuidString, label: "Chief of Staff"),
            SessionLink(kind: "cos-card", id: "aa11bb22"),
        ])
        #expect(ChatArchive.record(for: QuickConversation(providerID: UUID(), model: "m")).sessionLinks.isEmpty)
        var live = ChatArchive.record(for: branch)
        let stored = live
        live.sessionLinks = []
        #expect(ChatArchive.merge(live: live, into: stored).sessionLinks == links)
        #expect(QuickViewModel.oneLine("I will close the **costing** task. Then log it.") == "I will close the costing task")
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

    /// Discuss opens a branch: linked to the pinned conversation and the
    /// card, seeded with the card, its files, the charter core and the
    /// project, on the ordinary chat's model and tools.
    private func openBranch(_ rig: Rig, card: String = "ee55ff66") async {
        rig.window.openChiefOfStaff(proposalID: card)
        rig.cos.discussFocused()
        _ = await cosWaitFor { rig.cos.charter != nil }
    }

    @Test func aBranchOpensWithFullContext() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        await openBranch(rig)
        let branch = try #require(rig.window.chat.currentConversation)
        #expect(branch.cosCard == "ee55ff66")
        #expect(branch.id != ChiefOfStaffModel.conversationID)
        #expect(rig.window.chat.attachmentTray.items.first?.name.contains("Chief of Staff") == true)
        await rig.service.setResponses([StreamDelta(text: "I will close the rota task.", finishReason: "stop")])
        await ask(rig, "Alex owns the rota from Monday.")
        let system = try #require(await rig.service.lastMessages.first)
        #expect(system.role == .system)
        #expect(system.content.contains("Tristan's statements are true."))
        #expect(system.content.contains("PROJECT\nOps Desk"))
        #expect(system.content.contains("THE CARD\n[ee55ff66]"))
        #expect(system.content.contains("TRISTAN'S CHARTER"))
        #expect(await rig.service.lastMessages.last?.content.hasSuffix("Alex owns the rota from Monday.") == true)
    }

    /// Every branch message also goes to `cos tell --card --surface branch`;
    /// the first links the branch to its card. A proposal joins the branch
    /// after the model's answer, focused; an answer adds nothing.
    @Test func branchMessagesGoToCosTellAndProposalsShowInline() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        await openBranch(rig)
        let branchID = try #require(rig.window.chat.currentConversation?.id)
        await rig.service.setDelay(.milliseconds(40))
        await rig.service.setResponses([StreamDelta(text: "I will close the rota task.", finishReason: "stop")])
        await ask(rig, "Alex owns the rota from Monday.")
        #expect(await cosWaitFor { rig.window.chat.currentConversation?.messages.last?.cosTell != nil })
        let messages = try #require(rig.window.chat.currentConversation?.messages)
        #expect(messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(messages[1].content == "I will close the rota task.")
        #expect(messages[2].content == "Chief of Staff: I will add the task and close the costing card.")
        #expect(messages[2].cosTell == CosTold(card: "ee55ff66"))
        #expect(rig.cos.focusedCardID == "ee55ff66")
        #expect(rig.window.focus == .cards)
        let writes = await rig.runner.writes
        #expect(writes.contains(.append(role: .assistant, text: "Branch opened: Alex asks who owns the ops rota",
                                        meta: ["kind": "branch", "card": "ee55ff66", "branch": branchID.uuidString])))
        #expect(writes.contains(.tell(text: "Alex owns the rota from Monday.", card: "ee55ff66", surface: .branch)))
        // The card's own keys work in the branch.
        #expect(rig.window.handleChiefOfStaffKey(key: .return, characters: "\r", modifiers: [.command]))
        #expect(await cosWaitFor { rig.cos.card("ee55ff66").outcome != nil })
        // A question: the model answers, and no card joins; no second link.
        await rig.service.setDelay(.zero)
        rig.window.focusComposer()
        await ask(rig, "Who else is on the rota?")
        #expect(await cosWaitFor { rig.cos.telling.isEmpty })
        #expect(rig.window.chat.currentConversation?.messages.last?.cosTell == nil)
        let links = await rig.runner.writes.filter { if case .append(_, _, let meta) = $0 { meta["kind"] == "branch" } else { false } }
        #expect(links.count == 1)
    }

    /// Close branch (⇧⌘W) merges it back as one line under the card, then
    /// the pinned conversation opens. A Do it on a card the branch made
    /// merges it too. Reopening the card continues the branch.
    /// The merge-back lines written so far, once `count` of them are.
    private func summaries(_ rig: Rig, count: Int = 1) async -> [CosCommand] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var found: [CosCommand] = []
        repeat {
            found = await rig.runner.writes.filter {
                if case .append(_, _, let meta) = $0 { meta["kind"] == "branch_summary" } else { false }
            }
            if found.count >= count { return found }
            try? await Task.sleep(for: .milliseconds(2))
        } while ContinuousClock.now < deadline
        Issue.record("only \(found.count) merge-back lines")
        return found
    }

    @Test func aBranchMergesBackAndContinues() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        await openBranch(rig)
        let branchID = try #require(rig.window.chat.currentConversation?.id)
        await rig.service.setResponses([StreamDelta(text: "Understood. I will close the rota task.", finishReason: "stop")])
        await ask(rig, "Alex owns the rota from Monday.")
        #expect(await cosWaitFor { rig.window.chat.currentConversation?.messages.last?.cosTell != nil })
        rig.window.focusComposer()
        #expect(rig.window.handleChiefOfStaffKey(key: nil, characters: "w", modifiers: [.command, .shift]))
        #expect(rig.window.isChiefOfStaffOpen)
        let summary = CosCommand.append(
            role: .assistant, text: "Discussed: Alex asks who owns the ops rota · 0 actions done",
            meta: ["kind": "branch_summary", "card": "ee55ff66", "branch": branchID.uuidString, "turns": "3"]
        )
        #expect(await summaries(rig) == [summary])
        // A Do it on the branch's card merges it back again, at once.
        rig.window.chat.chiefOfStaffCardDone("ee55ff66")
        #expect(await summaries(rig, count: 2).count == 2)
        // Reopening the card continues the branch.
        #expect(rig.cos.branch(for: "ee55ff66") == branchID)
        rig.window.openChiefOfStaff(proposalID: "ee55ff66")
        rig.cos.discussFocused()
        #expect(rig.window.chat.currentConversation?.id == branchID)
        // The rail nests the branch under the Chief of Staff, unnumbered.
        let items = rig.window.railItems
        #expect(items.first.map { AIChatWindowModel.isChiefOfStaffItem($0.itemID) } == true)
        #expect(items[1].itemID == branchID.uuidString)
        #expect(rig.window.isNestedBranch(items[1]))
        #expect(rig.window.railNumber(at: 1) == nil)
    }

    /// An ordinary chat is not a branch: no tell, no branch keys, no system
    /// message.
    @Test func anOrdinaryChatIsNotABranch() async throws {
        let rig = try await rig()
        defer { rig.loop.cancel() }
        rig.window.open(handoff: nil)
        #expect(rig.window.discussedCardID == nil)
        await rig.service.setResponses([StreamDelta(text: "Friday.", finishReason: "stop")])
        await ask(rig, "Ship Friday?")
        #expect(!rig.window.handleChiefOfStaffKey(key: nil, characters: "w", modifiers: [.command, .shift]))
        #expect(await rig.runner.writes.isEmpty)
        #expect(await rig.service.lastMessages.first?.role != .system)
        #expect(rig.cos.systemMessage(forChat: UUID(), discussing: nil) == nil)
    }
}
