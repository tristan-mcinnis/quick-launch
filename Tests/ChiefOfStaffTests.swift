// ChiefOfStaffTests — the Chief of Staff's face in Quick Launch: the `cos`
// thread as read, the waiting cards, the card keys, the `cos` argument
// arrays, the notification rules, and the pinned chat on the ordinary chat
// pipeline. The fixture was written by the real `cos/thread.py` and
// `cos append`, not typed from memory.

import AppKit
import Foundation
import HouseChatCore
import Testing
import UserNotifications
@testable import QuickLaunch

/// Records every `cos` call and answers each with success.
actor RecordingCosRunner: CosRunning {
    private(set) var commands: [CosCommand] = []
    var stdout = ""

    func run(_ command: CosCommand) async throws -> CosResult {
        commands.append(command)
        if case .status = command {
            return CosResult(exitCode: 0, stdout: #"{"paused": false, "total": 6, "pending": 2}"#, stderr: "")
        }
        return CosResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    func setStdout(_ text: String) { stdout = text }
}

/// Keeps the notices it was asked to post.
@MainActor
final class RecordingCosNotifier: ChiefOfStaffNotifying {
    var onChoice: ((ChiefOfStaffNotificationChoice) -> Void)?
    private(set) var posted: [ChiefOfStaffNotice] = []
    func prepare() async {}
    func post(_ notice: ChiefOfStaffNotice) async { posted.append(notice) }
}

enum CosFixture {
    static func data() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "chief-of-staff-thread", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    static func items() throws -> [ChiefOfStaffThreadItem] {
        ChiefOfStaffThread.items(in: try ChiefOfStaffThread.decode(data()))
    }

    /// A temporary `COS_HOME` holding the fixture thread.
    static func home() throws -> CosPaths {
        let root = FileManager.default.temporaryDirectory.appending(path: "cos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "thread"), withIntermediateDirectories: true)
        try data().write(to: root.appending(path: "thread/chief-of-staff.json"))
        return CosPaths(data: root, executable: URL(fileURLWithPath: "/usr/bin/true"))
    }
}

@Suite("Chief of Staff thread")
struct ChiefOfStaffThreadTests {
    @Test func decodesEveryTurnKindTheCLIWrites() throws {
        let items = try CosFixture.items()
        let proposals = items.compactMap(\.proposal)
        #expect(proposals.map(\.id) == ["aa11bb22", "cc33dd44", "dd00ee11", "ee55ff66", "ff77aa88", "99887766"])
        #expect(proposals.map(\.status) == [.done, .pending, .dismissed, .pending, .later, .handled])
        #expect(proposals.map(\.statusWord) == ["Done", "Waiting", "No", "Waiting", "Later", "Handled"])
        let budget = try #require(proposals.first { $0.id == "cc33dd44" })
        #expect(budget.tier == "decide")
        #expect(budget.importance == "client")
        #expect(budget.due == "2026-09-30")
        #expect(budget.headline == "Budget approved, quote due Tuesday")
        #expect(budget.actions.map(\.kind) == [.statusNote, .taskAdd, .draftReply, .taskClose])
        // A null due date is no due date.
        #expect(proposals.first { $0.id == "ee55ff66" }?.actions.first?.due == nil)
        // The empty headline falls back to the message's first line.
        #expect(proposals.first { $0.id == "ee55ff66" }?.headline == "A question in #ops waits for you.")
        let done = try #require(proposals.first)
        #expect(done.results == [Proposal.Result(type: "status_note", ok: true, detail: "wrote status note")])
    }

    @Test func waitingIsNewestFirstAndHistoryLeavesOutWaitingVerdictsAndOwnTurns() throws {
        let items = try CosFixture.items()
        #expect(ChiefOfStaffThread.waiting(in: items).map(\.id) == ["ee55ff66", "cc33dd44"])
        let history = ChiefOfStaffThread.history(in: items)
        #expect(history.compactMap(\.proposal).map(\.id) == ["aa11bb22", "dd00ee11", "ff77aa88", "99887766"])
        let chats = history.compactMap { item -> String? in
            if case .chat(_, _, let text, _, _) = item { return text }
            return nil
        }
        // `cos ask` turns show; the turns Quick Launch appended are the
        // chat's own and are drawn by its thread.
        #expect(chats == ["What is still open on sample-project?", "One proposal waits: the budget approval."])
        #expect(!history.contains { if case .verdict = $0 { true } else { false } })
    }

    @Test func recentProposalsAreTheLastTwelveInOrder() throws {
        let items = try CosFixture.items()
        #expect(ChiefOfStaffThread.recentProposals(in: items, limit: 2).map(\.id) == ["ff77aa88", "99887766"])
        #expect(ChiefOfStaffThread.recentProposals(in: items).count == 6)
    }

    @Test func aTurnFromAnotherNamespaceIsLeftOut() throws {
        var record = try ChiefOfStaffThread.decode(CosFixture.data())
        let foreign = TurnRecord(
            id: "foreign",
            role: .assistant,
            text: "Another app's turn.",
            appPayload: AppPayload(namespace: "rti", values: ExtraFields())
        )
        record.turns.append(foreign)
        #expect(!ChiefOfStaffThread.items(in: record).contains { $0.id == "foreign" })
    }
}

@Suite("Chief of Staff cos calls")
struct CosCommandTests {
    @Test func verdictsAreArgumentArrays() throws {
        #expect(try CosCommand.status.arguments() == ["status", "--json"])
        #expect(try CosCommand.doIt(id: "cc33dd44").arguments() == ["do", "cc33dd44"])
        #expect(try CosCommand.skip(id: "a", reason: nil).arguments() == ["skip", "a"])
        #expect(try CosCommand.skip(id: "a", reason: "  not mine ").arguments() == ["skip", "a", "--reason", "not mine"])
    }

    @Test func editKeepsFieldsItDoesNotEditAndDropsEmptyOnes() throws {
        let items = try CosFixture.items()
        let budget = try #require(items.compactMap(\.proposal).first { $0.id == "cc33dd44" })
        var drafts = ActionDraft.drafts(for: budget)
        drafts[1].text = "Send the revised quote; today"
        drafts[1].due = ""
        drafts[3].text = "Sign-off in the 20:16 mail"
        let arguments = try CosCommand.edit(id: budget.id, actions: drafts.map(\.action)).arguments()
        #expect(Array(arguments.prefix(3)) == ["edit", "cc33dd44", "--actions-json"])
        let json = try #require(arguments.last)
        let decoded = try JSONDecoder().decode([[String: String]].self, from: Data(json.utf8))
        #expect(decoded[1] == ["type": "task_add", "title": "Send the revised quote; today"])
        #expect(decoded[3] == ["type": "task_close", "task_id": "T-42", "what": "Sign-off in the 20:16 mail"])
        #expect(decoded[2]["body"] == "Thanks, confirmed. I will send the quote by Tuesday.")
    }

    @Test func appendSendsTheTextOnStdinAndTheSurface() throws {
        let command = CosCommand.append(role: .user, text: "a \"quoted\"; line", meta: ["attachments": "brief.pdf"])
        #expect(try command.arguments() == [
            "append", "--role", "user", "--surface", "quick-launch", "--meta", #"{"attachments":"brief.pdf"}"#, "-",
        ])
        #expect(command.stdin == Data("a \"quoted\"; line".utf8))
        #expect(try CosCommand.append(role: .assistant, text: "x", meta: [:]).arguments()
            == ["append", "--role", "assistant", "--surface", "quick-launch", "-"])
        #expect(CosCommand.doIt(id: "a").stdin == nil)
    }

    @Test func outcomeLinesReadTheCLIOutput() {
        let result = CosResult(exitCode: 1, stdout: "OK   status_note: wrote\nFAIL task_add: no project\n", stderr: "")
        #expect(OutcomeLine.lines(from: result) == [
            OutcomeLine(ok: true, text: "status_note: wrote"),
            OutcomeLine(ok: false, text: "task_add: no project"),
        ])
        #expect(OutcomeLine.lines(from: CosResult(exitCode: 1, stdout: "", stderr: "x\nno pending proposal\n"))
            == [OutcomeLine(ok: false, text: "no pending proposal")])
    }
}

@Suite("Chief of Staff keys")
struct ChiefOfStaffKeyTests {
    private func route(
        _ key: VirtualKey?,
        _ characters: String? = nil,
        _ modifiers: NSEvent.ModifierFlags = [],
        _ place: ChiefOfStaffKeys.Place,
        waiting: Bool = true
    ) -> ChiefOfStaffKeys.Action? {
        ChiefOfStaffKeys.route(key: key, characters: characters, modifiers: modifiers, place: place, hasWaiting: waiting)
    }

    @Test func theComposerReachesTheCardsWithoutTakingTheDraftsKeys() {
        #expect(route(.upArrow, nil, [], .composer(draftIsEmpty: true)) == .focusCards)
        #expect(route(.upArrow, nil, [.option], .composer(draftIsEmpty: false)) == .focusCards)
        // A draft keeps its bare arrows; nothing waits, nothing moves.
        #expect(route(.upArrow, nil, [], .composer(draftIsEmpty: false)) == nil)
        #expect(route(.upArrow, nil, [], .composer(draftIsEmpty: true), waiting: false) == nil)
        #expect(route(.downArrow, nil, [], .composer(draftIsEmpty: true)) == nil)
        #expect(route(.return, nil, [.command], .composer(draftIsEmpty: false)) == nil)
    }

    @Test func aFocusedCardTakesItsActionKeys() {
        #expect(route(.downArrow, nil, [], .card) == .move(1))
        #expect(route(.upArrow, nil, [.option], .card) == .move(-1))
        #expect(route(.return, nil, [.command], .card) == .doIt)
        #expect(route(.keypadEnter, nil, [.command], .card) == .doIt)
        #expect(route(nil, "e", [.command], .card) == .edit)
        #expect(route(.delete, nil, [.command], .card) == .skip)
        #expect(route(.escape, nil, [], .card) == .toComposer)
        // A bare Return or Delete never decides a card.
        #expect(route(.return, nil, [], .card) == nil)
        #expect(route(.delete, nil, [], .card) == nil)
        // Caps lock and fn are noise.
        #expect(route(.return, nil, [.command, .capsLock], .card) == .doIt)
    }

    @Test func editingRunsOrCancelsAndLeavesTypingAlone() {
        #expect(route(.return, nil, [.command], .editing) == .runEdit)
        #expect(route(.escape, nil, [], .editing) == .cancelEdit)
        #expect(route(.return, nil, [], .editing) == nil)
        #expect(route(nil, "e", [.command], .editing) == nil)
        #expect(route(.delete, nil, [.command], .editing) == nil)
        #expect(route(.upArrow, nil, [], .editing) == nil)
    }
}

@Suite("Chief of Staff notifications")
struct ChiefOfStaffNotificationTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    private func card(
        _ id: String,
        kind: String = "email",
        importance: String = "client",
        project: String = "globex",
        due: String? = nil,
        message: String = "A note.",
        actions: [ProposalAction] = [ProposalAction(type: "status_note", fields: ["note": "x"])]
    ) -> Proposal {
        Proposal(id: id, project: project, eventKind: kind, message: message, importance: importance, due: due, actions: actions)
    }

    @Test func quietHoursRunFromElevenToSeven() {
        let quiet = QuietHours.standard
        #expect(quiet.contains(at(23, 23), calendar: calendar))
        #expect(quiet.contains(at(24, 0), calendar: calendar))
        #expect(quiet.contains(at(24, 6), calendar: calendar))
        #expect(!quiet.contains(at(24, 7), calendar: calendar))
        #expect(!quiet.contains(at(23, 22), calendar: calendar))
    }

    @Test func nothingIsPostedInQuietHours() {
        #expect(ChiefOfStaffNotificationRules.notices(for: [card("a")], now: at(23, 23), calendar: calendar).isEmpty)
    }

    @Test func onlyAClientEmailWithADateWithin48HoursIsTimeSensitive() {
        let now = at(23, 10)
        #expect(ChiefOfStaffNotificationRules.urgency(of: card("a", due: "2026-09-24"), now: now, calendar: calendar) == .timeSensitive)
        #expect(ChiefOfStaffNotificationRules.urgency(of: card("a", due: "2026-09-23"), now: now, calendar: calendar) == .timeSensitive)
        #expect(ChiefOfStaffNotificationRules.urgency(of: card("a", due: "2026-10-09"), now: now, calendar: calendar) == .active)
        #expect(ChiefOfStaffNotificationRules.urgency(of: card("a", importance: "team", due: "2026-09-24"), now: now, calendar: calendar) == .active)
        #expect(ChiefOfStaffNotificationRules.urgency(of: card("a", kind: "slack", due: "2026-09-24"), now: now, calendar: calendar) == .active)
        #expect(ChiefOfStaffNotificationRules.urgency(of: card("a"), now: now, calendar: calendar) == .active)
    }

    @Test func aDateNamedInTheTextCounts() {
        // Relative to the real clock, as the detector reads it.
        let now = Date()
        let tomorrow = card("a", message: "Can you confirm the deck by tomorrow at 3pm?")
        #expect(ChiefOfStaffNotificationRules.urgency(of: tomorrow, now: now) == .timeSensitive)
        let later = card("a", message: "The readout is in three weeks, no rush.")
        #expect(ChiefOfStaffNotificationRules.urgency(of: later, now: now) == .active)
    }

    @Test func threeAtOnceBecomeOneSummary() {
        let now = at(23, 10)
        let two = ChiefOfStaffNotificationRules.notices(for: [card("a"), card("b", project: "acme")], now: now, calendar: calendar)
        #expect(two.count == 2)
        let three = ChiefOfStaffNotificationRules.notices(
            for: [card("a"), card("b", project: "acme"), card("c", kind: "slack", project: "")],
            now: now,
            calendar: calendar
        )
        #expect(three == [.summary(count: 3, sources: ["globex", "acme"], urgency: .active)])
        let content = ChiefOfStaffNotificationContent(three[0])
        #expect(content.body == "3 new: globex, acme")
        #expect(content.category == ChiefOfStaffNotificationContent.summaryCategory)
        #expect(content.proposalID == nil)
    }

    @Test func aCardIsGroupedByProjectWithItsButtons() {
        let content = ChiefOfStaffNotificationContent(.card(card("a", due: "2026-09-24"), .timeSensitive))
        #expect(content.title == "Chief of Staff")
        #expect(content.subtitle == "globex")
        #expect(content.body == "A note.")
        #expect(content.threadIdentifier == "globex")
        #expect(content.category == ChiefOfStaffNotificationContent.cardCategory)
        #expect(content.interruptionLevel == .timeSensitive)
        #expect(content.proposalID == "a")
        let notice = ChiefOfStaffNotificationContent(.card(card("h", kind: "health", project: "", actions: []), .active))
        #expect(notice.category == ChiefOfStaffNotificationContent.noticeCategory)
        #expect(notice.threadIdentifier == "chief-of-staff")
        #expect(notice.interruptionLevel == .active)
    }

    @Test func responsesBecomeChoices() {
        typealias Content = ChiefOfStaffNotificationContent
        #expect(Content.choice(action: Content.doAction, proposalID: "a", text: nil) == .doIt(proposalID: "a"))
        #expect(Content.choice(action: Content.skipAction, proposalID: "a", text: nil) == .skip(proposalID: "a"))
        #expect(Content.choice(action: Content.openAction, proposalID: "a", text: nil) == .open(proposalID: "a"))
        #expect(Content.choice(action: UNNotificationDefaultActionIdentifier, proposalID: nil, text: nil) == .open(proposalID: nil))
        #expect(Content.choice(action: Content.replyAction, proposalID: "a", text: "do it but due Friday")
            == .reply(proposalID: "a", text: "do it but due Friday"))
        #expect(Content.choice(action: Content.replyAction, proposalID: "a", text: "  ") == nil)
        #expect(Content.choice(action: UNNotificationDismissActionIdentifier, proposalID: "a", text: nil) == nil)
    }
}

@Suite("Chief of Staff model", .serialized)
@MainActor
struct ChiefOfStaffModelTests {
    private func model(
        runner: RecordingCosRunner = RecordingCosRunner(),
        notifier: RecordingCosNotifier? = nil,
        now: Date = Date(timeIntervalSince1970: 1_790_000_000)
    ) throws -> ChiefOfStaffModel {
        ChiefOfStaffModel(
            paths: try CosFixture.home(),
            runner: runner,
            notifier: notifier,
            quietHours: QuietHours(startHour: 0, endHour: 0),
            clock: { now }
        )
    }

    @Test func readsTheThreadAndTheCLIStatus() async throws {
        let runner = RecordingCosRunner()
        let model = try model(runner: runner)
        await model.reload(force: true)
        #expect(model.waiting.map(\.id) == ["ee55ff66", "cc33dd44"])
        #expect(model.waitingCount == 2)
        #expect(model.summary == "2 waiting")
        #expect(model.status?.total == 6)
        #expect(await runner.commands == [.status])
        // Every waiting card has its state before a view reads it.
        #expect(model.cards.keys.sorted() == ["cc33dd44", "ee55ff66"])
    }

    @Test func focusWalksTheWaitingCardsAndLeavesPastTheLast() async throws {
        let model = try model()
        await model.reload(force: true)
        #expect(model.moveCardFocus(1))
        #expect(model.focusedCardID == "ee55ff66")
        model.moveCardFocus(1)
        #expect(model.focusedCardID == "cc33dd44")
        model.moveCardFocus(-1)
        #expect(model.focusedCardID == "ee55ff66")
        model.moveCardFocus(-1)
        #expect(model.focusedCardID == "ee55ff66")
        model.moveCardFocus(1)
        model.moveCardFocus(1)
        #expect(model.focusedCardID == nil)
    }

    @Test func cardKeysRunTheCLIOnTheFocusedCard() async throws {
        let runner = RecordingCosRunner()
        await runner.setStdout("OK   status_note: wrote\n")
        let model = try model(runner: runner)
        await model.reload(force: true)
        model.focusCard("cc33dd44")
        model.editFocused()
        #expect(model.isEditingFocusedCard)
        model.cards["cc33dd44"]?.drafts[0].text = "Edited note"
        await model.perform(.runEdit(id: "cc33dd44"))
        await model.perform(.skip(id: "ee55ff66"))
        await model.perform(.doIt(id: "cc33dd44"))
        let calls = await runner.commands.filter { $0 != .status }
        #expect(calls.count == 3)
        guard case .edit(let id, let actions) = calls[0] else {
            Issue.record("expected an edit, got \(calls[0])")
            return
        }
        #expect(id == "cc33dd44")
        #expect(actions[0].text == "Edited note")
        #expect(calls[1] == .skip(id: "ee55ff66", reason: nil))
        #expect(calls[2] == .doIt(id: "cc33dd44"))
        #expect(model.cards["cc33dd44"]?.outcome == [OutcomeLine(ok: true, text: "status_note: wrote")])
        #expect(model.cards["cc33dd44"]?.isEditing == false)
    }

    @Test func aHealthNoticeHasNoEdit() async throws {
        let model = try model()
        model.override(items: [.proposal(turnID: "t", Proposal(id: "h", eventKind: "health", message: "Green."))], status: nil)
        model.focusCard("h")
        model.editFocused()
        #expect(!model.isEditingFocusedCard)
    }

    @Test func newCardsAreAnnouncedAfterTheFirstRead() async throws {
        let notifier = RecordingCosNotifier()
        let model = try model(notifier: notifier)
        await model.reload(force: true)
        // The first read only seeds: those cards were announced before.
        #expect(notifier.posted.isEmpty)
        var items = try CosFixture.items()
        items.append(.proposal(turnID: "new", Proposal(id: "fresh", project: "globex", message: "New mail.")))
        model.override(items: items, status: nil)
        await model.announceNewCards()
        #expect(notifier.posted.count == 1)
        guard case .card(let proposal, _)? = notifier.posted.first else {
            Issue.record("expected one card notice")
            return
        }
        #expect(proposal.id == "fresh")
    }

    @Test func aNotificationReplyNamesItsCard() throws {
        let model = try model()
        var replies: [String] = []
        model.onReply = { replies.append($0) }
        model.override(items: try CosFixture.items(), status: nil)
        model.handle(.reply(proposalID: "cc33dd44", text: "do it but due Friday"))
        #expect(replies == ["About card cc33dd44 (Budget approved, quote due Tuesday): do it but due Friday"])
    }

    @Test func theSystemMessageCarriesWaitingAndRecentCards() async throws {
        let model = try model()
        await model.reload(force: true)
        let message = try #require(model.systemMessage(forChat: ChiefOfStaffModel.conversationID))
        #expect(message.contains("You cannot act from this chat"))
        #expect(message.contains("WAITING CARDS (newest first)\n[ee55ff66] Waiting"))
        #expect(message.contains("4. Close task: Budget sign-off received"))
        #expect(message.contains("RECENT CARDS (last 6, oldest first)"))
        #expect(!message.contains("—"))
        #expect(model.systemMessage(forChat: UUID()) == nil)
    }
}

@Suite("Chief of Staff pinned chat", .serialized)
@MainActor
struct ChiefOfStaffChatTests {
    struct Rig {
        let launcher: QuickViewModel
        let window: AIChatWindowModel
        let service: MockQuickService
        let runner: RecordingCosRunner
        let chiefOfStaff: ChiefOfStaffModel
    }

    private func makeRig() async throws -> Rig {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let service = MockQuickService()
        let launcher = QuickViewModel(settings: settings, service: service)
        launcher.overlayPresenter = RecordingPresenter()
        let chat = QuickViewModel(store: launcher.store, service: service)
        let suite = "ChiefOfStaffChatTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        window.window = FakeAIChatWindow()
        let runner = RecordingCosRunner()
        let chiefOfStaff = ChiefOfStaffModel(paths: try CosFixture.home(), runner: runner)
        await chiefOfStaff.reload(force: true)
        for vm in [launcher, chat] {
            vm.chiefOfStaff = chiefOfStaff
            vm.chiefOfStaffOpener = { window.openChiefOfStaff(proposalID: $0) }
        }
        return Rig(launcher: launcher, window: window, service: service, runner: runner, chiefOfStaff: chiefOfStaff)
    }

    @Test func theRailPinsTheChiefOfStaffFirstWithNoRowActions() async throws {
        let rig = try await makeRig()
        #expect(rig.window.railItems.first?.title == "Chief of Staff")
        #expect(rig.window.railDetail(for: rig.window.railItems[0]) == "2 waiting")
        rig.window.railIndex = 0
        #expect(rig.window.railActions.isEmpty)
        rig.window.railQuery = "cos"
        #expect(rig.window.railItems.first?.title == "Chief of Staff")
        rig.window.railQuery = "budget review"
        #expect(rig.window.railItems.first?.title != "Chief of Staff")
    }

    @Test func aQuestionRunsOnThePipelineWithTheSystemMessageAndIsRecorded() async throws {
        let rig = try await makeRig()
        rig.window.openChiefOfStaff()
        #expect(rig.window.isChiefOfStaffOpen)
        #expect(rig.window.chat.currentConversation?.enabledTools == ChiefOfStaffModel.tools)
        #expect(rig.window.chat.quickAITitle == "Chief of Staff")
        await rig.service.setResponses([StreamDelta(text: "Card cc33dd44 waits on you.", finishReason: "stop")])
        rig.window.chat.input = "What waits for me?"
        await rig.window.chat.submit()
        let sent = await rig.service.lastMessages
        #expect(sent.first?.role == .system)
        #expect(sent.first?.content.contains("[cc33dd44] Waiting") == true)
        #expect(sent.last?.content == "What waits for me?")
        await rig.chiefOfStaff.perform(.recordTurn(question: "What waits for me?", answer: "Card cc33dd44 waits on you.", attachmentNames: []))
        let appends = await rig.runner.commands.filter {
            if case .append = $0 { true } else { false }
        }
        #expect(appends == [
            .append(role: .user, text: "What waits for me?", meta: [:]),
            .append(role: .assistant, text: "Card cc33dd44 waits on you.", meta: [:]),
        ])
    }

    @Test func theBackingChatNeverShowsInAChatList() async throws {
        let rig = try await makeRig()
        rig.window.openChiefOfStaff()
        await rig.service.setResponses([StreamDelta(text: "Two.", finishReason: "stop")])
        rig.window.chat.input = "How many?"
        await rig.window.chat.submit()
        #expect(rig.window.chat.history.contains { $0.id == ChiefOfStaffModel.conversationID })
        let id = ChiefOfStaffModel.conversationID.uuidString
        #expect(!rig.launcher.chatItems(matching: "").contains { $0.itemID == id })
        #expect(rig.window.railItems.filter { $0.itemID == id }.count == 1)
    }

    @Test func aNewChatLeavesTheChiefOfStaff() async throws {
        let rig = try await makeRig()
        rig.window.openChiefOfStaff()
        rig.window.chat.startNewChatKeepingAnswer()
        #expect(!rig.window.isChiefOfStaffOpen)
        rig.window.openChat(itemID: ChiefOfStaffModel.conversationID.uuidString)
        #expect(rig.window.isChiefOfStaffOpen)
    }

    @Test func windowKeysMoveOverTheCardsAndBack() async throws {
        let rig = try await makeRig()
        rig.window.openChiefOfStaff()
        #expect(rig.window.focus == .composer)
        #expect(rig.window.handleChiefOfStaffKey(key: .upArrow, characters: nil, modifiers: []))
        #expect(rig.window.focus == .cards)
        #expect(rig.chiefOfStaff.focusedCardID == "ee55ff66")
        #expect(rig.window.handleChiefOfStaffKey(key: .downArrow, characters: nil, modifiers: []))
        #expect(rig.chiefOfStaff.focusedCardID == "cc33dd44")
        #expect(rig.window.handleChiefOfStaffKey(key: nil, characters: "e", modifiers: [.command]))
        #expect(rig.window.focus == .cardEdit)
        #expect(rig.window.handleEscape())
        #expect(rig.window.focus == .cards)
        #expect(rig.chiefOfStaff.isEditingFocusedCard == false)
        #expect(rig.window.handleEscape())
        #expect(rig.window.focus == .composer)
        #expect(rig.chiefOfStaff.focusedCardID == nil)
        // A notification's Open lands on its card.
        rig.window.openChiefOfStaff(proposalID: "cc33dd44")
        #expect(rig.window.focus == .cards)
        #expect(rig.chiefOfStaff.focusedCardID == "cc33dd44")
    }

    @Test func theLauncherFindsItByCos() async throws {
        let rig = try await makeRig()
        rig.launcher.input = "cos"
        #expect(rig.launcher.launcherMatches.first?.id == "command:\(QuickViewModel.chiefOfStaffCommandID)")
        let item = try #require(rig.launcher.catalogItem(kind: .command, itemID: QuickViewModel.chiefOfStaffCommandID))
        #expect(item.detail.hasPrefix("2 waiting"))
    }

    @Test func thePaletteOffersTheChiefOfStaffOutsideIt() async throws {
        let rig = try await makeRig()
        #expect(rig.window.windowSurfaceActions.first == .chiefOfStaff)
        rig.window.performWindowSurfaceAction(.chiefOfStaff)
        #expect(rig.window.isChiefOfStaffOpen)
        #expect(!rig.window.windowSurfaceActions.contains(.chiefOfStaff))
    }
}

/// The argument arrays against the installed `cos` itself, in a temporary
/// `COS_HOME` holding the fixture thread. Skipped on a Mac without `cos`.
@Suite("Chief of Staff real CLI", .serialized)
struct CosCLIIntegrationTests {
    static let installed = CosPaths.resolve(environment: [:]).executable

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: installed.path(percentEncoded: false))))
    func appendStatusAndSkipRunOnTheRealCLI() async throws {
        let home = try CosFixture.home()
        var environment = ProcessInfo.processInfo.environment
        environment["COS_HOME"] = home.data.path(percentEncoded: false)
        let cli = CosCLI(executable: Self.installed, environment: environment)

        let status = try await cli.run(.status)
        #expect(status.succeeded)
        #expect(try CosStatus.decode(status.stdout).pending == 2)

        let asked = try await cli.run(.append(role: .user, text: "Line one\nline \"two\"; three", meta: ["attachments": "a.pdf"]))
        #expect(asked.succeeded, "\(asked.stderr)")
        let answered = try await cli.run(.append(role: .assistant, text: "An answer.", meta: [:]))
        #expect(answered.succeeded, "\(answered.stderr)")

        let skipped = try await cli.run(.skip(id: "ee55ff66", reason: nil))
        #expect(skipped.succeeded, "\(skipped.stderr)")

        let record = try ChiefOfStaffThread.decode(Data(contentsOf: home.thread))
        let items = ChiefOfStaffThread.items(in: record)
        #expect(ChiefOfStaffThread.waiting(in: items).map(\.id) == ["cc33dd44"])
        let turns = items.suffix(3)
        guard case .chat(_, true, let question, _, let surface) = turns.dropLast().first else {
            Issue.record("expected the appended question, got \(Array(turns))")
            return
        }
        #expect(question == "Line one\nline \"two\"; three")
        #expect(surface == "quick-launch")
        #expect(record.turns.first { $0.text == question }?.appPayload?.values["attachments"]?.stringValue == "a.pdf")
    }
}
