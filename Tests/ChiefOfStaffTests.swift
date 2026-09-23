// ChiefOfStaffTests — the Chief of Staff's face in Quick Launch: the `cos`
// thread as read and sorted into tiers, the card keys, the `cos` argument
// arrays, the dates, the notification rules, the pinned chat on the ordinary
// chat pipeline, and the guardrail that Quick AI and every other AI Chat
// conversation are unchanged. The fixture was written by the real
// `cos/thread.py` and `cos append`, not typed from memory.

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
        switch command {
        case .status:
            return CosResult(exitCode: 0, stdout: #"{"paused": false, "total": 11, "pending": 7}"#, stderr: "")
        case .projects:
            return CosResult(exitCode: 0, stdout: Self.projectsJSON, stderr: "")
        case .tasks:
            return CosResult(exitCode: 0, stdout: #"[{"id": "t1", "lane": "requires_action", "title": "Send revised quote", "due": "2026-09-30"}]"#, stderr: "")
        default:
            return CosResult(exitCode: 0, stdout: stdout, stderr: "")
        }
    }

    /// The shape `cos projects --json` prints, extra keys and all.
    static let projectsJSON = """
    [{"slug": "sample-project", "name": "Sample Project", "phase": "fieldwork", "open_tasks": 5, "next_due": "2026-09-24",
      "overdue": 1, "waiting_cards": 2, "later_cards": 1, "waiting": 1, "source": "ledger", "risk": "red"},
     {"slug": "ops-desk", "name": "Ops Desk", "phase": null, "open_tasks": 2, "next_due": null,
      "overdue": 0, "waiting_cards": 0, "later_cards": 0, "waiting": 0, "source": "ledger", "risk": "ok"}]
    """

    /// Every call but the reads.
    var writes: [CosCommand] {
        commands.filter {
            switch $0 {
            case .status, .projects, .tasks: false
            default: true
            }
        }
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

/// 2026-09-23 12:00 UTC, the fixture's afternoon.
let cosNow = Date(timeIntervalSince1970: 1_790_164_800)

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()
}

@Suite("Chief of Staff thread")
struct ChiefOfStaffThreadTests {
    @Test func decodesEveryTurnKindAndTierTheCLIWrites() throws {
        let proposals = try CosFixture.items().compactMap(\.proposal)
        #expect(proposals.map(\.id) == [
            "aa11bb22", "cc33dd44", "dd00ee11", "ee55ff66", "ff77aa88", "99887766",
            "11aa22bb", "33cc44dd", "55ee66ff", "77aa88bb", "88bb99cc",
        ])
        #expect(proposals.map(\.status) == [
            .done, .pending, .dismissed, .pending, .later, .handled, .pending, .pending, .pending, .pending, .pending,
        ])
        #expect(proposals.map(\.tierKind) == [
            .today, .decide, .fyi, .today, .today, .system, .system, .waiting, .fyi, .today, .today,
        ])
        let budget = try #require(proposals.first { $0.id == "cc33dd44" })
        #expect(budget.headline == "Sam approved the budget; confirm the quote date")
        #expect(budget.why == "Sam waits on your reply before booking the room.")
        #expect(budget.due == "2026-09-24")
        #expect(budget.actions.map(\.kind) == [.statusNote, .taskAdd, .draftReply, .taskClose])
        let health = try #require(proposals.first { $0.id == "11aa22bb" })
        #expect(health.red == ["com.tristan.memory-health", "com.tristan.vault-heavy-backup"])
        let later = try #require(proposals.first { $0.id == "ff77aa88" })
        #expect(later.snoozedUntil == Date(timeIntervalSince1970: 1_790_211_600))
        #expect(later.canBringBack)
        #expect(proposals.first { $0.id == "88bb99cc" }?.isNotice == true)
        #expect(proposals.first?.decided != nil)
        // A null due is no due; an empty headline falls back to the message.
        #expect(proposals.first { $0.id == "ee55ff66" }?.actions.first?.due == nil)
        #expect(Proposal(id: "x", message: "First line.\nSecond.").headline == "First line.")
        // A card from before tiers is TODAY.
        #expect(Proposal(id: "x", message: "m").tierKind == .today)
    }

    @Test func historyLeavesOutPendingVerdictsAndOwnTurns() throws {
        let history = ChiefOfStaffThread.history(in: try CosFixture.items())
        #expect(history.compactMap(\.proposal).map(\.id) == ["aa11bb22", "dd00ee11", "99887766"])
        let chats = history.compactMap { item -> String? in
            if case .chat(_, _, let text, _, _) = item { return text }
            return nil
        }
        #expect(chats == ["What is still open on sample-project?", "One proposal waits: the budget approval."])
    }

    @Test func aTurnFromAnotherNamespaceIsLeftOut() throws {
        var record = try ChiefOfStaffThread.decode(CosFixture.data())
        record.turns.append(TurnRecord(
            id: "foreign",
            role: .assistant,
            text: "Another app's turn.",
            appPayload: AppPayload(namespace: "rti", values: ExtraFields())
        ))
        #expect(!ChiefOfStaffThread.items(in: record).contains { $0.id == "foreign" })
    }
}

@Suite("Chief of Staff cos calls")
struct CosCommandTests {
    @Test func verbsAreArgumentArrays() throws {
        #expect(try CosCommand.status.arguments() == ["status", "--json"])
        #expect(try CosCommand.doIt(id: "cc33dd44").arguments() == ["do", "cc33dd44"])
        #expect(try CosCommand.no(id: "a", reason: nil).arguments() == ["no", "a"])
        #expect(try CosCommand.no(id: "a", reason: "  not mine ").arguments() == ["no", "a", "--reason", "not mine"])
        #expect(try CosCommand.later(id: "a", until: "tomorrow").arguments() == ["later", "a", "--until", "tomorrow"])
        #expect(try CosCommand.reopen(id: "a").arguments() == ["reopen", "a"])
        #expect(try CosCommand.projects.arguments() == ["projects", "--json"])
        #expect(try CosCommand.tasks(project: "acme-amplify").arguments() == ["tasks", "--project", "acme-amplify"])
        #expect(try CosCommand.add(title: "Send the quote; today", project: "p", due: "2026-10-02").arguments()
            == ["add", "Send the quote; today", "--project", "p", "--due", "2026-10-02"])
        #expect(try CosCommand.add(title: "t", project: "p", due: nil).arguments() == ["add", "t", "--project", "p"])
    }

    @Test func editKeepsFieldsItDoesNotEditAndDropsEmptyOnes() throws {
        let budget = try #require(try CosFixture.items().compactMap(\.proposal).first { $0.id == "cc33dd44" })
        var drafts = ActionDraft.drafts(for: budget)
        drafts[1].text = "Send the revised quote; today"
        drafts[1].due = ""
        drafts[3].text = "Sign-off in the 20:16 mail"
        let arguments = try CosCommand.edit(id: budget.id, actions: drafts.map(\.action)).arguments()
        #expect(Array(arguments.prefix(3)) == ["edit", "cc33dd44", "--actions-json"])
        let decoded = try JSONDecoder().decode([[String: String]].self, from: Data(try #require(arguments.last).utf8))
        #expect(decoded[1] == ["type": "task_add", "title": "Send the revised quote; today"])
        #expect(decoded[3] == ["type": "task_close", "task_id": "T-42", "what": "Sign-off in the 20:16 mail"])
    }

    @Test func appendSendsTheTextOnStdinAndTheSurface() throws {
        let command = CosCommand.append(role: .user, text: "a \"quoted\"; line", meta: ["attachments": "brief.pdf"])
        #expect(try command.arguments() == [
            "append", "--role", "user", "--surface", "quick-launch", "--meta", #"{"attachments":"brief.pdf"}"#, "-",
        ])
        #expect(command.stdin == Data("a \"quoted\"; line".utf8))
        #expect(CosCommand.doIt(id: "a").stdin == nil)
    }

    @Test func projectsAndTasksDecodeTheCLIOutput() throws {
        let projects = try CosProject.decodeList(RecordingCosRunner.projectsJSON)
        #expect(projects.map(\.slug) == ["sample-project", "ops-desk"])
        #expect(projects[0].openTasks == 5 && projects[0].overdue == 1 && projects[0].waitingCards == 2 && projects[0].risk == "red")
        #expect(projects[1].phase == nil && projects[1].nextDue == nil)
        let tasks = try CosTask.decodeList(#"[{"id": "a", "lane": "captured", "title": "T", "due": null}]"#)
        #expect(tasks == [CosTask(id: "a", lane: "captured", title: "T", due: nil)])
    }

    @Test func outcomeLinesReadTheCLIOutput() {
        let result = CosResult(exitCode: 1, stdout: "OK   status_note: wrote\nFAIL task_add: no project\n", stderr: "")
        #expect(OutcomeLine.lines(from: result) == [
            OutcomeLine(ok: true, text: "status_note: wrote"),
            OutcomeLine(ok: false, text: "task_add: no project"),
        ])
    }
}

@Suite("Chief of Staff dates")
struct ChiefOfStaffDateTests {
    let calendar = Calendar.utc

    @Test func dueDaysReadAsPhrases() {
        #expect(ChiefOfStaffDates.relativeDue("2026-09-23", now: cosNow, calendar: calendar) == "by today")
        #expect(ChiefOfStaffDates.relativeDue("2026-09-24", now: cosNow, calendar: calendar) == "by tomorrow")
        #expect(ChiefOfStaffDates.relativeDue("2026-09-25", now: cosNow, calendar: calendar) == "by Friday")
        #expect(ChiefOfStaffDates.relativeDue("2026-10-09", now: cosNow, calendar: calendar) == "by 9 Oct")
        #expect(ChiefOfStaffDates.relativeDue("2026-09-22", now: cosNow, calendar: calendar) == "1 day late")
        #expect(ChiefOfStaffDates.relativeDue("2026-09-20", now: cosNow, calendar: calendar) == "3 days late")
        #expect(ChiefOfStaffDates.relativeDue("soon", now: cosNow, calendar: calendar) == nil)
    }

    @Test func typedDaysBecomeISODays() {
        func parse(_ text: String) -> String? { ChiefOfStaffDates.parseDay(text, now: cosNow, calendar: calendar) }
        #expect(parse("today") == "2026-09-23")
        #expect(parse("tomorrow") == "2026-09-24")
        #expect(parse("tmr") == "2026-09-24")
        // Wednesday the 23rd: "fri" is this Friday, "wed" next week's.
        #expect(parse("fri") == "2026-09-25")
        #expect(parse("Friday") == "2026-09-25")
        #expect(parse("wed") == "2026-09-30")
        #expect(parse("next week") == "2026-09-28")
        #expect(parse("+3") == "2026-09-26")
        #expect(parse("3d") == "2026-09-26")
        #expect(parse("2026-10-02") == "2026-10-02")
        #expect(parse("10/2") == "2026-10-02")
        #expect(parse("2 oct") == "2026-10-02")
        #expect(parse("Oct 2") == "2026-10-02")
        // A day already past this year is next year's.
        #expect(parse("1/5") == "2027-01-05")
        #expect(parse("someday") == nil)
        #expect(parse("") == nil)
    }

    @Test func laterSaysWhenItComesBack() {
        let tonight = cosNow.addingTimeInterval(8 * 3600)
        #expect(ChiefOfStaffDates.returnPhrase(tonight, now: cosNow, calendar: calendar) == "back tonight at 20:00")
        let tomorrow = cosNow.addingTimeInterval(21 * 3600)
        #expect(ChiefOfStaffDates.returnPhrase(tomorrow, now: cosNow, calendar: calendar) == "back tomorrow at 09:00")
        #expect(LaterChoice.allCases.map { $0.until(picked: "2026-10-02") } == ["tonight", "tomorrow", "nextweek", "2026-10-02"])
        #expect(LaterChoice.pickDate.until(picked: nil) == nil)
    }
}

@Suite("Chief of Staff keys")
struct ChiefOfStaffKeyTests {
    private func route(
        _ key: VirtualKey?,
        _ characters: String? = nil,
        _ modifiers: NSEvent.ModifierFlags = [],
        _ place: ChiefOfStaffKeys.Place,
        cards: Bool = true
    ) -> ChiefOfStaffKeys.Action? {
        ChiefOfStaffKeys.route(key: key, characters: characters, modifiers: modifiers, place: place, hasCards: cards)
    }

    @Test func theComposerReachesTheCardsWithoutTakingTheDraftsKeys() {
        #expect(route(.upArrow, nil, [], .composer(draftIsEmpty: true)) == .focusCards)
        #expect(route(.upArrow, nil, [.option], .composer(draftIsEmpty: false)) == .focusCards)
        #expect(route(.upArrow, nil, [], .composer(draftIsEmpty: false)) == nil)
        #expect(route(.upArrow, nil, [], .composer(draftIsEmpty: true), cards: false) == nil)
        #expect(route(.downArrow, nil, [], .composer(draftIsEmpty: true)) == nil)
        // ⌘↩ and ⌘L stay the composer's (send, read aloud).
        #expect(route(.return, nil, [.command], .composer(draftIsEmpty: false)) == nil)
        #expect(route(nil, "l", [.command], .composer(draftIsEmpty: false)) == nil)
        #expect(route(nil, "r", [.command], .composer(draftIsEmpty: false)) == nil)
    }

    @Test func aFocusedCardTakesItsActionKeys() {
        #expect(route(.downArrow, nil, [], .card(board: false)) == .move(1))
        #expect(route(.upArrow, nil, [.option], .card(board: false)) == .move(-1))
        #expect(route(.return, nil, [.command], .card(board: false)) == .doIt)
        #expect(route(nil, "e", [.command], .card(board: false)) == .edit)
        #expect(route(nil, "l", [.command], .card(board: false)) == .later)
        #expect(route(.delete, nil, [.command], .card(board: false)) == .no)
        #expect(route(nil, "r", [.command], .card(board: false)) == .bringBack)
        #expect(route(.escape, nil, [], .card(board: false)) == .toComposer)
        #expect(route(.return, nil, [], .card(board: false)) == nil)
        #expect(route(.delete, nil, [], .card(board: false)) == nil)
        #expect(route(.rightArrow, nil, [], .card(board: false)) == nil)
        #expect(route(.rightArrow, nil, [], .card(board: true)) == .moveColumn(1))
        #expect(route(.leftArrow, nil, [], .card(board: true)) == .moveColumn(-1))
        #expect(route(.return, nil, [.command, .capsLock], .card(board: true)) == .doIt)
    }

    @Test func theConversationsOwnKeysWorkFromTheComposerAndACard() {
        for place in [ChiefOfStaffKeys.Place.composer(draftIsEmpty: false), .card(board: false)] {
            #expect(route(nil, "1", [.command, .option], place) == .showList)
            #expect(route(nil, "2", [.command, .option], place) == .showBoard)
            // ⌘1 to ⌘9 stay the rail's, here as in every chat.
            #expect(route(nil, "1", [.command], place) == nil)
            #expect(route(nil, "2", [.command], place) == nil)
            #expect(route(nil, "n", [.command], place) == .newTask)
            #expect(route(nil, "i", [.command], place) == .toggleHealth)
            #expect(route(nil, "p", [.command, .shift], place) == .pickProject)
            #expect(route(nil, "t", [.command, .shift], place) == .toggleTasks)
            #expect(route(.return, nil, [.command, .shift], place) == .doAllToday)
        }
    }

    @Test func theLaterMenuAndEditOwnTheirKeys() {
        #expect(route(.downArrow, nil, [], .laterMenu) == .menuMove(1))
        #expect(route(.return, nil, [], .laterMenu) == .menuPick(nil))
        #expect(route(nil, "2", [], .laterMenu) == .menuPick(.tomorrow))
        #expect(route(.escape, nil, [], .laterMenu) == .menuClose)
        #expect(route(nil, "1", [.command, .option], .laterMenu) == nil)
        // Typing a day types; Return picks it.
        #expect(route(nil, "2", [], .laterPicking) == nil)
        #expect(route(.return, nil, [], .laterPicking) == .menuPick(.pickDate))
        #expect(route(.escape, nil, [], .laterPicking) == .menuClose)
        #expect(route(.return, nil, [.command], .editing) == .runEdit)
        #expect(route(.escape, nil, [], .editing) == .cancelEdit)
        #expect(route(.return, nil, [], .editing) == nil)
        #expect(route(nil, "n", [.command], .editing) == nil)
    }
}

@Suite("Chief of Staff notifications")
struct ChiefOfStaffNotificationTests {
    let calendar = Calendar.utc

    private func card(_ id: String, tier: String, project: String = "globex", actions: [ProposalAction] = [
        ProposalAction(type: "status_note", fields: ["note": "x"]),
    ]) -> Proposal {
        Proposal(id: id, project: project, eventKind: "email", message: "A note.", tier: tier, actions: actions)
    }

    @Test func quietHoursRunFromElevenToSeven() {
        let quiet = QuietHours.standard
        func at(_ hour: Int) -> Date { calendar.date(bySettingHour: hour, minute: 0, second: 0, of: cosNow)! }
        #expect(quiet.contains(at(23), calendar: calendar))
        #expect(quiet.contains(at(0), calendar: calendar))
        #expect(quiet.contains(at(6), calendar: calendar))
        #expect(!quiet.contains(at(7), calendar: calendar))
        #expect(!quiet.contains(at(22), calendar: calendar))
        #expect(ChiefOfStaffNotificationRules.notices(for: [card("a", tier: "decide")], now: at(23), calendar: calendar).isEmpty)
    }

    @Test func decideInterruptsTodayAndFYIArePassiveWaitingIsSilent() {
        let notices = ChiefOfStaffNotificationRules.notices(
            for: [card("d", tier: "decide"), card("t", tier: "today"), card("f", tier: "fyi"), card("w", tier: "waiting")],
            now: cosNow,
            calendar: calendar
        )
        #expect(notices == [
            .card(card("d", tier: "decide"), .timeSensitive),
            .card(card("t", tier: "today"), .passive),
            .card(card("f", tier: "fyi"), .passive),
        ])
        #expect(ChiefOfStaffNotificationContent(notices[0]).interruptionLevel == .timeSensitive)
        #expect(ChiefOfStaffNotificationContent(notices[1]).interruptionLevel == .passive)
    }

    @Test func threeQuietCardsBecomeOnePassiveSummary() {
        let notices = ChiefOfStaffNotificationRules.notices(
            for: [card("a", tier: "today"), card("b", tier: "today", project: "acme"), card("c", tier: "fyi", project: ""),
                  card("d", tier: "decide")],
            now: cosNow,
            calendar: calendar
        )
        #expect(notices == [
            .card(card("d", tier: "decide"), .timeSensitive),
            .summary(count: 3, sources: ["globex", "acme"], urgency: .passive),
        ])
        #expect(ChiefOfStaffNotificationContent(notices[1]).body == "3 new: globex, acme")
    }

    @Test func healthNotifiesOnlyForNewlyRedJobs() {
        let quiet = ChiefOfStaffNotificationRules.notices(for: [], now: cosNow, calendar: calendar)
        #expect(quiet.isEmpty)
        let red = ChiefOfStaffNotificationRules.notices(
            for: [], newlyRed: ["com.tristan.memory-health"], healthHeadline: "1 job is failing.", now: cosNow, calendar: calendar
        )
        #expect(red == [.health(newlyRed: ["com.tristan.memory-health"], headline: "1 job is failing.")])
        let content = ChiefOfStaffNotificationContent(red[0])
        #expect(content.subtitle == "A job turned red")
        #expect(content.threadIdentifier == "chief-of-staff.health")
        #expect(content.interruptionLevel == .active)
    }

    @Test func aCardIsGroupedByProjectWithItsButtons() {
        let content = ChiefOfStaffNotificationContent(.card(card("a", tier: "decide"), .timeSensitive))
        #expect(content.title == "Chief of Staff")
        #expect(content.subtitle == "globex")
        #expect(content.threadIdentifier == "globex")
        #expect(content.category == ChiefOfStaffNotificationContent.cardCategory)
        #expect(content.proposalID == "a")
        let notice = ChiefOfStaffNotificationContent(.card(card("n", tier: "today", project: "", actions: []), .passive))
        #expect(notice.category == ChiefOfStaffNotificationContent.noticeCategory)
        #expect(notice.threadIdentifier == "chief-of-staff")
    }

    @Test func responsesBecomeChoices() {
        typealias Content = ChiefOfStaffNotificationContent
        #expect(Content.choice(action: Content.doAction, proposalID: "a", text: nil) == .doIt(proposalID: "a"))
        #expect(Content.choice(action: Content.noAction, proposalID: "a", text: nil) == .no(proposalID: "a"))
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
        notifier: RecordingCosNotifier? = nil
    ) async throws -> ChiefOfStaffModel {
        let model = ChiefOfStaffModel(
            paths: try CosFixture.home(),
            runner: runner,
            notifier: notifier,
            quietHours: QuietHours(startHour: 0, endHour: 0),
            clock: { cosNow }
        )
        await model.reload(force: true)
        return model
    }

    @Test func cardsSortIntoTiersAndHealthIsNotACard() async throws {
        let model = try await model()
        #expect(model.decide.map(\.id) == ["cc33dd44"])
        #expect(model.today.map(\.id) == ["88bb99cc", "77aa88bb", "ee55ff66"])
        #expect(model.waitingOnOthers.map(\.id) == ["33cc44dd"])
        #expect(model.fyi.map(\.id) == ["55ee66ff"])
        #expect(model.later.map(\.id) == ["ff77aa88"])
        #expect(model.doneThisWeek.map(\.id) == ["aa11bb22"])
        #expect(model.health?.id == "11aa22bb")
        #expect(model.healthLine == "2 background jobs are failing.")
        #expect(model.waitingCount == 4)
        #expect(model.summary == "4 waiting")
        #expect(model.projects.map(\.slug) == ["sample-project", "ops-desk"])
        #expect(!model.focusOrder.contains("11aa22bb"))
    }

    @Test func aProjectFilterNarrowsEveryTierAndTheHistory() async throws {
        let model = try await model()
        model.setProjectFilter("ops-desk")
        #expect(model.decide.isEmpty)
        #expect(model.today.map(\.id) == ["ee55ff66"])
        #expect(model.later.isEmpty)
        #expect(model.filteredHistory.isEmpty)
        #expect(model.filteredProject?.name == "Ops Desk")
        // Health is the whole Mac's, whatever the filter.
        #expect(model.health != nil)
        model.setProjectFilter(nil)
        #expect(model.today.count == 3)
    }

    @Test func decideShowsThreeUntilShowAll() async throws {
        let model = try await model()
        let many = (0..<5).map { index in
            ChiefOfStaffThreadItem.proposal(turnID: "t\(index)", Proposal(id: "d\(index)", message: "m", tier: "decide"))
        }
        model.override(items: many, status: nil)
        #expect(model.visibleDecide.count == 3)
        model.toggleSection(.decide)
        #expect(model.visibleDecide.count == 5)
    }

    @Test func listFocusWalksDecideTodayAndOpenSections() async throws {
        let model = try await model()
        #expect(model.focusOrder == ["cc33dd44", "88bb99cc", "77aa88bb", "ee55ff66"])
        model.moveCardFocus(1)
        #expect(model.focusedCardID == "cc33dd44")
        model.moveCardFocus(-1)
        #expect(model.focusedCardID == "cc33dd44")
        for _ in 0..<3 { model.moveCardFocus(1) }
        #expect(model.focusedCardID == "ee55ff66")
        model.moveCardFocus(1)
        #expect(model.focusedCardID == nil)
        // Focusing a card behind a collapsed section opens it.
        model.focusCard("ff77aa88")
        #expect(model.expanded.contains(.later))
        #expect(model.focusedCardID == "ff77aa88")
    }

    @Test func theBoardMovesAcrossColumns() async throws {
        let model = try await model()
        model.viewMode = .board
        #expect(model.column(.done).map(\.id) == ["aa11bb22"])
        model.focusCard("cc33dd44")
        model.moveColumnFocus(1)
        #expect(model.focusedCardID == "88bb99cc")
        model.moveCardFocus(1)
        #expect(model.focusedCardID == "77aa88bb")
        model.moveColumnFocus(1)
        #expect(model.focusedCardID == "33cc44dd")
        model.moveColumnFocus(1)
        #expect(model.focusedCardID == "ff77aa88")
        model.moveColumnFocus(1)
        #expect(model.focusedCardID == "aa11bb22")
        model.moveColumnFocus(1)
        #expect(model.focusedCardID == "aa11bb22")
    }

    @Test func cardKeysCallTheirVerbs() async throws {
        let runner = RecordingCosRunner()
        await runner.setStdout("OK   status_note: wrote\n")
        let model = try await model(runner: runner)
        model.focusCard("cc33dd44")
        model.editFocused()
        #expect(model.isEditingFocusedCard)
        model.cards["cc33dd44"]?.drafts[0].text = "Edited note"
        await model.perform(.runEdit(id: "cc33dd44"))
        await model.perform(.no(id: "ee55ff66"))
        await model.perform(.doIt(id: "88bb99cc"))
        await model.perform(.reopen(id: "ff77aa88"))
        let writes = await runner.writes
        guard case .edit(let id, let actions) = writes.first else {
            Issue.record("expected an edit first, got \(writes)")
            return
        }
        #expect(id == "cc33dd44")
        #expect(actions[0].text == "Edited note")
        #expect(Array(writes.dropFirst()) == [.no(id: "ee55ff66", reason: nil), .doIt(id: "88bb99cc"), .reopen(id: "ff77aa88")])
        #expect(model.cards["cc33dd44"]?.isEditing == false)
    }

    @Test func laterAsksWhenThenCallsLater() async throws {
        let model = try await model()
        model.focusCard("ee55ff66")
        model.openLaterMenu()
        #expect(model.laterMenu?.proposalID == "ee55ff66")
        model.moveLaterMenu(1)
        #expect(model.laterMenu?.index == LaterChoice.tomorrow.rawValue)
        model.chooseLater()
        #expect(model.laterMenu == nil)
        model.openLaterMenu()
        model.chooseLater(.pickDate)
        #expect(model.laterMenu?.isPicking == true)
        model.setLaterPickText("someday")
        model.chooseLater(.pickDate)
        #expect(model.laterMenu != nil)
        model.setLaterPickText("2026-10-02")
        model.chooseLater(.pickDate)
        #expect(model.laterMenu == nil)
        // Later is not for a card that is not waiting.
        model.focusCard("ff77aa88")
        model.openLaterMenu()
        #expect(model.laterMenu == nil)
    }

    @Test func laterSendsTheCLIsWords() async throws {
        let runner = RecordingCosRunner()
        let model = try await model(runner: runner)
        await model.perform(.later(id: "ee55ff66", until: "tomorrow"))
        #expect(await runner.writes == [.later(id: "ee55ff66", until: "tomorrow")])
    }

    @Test func doAllTodayAsksOnceThenRunsEveryVisibleRow() async throws {
        let model = try await model()
        model.doAllToday()
        #expect(model.bulkArmed == ["88bb99cc", "77aa88bb", "ee55ff66"])
        model.moveCardFocus(1)
        #expect(model.bulkArmed == nil)
        model.doAllToday()
        model.doAllToday()
        #expect(model.bulkArmed == nil)
    }

    @Test func newTaskChecksItsFieldsThenAdds() async throws {
        let runner = RecordingCosRunner()
        let model = try await model(runner: runner)
        model.openNewTask()
        model.submitNewTask()
        #expect(model.newTask?.problem == "Type the task.")
        model.newTask?.title = "Book the room"
        model.newTask?.projectQuery = "zzz"
        model.submitNewTask()
        #expect(model.newTask?.problem == "Pick a project.")
        model.newTask?.projectQuery = "ops"
        model.newTask?.due = "whenever"
        model.submitNewTask()
        #expect(model.newTask?.problem == "Due: tomorrow, fri, or 2026-10-02.")
        model.newTask?.due = "fri"
        model.submitNewTask()
        #expect(model.newTask == nil)
        await model.perform(.addTask(title: "Book the room", project: "ops-desk", due: "2026-09-25"))
        #expect(await runner.writes == [.add(title: "Book the room", project: "ops-desk", due: "2026-09-25")])
        #expect(model.notice == "Task added to Ops Desk.")
        // On a filtered project the sheet starts on it.
        model.setProjectFilter("sample-project")
        model.openNewTask()
        #expect(model.newTask?.projectSlug == "sample-project")
    }

    @Test func aReplyStartingWithTaskAddsATaskOnTheCardsProject() async throws {
        let model = try await model()
        var replies: [String] = []
        model.onReply = { replies.append($0) }
        #expect(ChiefOfStaffModel.taskTitle(in: "task: Book the room") == "Book the room")
        #expect(ChiefOfStaffModel.taskTitle(in: "Task:") == nil)
        #expect(ChiefOfStaffModel.taskTitle(in: "do it") == nil)
        model.handle(.reply(proposalID: "cc33dd44", text: "do it but due Friday"))
        #expect(replies == ["About card cc33dd44 (Sam approved the budget; confirm the quote date): do it but due Friday"])
    }

    @Test func tasksLoadForTheFilteredProject() async throws {
        let model = try await model()
        model.setProjectFilter("sample-project")
        await model.perform(.loadTasks(project: "sample-project"))
        #expect(model.tasks.map(\.title) == ["Send revised quote"])
    }

    @Test func newCardsAndNewlyRedJobsAreAnnouncedAfterTheFirstRead() async throws {
        let notifier = RecordingCosNotifier()
        let model = try await model(notifier: notifier)
        #expect(notifier.posted.isEmpty)
        var items = try CosFixture.items()
        items.append(.proposal(turnID: "new", Proposal(id: "fresh", project: "globex", message: "New mail.", tier: "decide")))
        items.append(.proposal(turnID: "w", Proposal(id: "owed", message: "They owe.", tier: "waiting")))
        model.override(items: items, status: nil)
        await model.announceNewCards()
        #expect(notifier.posted.count == 1)
        guard case .card(let proposal, .timeSensitive)? = notifier.posted.first else {
            Issue.record("expected one time-sensitive card, got \(notifier.posted)")
            return
        }
        #expect(proposal.id == "fresh")
        // The health card gains a red job.
        let redder = items.map { item -> ChiefOfStaffThreadItem in
            guard case .proposal(let turn, var card) = item, card.id == "11aa22bb" else { return item }
            card.red.append("com.tristan.workspace-intake")
            return .proposal(turnID: turn, card)
        }
        model.override(items: redder, status: nil)
        await model.announceNewCards()
        #expect(notifier.posted.last == .health(newlyRed: ["com.tristan.workspace-intake"], headline: "2 background jobs are failing."))
    }

    @Test func theSystemMessageCarriesCardsButNotHealth() async throws {
        let model = try await model()
        let message = try #require(model.systemMessage(forChat: ChiefOfStaffModel.conversationID))
        #expect(message.contains("You cannot act from this chat"))
        #expect(message.contains("[cc33dd44] Waiting · sample-project · decide · due 2026-09-24"))
        #expect(message.contains("4. Close task: Budget sign-off received"))
        #expect(!message.contains("WAITING CARDS (newest first)\n[11aa22bb]"))
        #expect(!message.contains("—"))
        #expect(model.systemMessage(forChat: UUID()) == nil)
    }
}

@Suite("Chief of Staff pinned chat and guardrail", .serialized)
@MainActor
struct ChiefOfStaffChatTests {
    struct Rig {
        let launcher: QuickViewModel
        let window: AIChatWindowModel
        let service: MockQuickService
        let runner: RecordingCosRunner
        let chiefOfStaff: ChiefOfStaffModel?
    }

    private func makeRig(withChiefOfStaff: Bool = true, history: [QuickConversation] = []) async throws -> Rig {
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
        launcher.aiChatOpener = { window.open(handoff: $0) }
        if !history.isEmpty { chat.history = history }
        let runner = RecordingCosRunner()
        var chiefOfStaff: ChiefOfStaffModel?
        if withChiefOfStaff {
            let model = ChiefOfStaffModel(paths: try CosFixture.home(), runner: runner, clock: { cosNow })
            await model.reload(force: true)
            for vm in [launcher, chat] {
                vm.chiefOfStaff = model
                vm.chiefOfStaffOpener = { window.openChiefOfStaff(proposalID: $0) }
            }
            chiefOfStaff = model
        }
        return Rig(launcher: launcher, window: window, service: service, runner: runner, chiefOfStaff: chiefOfStaff)
    }

    private func conversation(_ title: String, minutes: Double) -> QuickConversation {
        var conversation = QuickConversation(
            providerID: QuickSettings().providers[0].id,
            model: "model",
            messages: [QuickMessage(role: .user, content: title), QuickMessage(role: .assistant, content: "Answer.")]
        )
        conversation.updatedAt = Date(timeIntervalSinceNow: -minutes * 60)
        return conversation
    }

    @Test func theRailPinsTheChiefOfStaffFirstWithNoNumberAndNoRowActions() async throws {
        let rig = try await makeRig(history: [conversation("Budget review", minutes: 5), conversation("Kyoto trip", minutes: 50)])
        let items = rig.window.railItems
        #expect(items.first?.title == "Chief of Staff")
        #expect(rig.window.railDetail(for: items[0]) == "4 waiting")
        #expect(rig.window.railNumber(at: 0) == nil)
        #expect(rig.window.railNumber(at: 1) == 1)
        rig.window.railIndex = 0
        #expect(rig.window.railActions.isEmpty)
        rig.window.railQuery = "cos"
        #expect(rig.window.railItems.first?.title == "Chief of Staff")
        rig.window.railQuery = "kyoto"
        #expect(rig.window.railItems.first?.title != "Chief of Staff")
        withExtendedLifetime(rig.chiefOfStaff) {}
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
        await rig.chiefOfStaff?.perform(.recordTurn(question: "What waits for me?", answer: "Card cc33dd44 waits on you.", attachmentNames: []))
        #expect(await rig.runner.writes == [
            .append(role: .user, text: "What waits for me?", meta: [:]),
            .append(role: .assistant, text: "Card cc33dd44 waits on you.", meta: [:]),
        ])
        #expect(rig.window.chat.history.contains { $0.id == ChiefOfStaffModel.conversationID })
        #expect(!rig.launcher.chatItems(matching: "").contains { $0.itemID == ChiefOfStaffModel.conversationID.uuidString })
    }

    @Test func windowKeysMoveOverTheCardsAndBack() async throws {
        let rig = try await makeRig()
        let cos = try #require(rig.chiefOfStaff)
        rig.window.openChiefOfStaff()
        #expect(rig.window.handleChiefOfStaffKey(key: .upArrow, characters: nil, modifiers: []))
        #expect(rig.window.focus == .cards)
        #expect(cos.focusedCardID == "cc33dd44")
        #expect(rig.window.handleChiefOfStaffKey(key: .downArrow, characters: nil, modifiers: []))
        #expect(cos.focusedCardID == "88bb99cc")
        #expect(rig.window.handleChiefOfStaffKey(key: nil, characters: "l", modifiers: [.command]))
        #expect(cos.laterMenu?.proposalID == "88bb99cc")
        #expect(rig.window.handleChiefOfStaffKey(key: .escape, characters: nil, modifiers: []))
        #expect(cos.laterMenu == nil)
        #expect(rig.window.handleChiefOfStaffKey(key: .upArrow, characters: nil, modifiers: []))
        #expect(rig.window.handleChiefOfStaffKey(key: nil, characters: "e", modifiers: [.command]))
        #expect(rig.window.focus == .cardEdit)
        #expect(rig.window.handleEscape())
        #expect(rig.window.focus == .cards)
        #expect(rig.window.handleEscape())
        #expect(rig.window.focus == .composer)
        #expect(cos.focusedCardID == nil)
        #expect(!rig.window.handleChiefOfStaffKey(key: nil, characters: "2", modifiers: [.command]))
        #expect(rig.window.handleChiefOfStaffKey(key: nil, characters: "2", modifiers: [.command, .option]))
        #expect(cos.viewMode == .board)
        #expect(rig.window.handleChiefOfStaffKey(key: nil, characters: "n", modifiers: [.command]))
        #expect(rig.window.focus == .cosForm)
        #expect(cos.newTask != nil)
        #expect(rig.window.handleEscape())
        #expect(cos.newTask == nil)
        rig.window.openChiefOfStaff(proposalID: "ff77aa88")
        #expect(rig.window.focus == .cards)
        #expect(cos.focusedCardID == "ff77aa88")
    }

    @Test func theLauncherFindsItByCos() async throws {
        let rig = try await makeRig()
        rig.launcher.input = "cos"
        #expect(rig.launcher.launcherMatches.first?.id == "command:\(QuickViewModel.chiefOfStaffCommandID)")
        let item = try #require(rig.launcher.catalogItem(kind: .command, itemID: QuickViewModel.chiefOfStaffCommandID))
        #expect(item.detail.hasPrefix("4 waiting"))
    }

    // MARK: Guardrail: Quick AI and every other AI Chat conversation are unchanged

    /// An ordinary AI Chat question sends exactly what it sends with no
    /// Chief of Staff in the app: the same messages (no system message
    /// added), the same provider and model, and the same tools.
    @Test func anOrdinaryChatRequestIsIdenticalWithOrWithoutTheChiefOfStaff() async throws {
        var sent: [[QuickMessage]] = []
        var routes: [String] = []
        var tools: [Set<ChatToolKind>?] = []
        for attached in [false, true] {
            let rig = try await makeRig(withChiefOfStaff: attached)
            rig.window.open(handoff: nil)
            #expect(!rig.window.isChiefOfStaffOpen)
            await rig.service.setResponses([StreamDelta(text: "Ship Friday.", finishReason: "stop")])
            rig.window.chat.input = "When do we ship?"
            await rig.window.chat.submit()
            sent.append(await rig.service.lastMessages.map { QuickMessage(role: $0.role, content: $0.content) })
            let conversation = try #require(rig.window.chat.currentConversation)
            routes.append("\(conversation.providerID) \(conversation.model)")
            tools.append(conversation.enabledTools)
            #expect(rig.window.chat.quickAITitle != "Chief of Staff")
            #expect(await rig.runner.writes.isEmpty)
            withExtendedLifetime(rig.chiefOfStaff) {}
        }
        #expect(sent[0].map(\.content) == sent[1].map(\.content))
        #expect(sent[0].map(\.role) == sent[1].map(\.role))
        #expect(!sent[1].contains { $0.content.contains("chief of staff") })
        #expect(routes[0] == routes[1])
        #expect(tools[0] == tools[1])
    }

    @Test func quickAIInTheLauncherIsUntouched() async throws {
        var sent: [[String]] = []
        for attached in [false, true] {
            let rig = try await makeRig(withChiefOfStaff: attached)
            rig.launcher.openQuickAI()
            await rig.service.setResponses([StreamDelta(text: "Four.", finishReason: "stop")])
            rig.launcher.input = "two plus two in words"
            await rig.launcher.submit()
            sent.append(await rig.service.lastMessages.map(\.content))
            #expect(rig.launcher.currentConversation?.id != ChiefOfStaffModel.conversationID)
            #expect(await rig.runner.writes.isEmpty)
            withExtendedLifetime(rig.chiefOfStaff) {}
        }
        #expect(sent[0] == sent[1])
    }

    /// Outside the pinned conversation none of its keys act: ⌘1 still jumps
    /// to the first chat, ⌘N is still New Chat, ↑ is the composer's.
    @Test func theChiefOfStaffKeysDoNothingInAnOrdinaryChat() async throws {
        let rig = try await makeRig(history: [conversation("Budget review", minutes: 5), conversation("Kyoto trip", minutes: 50)])
        rig.window.open(handoff: nil)
        for (key, characters, modifiers) in [
            (nil, "1", NSEvent.ModifierFlags([.command, .option])), (nil, "2", [.command, .option]), (nil, "n", [.command]),
            (nil, "i", [.command]), (nil, "p", [.command, .shift]), (VirtualKey.upArrow, nil, []),
            (.upArrow, nil, [.option]), (.return, nil, [.command, .shift]),
        ] as [(VirtualKey?, String?, NSEvent.ModifierFlags)] {
            #expect(!rig.window.handleChiefOfStaffKey(key: key, characters: characters, modifiers: modifiers))
        }
        #expect(rig.window.handleKeyEquivalent(characters: "1", keyCode: 18, modifiers: [.command]))
        #expect(rig.window.chat.currentConversation.map { rig.window.chat.title(of: $0) } == "Budget review")
        withExtendedLifetime(rig.chiefOfStaff) {}
    }

    /// In the pinned conversation too, ⌘1 opens the rail's first chat.
    @Test func railJumpsKeepTheirMeaningInsideThePinnedConversation() async throws {
        let rig = try await makeRig(history: [conversation("Budget review", minutes: 5), conversation("Kyoto trip", minutes: 50)])
        rig.window.openChiefOfStaff()
        #expect(!rig.window.handleChiefOfStaffKey(key: nil, characters: "1", modifiers: [.command]))
        #expect(rig.window.handleKeyEquivalent(characters: "1", keyCode: 18, modifiers: [.command]))
        #expect(!rig.window.isChiefOfStaffOpen)
        #expect(rig.window.chat.currentConversation.map { rig.window.chat.title(of: $0) } == "Budget review")
        withExtendedLifetime(rig.chiefOfStaff) {}
    }

    @Test func thePalettesRowsKeepTheirOrderAndGainOneAtTheEnd() async throws {
        let plain = try await makeRig(withChiefOfStaff: false)
        let with = try await makeRig()
        #expect(Array(with.window.windowSurfaceActions.dropLast()) == plain.window.windowSurfaceActions)
        #expect(with.window.windowSurfaceActions.last == .chiefOfStaff)
        with.window.performWindowSurfaceAction(.chiefOfStaff)
        #expect(with.window.isChiefOfStaffOpen)
        #expect(with.window.windowSurfaceActions.last == .newTask)
    }
}

/// The argument arrays against the installed `cos` itself, in a temporary
/// `COS_HOME` holding the fixture thread. Skipped on a Mac without `cos`.
@Suite("Chief of Staff real CLI", .serialized)
struct CosCLIIntegrationTests {
    static let installed = CosPaths.resolve(environment: [:]).executable

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: installed.path(percentEncoded: false))))
    func verbsRunOnTheRealCLI() async throws {
        let home = try CosFixture.home()
        var environment = ProcessInfo.processInfo.environment
        environment["COS_HOME"] = home.data.path(percentEncoded: false)
        let cli = CosCLI(executable: Self.installed, environment: environment)

        let status = try await cli.run(.status)
        #expect(status.succeeded)
        #expect(try CosStatus.decode(status.stdout).pending == 7)

        let asked = try await cli.run(.append(role: .user, text: "Line one\nline \"two\"; three", meta: ["attachments": "a.pdf"]))
        #expect(asked.succeeded, "\(asked.stderr)")
        #expect(try await cli.run(.append(role: .assistant, text: "An answer.", meta: [:])).succeeded)
        let no = try await cli.run(.no(id: "ee55ff66", reason: nil))
        #expect(no.succeeded, "\(no.stderr)")
        let later = try await cli.run(.later(id: "88bb99cc", until: "tomorrow"))
        #expect(later.succeeded, "\(later.stderr)")
        let reopen = try await cli.run(.reopen(id: "ff77aa88"))
        #expect(reopen.succeeded, "\(reopen.stderr)")

        let record = try ChiefOfStaffThread.decode(Data(contentsOf: home.thread))
        let proposals = ChiefOfStaffThread.items(in: record).compactMap(\.proposal)
        #expect(proposals.first { $0.id == "ee55ff66" }?.status == .dismissed)
        #expect(proposals.first { $0.id == "88bb99cc" }?.status == .later)
        #expect(proposals.first { $0.id == "88bb99cc" }?.snoozedUntil != nil)
        #expect(proposals.first { $0.id == "ff77aa88" }?.status == .pending)
        let question = record.turns.first { $0.text == "Line one\nline \"two\"; three" }
        #expect(question?.appPayload?.values["surface"]?.stringValue == "quick-launch")
        #expect(question?.appPayload?.values["attachments"]?.stringValue == "a.pdf")
    }
}
