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
            return CosResult(exitCode: 0, stdout: Self.statusJSON, stderr: "")
        case .projects:
            return CosResult(exitCode: 0, stdout: Self.projectsJSON, stderr: "")
        case .tasks:
            return CosResult(exitCode: 0, stdout: #"[{"id": "t1", "lane": "requires_action", "title": "Send revised quote", "due": "2026-09-30"}]"#, stderr: "")
        case .activity:
            return CosResult(exitCode: 0, stdout: Self.activityJSON, stderr: "")
        case .artifacts:
            return CosResult(exitCode: 0, stdout: #"[{"card": "cc33dd44", "path": "/tmp/cos-artifacts/cc33dd44/quote-note.md", "rel": "artifacts/cc33dd44/quote-note.md", "name": "Quote note draft", "headline": "Sam approved the budget; confirm the quote date", "project": "sample-project", "bytes": 812, "modified": "2026-09-23T11:30:00+00:00"}]"#, stderr: "")
        case .charter:
            return CosResult(exitCode: 0, stdout: Self.charterJSON, stderr: "")
        case .learnings:
            return CosResult(exitCode: 0, stdout: Self.learningsJSON, stderr: "")
        case .rungs:
            return CosResult(exitCode: 0, stdout: #"[{"id": "status_note@sample-project", "type": "status_note", "project": "sample-project", "note": ""}, {"id": "task_close@*", "type": "task_close", "project": null, "note": ""}]"#, stderr: "")
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

    /// `cos status --json` with the call budget (contract §11).
    static let statusJSON = """
    {"paused": false, "total": 11, "pending": 7, "decided": 4, "accepted": 4, "auto_closed": 7, "auto_ran": 1,
     "rungs": 2, "learnings": 2, "today": 2, "cap": 8,
     "model_calls": {"maker": 12, "reviewer": 3, "cap": {"maker": 40, "reviewer": 10}, "failures_in_row": 0, "paused_until": null}}
    """

    /// `cos learnings --json`, newest first.
    static let learningsJSON = """
    [{"key": "k-newsletters", "text": "Less like this: newsletter digests", "scope": "all", "source": "user",
      "confidence": 1.0, "created": "2026-09-23T10:00:00Z", "weight": 1.0},
     {"key": "k-charlie", "text": "Charlie's date changes are always DECIDE", "scope": "project:sample-project",
      "source": "inferred", "confidence": 0.6, "created": "2026-09-20T09:00:00Z", "card": "aa11bb22", "weight": 0.55}]
    """

    /// `cos activity --json` as contract v1 prints it.
    static let activityJSON = """
    {"day": "2026-09-23", "runs": 38,
     "read": {"count": 1, "items": [{"ts": "2026-09-23T08:00:00+00:00", "time": "16:00", "text": "4 mails and 2 Slack threads"}]},
     "proposed": {"count": 1, "items": [{"ts": "2026-09-23T08:01:00+00:00", "time": "16:01", "text": "Budget approved: log it, add a task, draft a reply", "card": "cc33dd44"}]},
     "reviewed": {"count": 1, "items": [{"ts": 1790150460, "time": "16:01", "text": "Escalated: the reply promises a date the task tree does not show", "card": "cc33dd44"}]},
     "ran": {"count": 1, "items": [{"ts": "2026-09-23T11:00:05.000Z", "time": "19:00", "text": "Logged the budget approval (rung: status notes on Sample Project)", "card": "au777777"}]},
     "closed_on_their_own": {"count": 1, "items": [{"time": "19:20", "text": "Merged 7 cards into one digest"}]},
     "failed": {"count": 1, "items": [{"time": "19:40", "text": "Brain call timed out after 240 s"}]},
     "answered": {"count": 1, "items": [{"time": "19:45", "text": "Do it: Alex asks who owns the ops rota", "card": "ee55ff66"}]}
    }
    """

    /// `cos charter --json` as contract v1 prints it, rungs included.
    static let charterJSON = """
    {"path": "/tmp/chief-of-staff-charter.md", "sections": [
     {"key": "voice", "title": "Voice", "text": "I am Tristan's chief of staff: calm, direct,\\non his side.\\n\\nNo flattery, no filler.\\n\\n- \\"Charlie approved. / Next: log it.\\"", "items": ["\\"Charlie approved. / Next: log it.\\""]},
     {"key": "watch", "title": "Watch", "text": "- Client mail on live projects\\n- Slack mentions in #ops", "items": ["Client mail on live projects", "Slack mentions in #ops"]},
     {"key": "people", "title": "People", "text": "", "items": ["Charlie: Globex client lead"]},
     {"key": "ignore", "title": "Ignore", "text": "", "items": ["Newsletters"]},
     {"key": "style", "title": "Style", "text": "", "items": ["Plain short sentences"]},
     {"key": "learned", "title": "Learned", "text": "", "items": ["Less like this: newsletter digests (2026-09-23)"]}
    ], "rungs": [
     {"id": "status_note@sample-project", "type": "status_note", "project": "sample-project", "note": "2026-09-23"},
     {"id": "task_close@*", "type": "task_close", "project": null, "note": ""}
    ]}
    """

    /// Every call but the reads.
    var writes: [CosCommand] {
        commands.filter {
            switch $0 {
            case .status, .projects, .tasks, .charter, .rungs, .learnings, .activity, .artifacts: false
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
            "11aa22bb", "33cc44dd", "55ee66ff", "77aa88bb", "88bb99cc", "mo123456", "me654321", "au777777", "rv000001",
        ])
        #expect(proposals.map(\.status) == [
            .done, .pending, .dismissed, .pending, .later, .handled, .pending, .pending, .pending, .pending, .pending,
            .pending, .pending, .done, .pending,
        ])
        #expect(proposals.map(\.tierKind) == [
            .today, .decide, .fyi, .today, .today, .system, .system, .waiting, .fyi, .today, .today, .today, .decide, .fyi, .today,
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

@Suite("Chief of Staff reading")
struct ChiefOfStaffReadingTests {
    @Test func headlinesFallBackToTheFirstSentenceCutAtASemicolon() {
        #expect(Proposal.firstSentence(of: "Charlie approved the mini group; Dana started.\nMore.") == "Charlie approved the mini group")
        #expect(Proposal.firstSentence(of: "The readout moved. Log it.") == "The readout moved.")
        #expect(Proposal.firstSentence(of: "One line") == "One line")
        #expect(Proposal.firstSentence(of: "\n\n") == nil)
        #expect(Proposal(id: "x", message: "A; b").headline == "A")
        #expect(Proposal(id: "x", message: "m", headline: "Given").headline == "Given")
        let long = "Charlie approved the mini group with 5 IC recruits on 2026-09-23; Dana started the same day"
        #expect(Proposal(id: "x", message: "m", headline: long).headline == "Charlie approved the mini group with 5 IC recruits on 2026-09-23")
        #expect(Proposal(id: "x", message: "m", headline: "Short; fine").headline == "Short; fine")
    }

    @Test func rowsSayTheFirstActionNotItsType() {
        let close = { (what: String) in ProposalAction(type: "task_close", fields: ["task_id": "t", "what": what]) }
        let three = Proposal(id: "x", message: "m", actions: [close("Finalise stimulus photos."), close("b"), close("c")])
        #expect(three.actionSummary == "Finalise stimulus photos, +2 more")
        #expect(Proposal(id: "x", message: "m", actions: [close("Sent the transcript")]).actionSummary == "Sent the transcript")
        #expect(Proposal(id: "x", message: "m").actionSummary == nil)
    }

    @Test func projectsShowTheirShortName() throws {
        let long = CosProject(slug: "globex-northwind", name: "Northwind & Contoso Consumer Immersion — Globex Corporation")
        #expect(long.shortName == "Northwind & Contoso Consumer Immersion")
        #expect(CosProject(slug: "s", name: "Plain").shortName == "Plain")
        #expect(CosProject(slug: "s", name: " — x").shortName == "s")
        var named = Proposal(id: "x", project: "globex-northwind", sender: "Charlie", message: "m")
        #expect(named.source == "globex-northwind")
        named.projectName = long.shortName
        #expect(named.source == "Northwind & Contoso Consumer Immersion")
    }

    @Test func earlierDropsDigestBookkeepingAndFoldsAutoClosedCards() {
        func card(_ id: String, _ verdict: String?) -> ChiefOfStaffThreadItem {
            .proposal(turnID: id, Proposal(id: id, status: verdict == "auto" ? .handled : .done, message: id, verdict: verdict))
        }
        func note(_ id: String, _ text: String) -> ChiefOfStaffThreadItem {
            .verdict(turnID: "v-\(id)-\(text.count)", proposalID: id, verdict: "auto", text: text, date: nil)
        }
        let items: [ChiefOfStaffThreadItem] = [
            card("merged", "auto"), note("merged", "Merged into one digest"),
            card("closed", "auto"), note("closed", "Closed on its own: the proof arrived"),
            card("done", "do"),
            card("health", "auto"),
        ]
        let entries = ChiefOfStaffThread.earlier(ChiefOfStaffThread.history(in: items), in: items)
        #expect(entries.count == 2)
        guard case .closedOnTheirOwn(let folded) = entries.first else {
            Issue.record("expected the folded line first, got \(entries)")
            return
        }
        #expect(folded.map(\.id) == ["closed", "health"])
        #expect(entries.last?.id == "done")
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
        let decoded = try JSONDecoder().decode([[String: JSONValue]].self, from: Data(try #require(arguments.last).utf8))
        #expect(decoded[1] == ["type": .string("task_add"), "title": .string("Send the revised quote; today")])
        // Fields Edit does not model come back as they were, a null included.
        #expect(decoded[3] == [
            "type": .string("task_close"), "task_id": .string("T-42"),
            "what": .string("Sign-off in the 20:16 mail"), "evidence": .null,
        ])
    }

    /// Edit never drops a field it does not model: lists, objects, numbers,
    /// booleans and empty strings go back to `cos edit` unchanged.
    @Test func editKeepsNestedAndListFields() throws {
        let wire = #"""
        {"type": "charter_compact", "note": "Merge these", "rules": ["[all] Skip newsletters", "[project:globex] Less like this"],
         "scope": {"project": "globex", "since": 3, "strict": true}, "weight": 2.5, "empty": "", "none": null}
        """#
        let action = try #require(ProposalAction(json: JSONDecoder().decode(JSONValue.self, from: Data(wire.utf8))))
        let edited = action.editing(text: "  Merge these three  ", due: "")
        let json = try ProposalAction.actionsJSON([edited])
        let sent = try JSONDecoder().decode([[String: JSONValue]].self, from: Data(json.utf8))
        #expect(sent == [[
            "type": .string("charter_compact"),
            "note": .string("Merge these three"),
            "rules": .array([.string("[all] Skip newsletters"), .string("[project:globex] Less like this")]),
            "scope": .object(["project": .string("globex"), "since": .number(3), "strict": .bool(true)]),
            "weight": .number(2.5),
            "empty": .string(""),
            "none": .null,
        ]])
        // Unedited, the action goes back exactly as it came.
        let untouched = try JSONDecoder().decode([[String: JSONValue]].self, from: Data(try ProposalAction.actionsJSON([action]).utf8))
        var original = try JSONDecoder().decode([String: JSONValue].self, from: Data(wire.utf8))
        original["note"] = .string("Merge these")
        #expect(untouched == [original])
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
            #expect(route(nil, "1", [.command, .option], place) == .showView(.list))
            #expect(route(nil, "2", [.command, .option], place) == .showView(.board))
            #expect(route(nil, "3", [.command, .option], place) == .showView(.activity))
            #expect(route(nil, "4", [.command, .option], place) == .showView(.artifacts))
            #expect(route(nil, "5", [.command, .option], place) == .showView(.charter))
            #expect(route(nil, "6", [.command, .option], place) == nil)
            #expect(route(nil, "[", [.command, .option], place) == .activityDay(-1))
            #expect(route(nil, "]", [.command, .option], place) == .activityDay(1))
            // ⌘Y only while "Always do this?" is offered.
            #expect(route(nil, "y", [.command], place) == nil)
            #expect(ChiefOfStaffKeys.route(key: nil, characters: "y", modifiers: [.command], place: place, hasCards: true, hasRungOffer: true) == .acceptRung)
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
        #expect(model.decide.map(\.id) == ["me654321", "cc33dd44"])
        // The morning brief is pinned first in TODAY.
        #expect(model.today.map(\.id) == ["mo123456", "88bb99cc", "77aa88bb", "ee55ff66"])
        #expect(model.waitingOnOthers.map(\.id) == ["33cc44dd"])
        // FYI: the waiting FYI card, then what a rung ran ("I did this").
        #expect(model.fyi.map(\.id) == ["55ee66ff", "au777777"])
        #expect(model.later.map(\.id) == ["ff77aa88"])
        #expect(model.doneThisWeek.map(\.id) == ["au777777", "aa11bb22"])
        #expect(model.health?.id == "11aa22bb")
        #expect(model.healthLine == "2 background jobs are failing.")
        #expect(model.waitingCount == 6)
        #expect(model.summary == "6 waiting")
        #expect(model.projects.map(\.slug) == ["sample-project", "ops-desk"])
        // Cards carry their project's name from the strip, not the slug.
        #expect(model.today.map(\.source) == ["", "Sample Project", "Sample Project", "Ops Desk"])
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
        #expect(model.today.count == 4)
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
        #expect(model.focusOrder == ["me654321", "cc33dd44", "mo123456", "88bb99cc", "77aa88bb", "ee55ff66"])
        model.moveCardFocus(1)
        #expect(model.focusedCardID == "me654321")
        model.moveCardFocus(-1)
        #expect(model.focusedCardID == "me654321")
        for _ in 0..<5 { model.moveCardFocus(1) }
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
        #expect(model.column(.done).map(\.id) == ["au777777", "aa11bb22"])
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
        #expect(model.focusedCardID == "au777777")
        model.moveColumnFocus(1)
        #expect(model.focusedCardID == "au777777")
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
        // The morning brief is not run by Do all.
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
        #expect(message.contains("[cc33dd44] Waiting · Sample Project (sample-project) · decide · due 2026-09-24"))
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
        #expect(rig.window.railDetail(for: items[0]) == "6 waiting")
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
        #expect(cos.focusedCardID == "me654321")
        #expect(rig.window.handleChiefOfStaffKey(key: .downArrow, characters: nil, modifiers: []))
        #expect(cos.focusedCardID == "cc33dd44")
        #expect(rig.window.handleChiefOfStaffKey(key: nil, characters: "l", modifiers: [.command]))
        #expect(cos.laterMenu?.proposalID == "cc33dd44")
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
        #expect(item.detail.hasPrefix("6 waiting"))
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
        #expect(try CosStatus.decode(status.stdout).pending == 10)

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
        // The v1 reads decode as the real CLI prints them. (Writes such as
        // more, less, rule, always and undo touch the real charter or the
        // vault, so they are never run from a test.)
        let activity = try await cli.run(.activity(day: nil))
        #expect(activity.succeeded, "\(activity.stderr)")
        _ = try CosActivity.decode(activity.stdout)
        let artifacts = try await cli.run(.artifacts)
        #expect(artifacts.succeeded)
        _ = try CosArtifact.decodeList(artifacts.stdout)
        let charter = try await cli.run(.charter)
        #expect(charter.succeeded)
        #expect(try CosCharter.decode(charter.stdout).sections.isEmpty == false)
        let rungs = try await cli.run(.rungs)
        #expect(rungs.succeeded)
        _ = try CosRung.decodeList(rungs.stdout)
        let learnings = try await cli.run(.learnings)
        #expect(learnings.succeeded)
        _ = try CosLearning.decodeList(learnings.stdout)
        #expect(try CosStatus.decode(status.stdout).modelCalls != nil)

        let question = record.turns.first { $0.text == "Line one\nline \"two\"; three" }
        #expect(question?.appPayload?.values["surface"]?.stringValue == "quick-launch")
        #expect(question?.appPayload?.values["attachments"]?.stringValue == "a.pdf")
    }
}

// MARK: - Contract v1

/// Keeps the files it was asked to open.
actor RecordingFileOpener: LocalFileOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) async throws { opened.append(url) }
}

@Suite("Chief of Staff contract v1 data")
struct ChiefOfStaffV1DataTests {
    @Test func newVerbsAreArgumentArrays() throws {
        #expect(try CosCommand.more(id: "a").arguments() == ["more", "a"])
        #expect(try CosCommand.less(id: "a", why: nil).arguments() == ["less", "a"])
        #expect(try CosCommand.less(id: "a", why: " newsletters again ").arguments() == ["less", "a", "--why", "newsletters again"])
        #expect(try CosCommand.always(id: "a").arguments() == ["always", "a"])
        #expect(try CosCommand.never(rung: "status_note@p").arguments() == ["never", "status_note@p"])
        #expect(try CosCommand.rungs.arguments() == ["rungs", "--json"])
        #expect(try CosCommand.undo(id: "a").arguments() == ["undo", "a"])
        #expect(try CosCommand.activity(day: nil).arguments() == ["activity", "--json"])
        #expect(try CosCommand.activity(day: "2026-09-22").arguments() == ["activity", "--day", "2026-09-22", "--json"])
        #expect(try CosCommand.artifacts.arguments() == ["artifacts", "--json"])
        #expect(try CosCommand.charter.arguments() == ["charter", "--json"])
        #expect(try CosCommand.rule(text: "Ignore newsletters", scope: "all").arguments()
            == ["rule", "Ignore newsletters", "--scope", "all"])
        #expect(try CosCommand.rule(text: "Dates matter", scope: "project:globex").arguments()
            == ["rule", "Dates matter", "--scope", "project:globex"])
        #expect(try CosCommand.learnings.arguments() == ["learnings", "--json"])
        #expect(try CosCommand.charterLine(text: "Warmer with clients", section: "voice").arguments()
            == ["rule", "Warmer with clients", "--section", "voice"])
        #expect(try CosCommand.forget(key: "k-1").arguments() == ["forget", "k-1"])
    }

    @Test func v1CardFieldsDecode() throws {
        let proposals = try CosFixture.items().compactMap(\.proposal)
        let budget = try #require(proposals.first { $0.id == "cc33dd44" })
        #expect(budget.review == Proposal.Review(
            verdict: "escalate", reason: "The reply promises a date the task tree does not show.", model: "deepseek-v4-pro"
        ))
        #expect(budget.review?.isEscalation == true)
        #expect(budget.artifacts == ["artifacts/cc33dd44/quote-note.md"])
        let auto = try #require(proposals.first { $0.id == "au777777" })
        #expect(auto.auto && auto.hasUndo && auto.canUndo)
        #expect(auto.statusWord == "I did this")
        let done = try #require(proposals.first { $0.id == "aa11bb22" })
        #expect(done.canUndo && done.feedback == "more")
        let meeting = try #require(proposals.first { $0.id == "me654321" })
        #expect(meeting.isMeeting && meeting.location == "Zoom" && meeting.source == "sample-project")
        #expect(meeting.starts == Date(timeIntervalSince1970: 1_790_165_700))
        // Undo shows while a step is not undone yet.
        func undoable(_ steps: String) throws -> Bool {
            let json = #"{"kind": "proposal", "id": "u", "status": "done", "message": "m", "undo": \#(steps)}"#
            let values = try JSONDecoder().decode(ExtraFields.self, from: Data(json.utf8))
            return try #require(Proposal(values: values, fallbackText: "", fallbackDate: nil)).canUndo
        }
        #expect(try undoable(#"[{"type": "status_note", "done": false}]"#))
        #expect(try undoable(#"[{"type": "status_note", "done": true}, {"type": "task_add", "done": false}]"#))
        #expect(try !undoable(#"[{"type": "status_note", "done": true}]"#))
        #expect(try !undoable("[]"))
        #expect(ProposalAction(type: "prepare", fields: ["brief": "A one-page note", "format": "md"]).typeLabel == "Prepare")
        #expect(ProposalAction(type: "prepare", fields: ["brief": "A one-page note"]).text == "A one-page note")
        // A card still waiting on the reviewer is hidden.
        let held = try #require(proposals.first { $0.id == "rv000001" })
        #expect(held.awaitsReview)
        #expect(!ChiefOfStaffThread.waiting(in: try CosFixture.items()).contains { $0.id == "rv000001" })
        #expect(Proposal(id: "x", status: .dismissed, message: "m", verdict: "undone").statusWord == "Undone")
        #expect(proposals.first { $0.id == "mo123456" }?.isMorning == true)
        // Pending cards cannot be undone.
        #expect(!budget.canUndo)
    }

    @Test func alwaysIsOfferedOnlyForAutoEligibleCardsOutsideDecide() {
        func card(_ types: [String], tier: String = "today", auto: Bool = false, kind: String = "email") -> Proposal {
            Proposal(id: "x", eventKind: kind, message: "m", tier: tier, actions: types.map { ProposalAction(type: $0) }, auto: auto)
        }
        #expect(card(["status_note"]).offersRung)
        #expect(card(["task_add", "task_close"]).offersRung)
        #expect(!card(["status_note", "draft_reply"]).offersRung)
        #expect(!card(["prepare"]).offersRung)
        #expect(!card([]).offersRung)
        #expect(!card(["status_note"], tier: "decide").offersRung)
        #expect(!card(["status_note"], auto: true).offersRung)
        #expect(!card(["task_add"], kind: "meeting").offersRung)
    }

    @Test func activityDecodesEitherShapeAndGroups() throws {
        let activity = try CosActivity.decode(RecordingCosRunner.activityJSON)
        #expect(activity.day == "2026-09-23" && activity.runs == 38)
        #expect(activity.events.count == 7)
        #expect(activity.events("reviewed").first?.ts == Date(timeIntervalSince1970: 1_790_150_460))
        #expect(activity.events("read").first?.ts == Date(timeIntervalSince1970: 1_790_150_400))
        #expect(activity.events("read").first?.clock == "16:00")
        #expect(activity.events("ran").first?.card == "au777777")
        #expect(activity.events("answered").first?.text == "Do it: Alex asks who owns the ops rota")
        #expect(CosActivity.groups.map(\.kind) == ["read", "proposed", "reviewed", "ran", "closed_on_their_own", "failed", "answered"])
        let bare = try CosActivity.decode(#"[{"kind": "failed", "text": "x"}]"#)
        #expect(bare.day == nil && bare.events.map(\.kind) == ["failed"])
        #expect(Set(activity.events.map(\.id)).count == 7)
        // The empty day the real CLI prints.
        let empty = try CosActivity.decode(#"{"day": "2026-09-23", "read": {"count": 0, "items": []}, "runs": 38}"#)
        #expect(empty.events.isEmpty && empty.runs == 38)
    }

    /// A meeting's start and an artifact's time are local, with no zone.
    @Test func localTimesWithNoZoneParse() throws {
        let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
        #expect(CosDate.parse("2026-09-23T20:15", timeZone: shanghai) == Date(timeIntervalSince1970: 1_790_165_700))
        #expect(CosDate.parse("2026-09-23T20:15:00", timeZone: shanghai) == Date(timeIntervalSince1970: 1_790_165_700))
        #expect(CosDate.parse("2026-09-23T12:15:00+00:00") == Date(timeIntervalSince1970: 1_790_165_700))
        #expect(CosDate.parse("soon") == nil)
    }

    @Test func artifactsCharterAndRungsDecode() throws {
        let artifacts = try CosArtifact.decodeList(#"""
        [{"card": "c1", "path": "/d/artifacts/c1/draft.md", "rel": "artifacts/c1/draft.md", "name": "draft.md",
          "headline": "H", "project": "p", "bytes": 10, "modified": "2026-09-23T11:30:00+00:00"},
         {"card": "c2", "path": "artifacts/c2/x.md"}, {"card": "c3", "path": "y.md"}]
        """#)
        // A row names a draft by its card's headline, else its file.
        #expect(artifacts.map(\.name) == ["H", "x.md", "y.md"])
        #expect(artifacts[0].created == Date(timeIntervalSince1970: 1_790_163_000))
        #expect(artifacts[0].headline == "H")
        let paths = CosPaths(data: URL(fileURLWithPath: "/data"), executable: URL(fileURLWithPath: "/bin/cos"))
        #expect(artifacts[0].url(in: paths).path == "/d/artifacts/c1/draft.md")
        #expect(artifacts[1].url(in: paths).path == "/data/artifacts/c2/x.md")
        #expect(artifacts[2].url(in: paths).path == "/data/artifacts/c3/y.md")
        let charter = try CosCharter.decode(RecordingCosRunner.charterJSON)
        #expect(charter.path == "/tmp/chief-of-staff-charter.md")
        #expect(charter.sections.map(\.key) == ["voice", "watch", "people", "ignore", "style", "learned"])
        #expect(charter.sections.map(\.name) == ["Voice", "Watch", "People", "Ignore", "Style", "Learned"])
        // Voice is prose first (each paragraph on one line), then its examples.
        #expect(charter.sections[0].prose == ["I am Tristan's chief of staff: calm, direct, on his side.", "No flattery, no filler."])
        #expect(charter.sections[0].lines == ["\"Charlie approved. / Next: log it.\""])
        // A section that is only "- " lines has no prose to repeat.
        #expect(charter.sections[1].prose.isEmpty)
        #expect(charter.sections[1].lines == ["Client mail on live projects", "Slack mentions in #ops"])
        #expect(charter.rungs.map(\.rung) == ["status_note@sample-project", "task_close@*"])
        #expect(charter.rungs[1].project == "*")
        let keyed = try CosCharter.decode(#"{"Watch": ["a"], "Ignore": ["b", "c"]}"#)
        #expect(keyed.sections.map(\.key) == ["ignore", "watch"])
        let rungs = try CosRung.decodeList(#"[{"id": "status_note@p", "type": "status_note", "project": "p", "note": ""}]"#)
        #expect(rungs.first?.rung == "status_note@p")
    }

    @Test func discussAttachesTheCardAndOnlyItsFilesInsideTheVault() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cos-discuss-\(UUID().uuidString)")
        let vault = root.appending(path: "vault")
        let data = root.appending(path: "data")
        try FileManager.default.createDirectory(at: vault.appending(path: "kb/emails"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data.appending(path: "artifacts/c1"), withIntermediateDirectories: true)
        try Data("mail".utf8).write(to: vault.appending(path: "kb/emails/a.md"))
        try Data("draft".utf8).write(to: data.appending(path: "artifacts/c1/note.md"))
        try Data("secret".utf8).write(to: root.appending(path: "outside.md"))
        let card = Proposal(
            id: "c1", project: "p", message: "The readout moved.", headline: "Readout moved", why: "Sam asked.",
            actions: [ProposalAction(type: "status_note", fields: ["note": "Log it"])],
            artifacts: ["artifacts/c1/note.md", "missing.md"]
        )
        var withPaths = card
        withPaths.paths = ["kb/emails/a.md", "kb/emails/missing.md", "../outside.md", root.appending(path: "outside.md").path]
        let discussion = ChiefOfStaffModel.discussion(for: withPaths, vault: vault, data: data)
        #expect(discussion.title == "Readout moved")
        #expect(discussion.files.map(\.lastPathComponent) == ["a.md", "note.md"])
        #expect(discussion.cardText.hasPrefix("Readout moved\nFrom: p\nWhy: Sam asked.\n\nThe readout moved."))
        #expect(discussion.cardText.contains("1. Status note: Log it"))
    }
}

@Suite("Chief of Staff contract v1 model", .serialized)
@MainActor
struct ChiefOfStaffV1ModelTests {
    private func model(runner: RecordingCosRunner = RecordingCosRunner()) async throws -> ChiefOfStaffModel {
        let model = ChiefOfStaffModel(paths: try CosFixture.home(), runner: runner, clock: { cosNow })
        await model.reload(force: true)
        return model
    }

    @Test func moreAndLessWithAnOptionalWhy() async throws {
        let runner = RecordingCosRunner()
        let model = try await model(runner: runner)
        model.focusCard("ee55ff66")
        model.moreFocused()
        model.lessFocused()
        #expect(model.lessPrompt?.proposalID == "ee55ff66")
        model.lessPrompt?.why = "  "
        model.submitLess()
        #expect(model.lessPrompt == nil)
        model.lessFocused()
        model.lessPrompt?.why = "Slack rota questions are Alex's"
        model.submitLess()
        await model.perform(.more(id: "ee55ff66"))
        await model.perform(.less(id: "ee55ff66", why: nil))
        await model.perform(.less(id: "ee55ff66", why: "Slack rota questions are Alex's"))
        #expect(await runner.writes == [
            .more(id: "ee55ff66"), .less(id: "ee55ff66", why: nil), .less(id: "ee55ff66", why: "Slack rota questions are Alex's"),
        ])
        #expect(model.notice == "Less like this: noted.")
    }

    @Test func aDoItOnAnEligibleCardOffersAlways() async throws {
        let runner = RecordingCosRunner()
        await runner.setStdout("OK   task_add: added\n")
        let model = try await model(runner: runner)
        await model.perform(.doIt(id: "ee55ff66"))
        #expect(model.rungOffer == ChiefOfStaffModel.RungOffer(proposalID: "ee55ff66", project: "Ops Desk", types: ["Task"]))
        model.acceptRungOffer()
        #expect(model.rungOffer == nil)
        await model.perform(.always(id: "ee55ff66"))
        #expect(await runner.writes.last == .always(id: "ee55ff66"))
        // Not after a DECIDE card, nor after a failed run.
        await model.perform(.doIt(id: "cc33dd44"))
        #expect(model.rungOffer == nil)
        await runner.setStdout("FAIL task_close: no such task\n")
        await model.perform(.doIt(id: "77aa88bb"))
        #expect(model.rungOffer == nil)
    }

    @Test func doAllTodayNeverOffersAlways() async throws {
        let runner = RecordingCosRunner()
        await runner.setStdout("OK   task_add: added\n")
        let model = try await model(runner: runner)
        model.doAllToday()
        model.doAllToday()
        await model.perform(.doIt(id: "ee55ff66"))
        #expect(model.rungOffer == nil)
    }

    @Test func undoIsOnlyForDoneCardsWithSteps() async throws {
        let runner = RecordingCosRunner()
        let model = try await model(runner: runner)
        model.focusCard("ee55ff66")
        model.undoFocused()
        model.viewMode = .board
        model.focusCard("aa11bb22")
        model.undoFocused()
        model.focusCard("au777777")
        model.undoFocused()
        await model.perform(.undo(id: "au777777"))
        #expect(await runner.writes.contains(.undo(id: "au777777")))
        #expect(!(await runner.writes.contains(.undo(id: "ee55ff66"))))
    }

    @Test func pagesLoadWhenShownAndActOnTheirRows() async throws {
        let runner = RecordingCosRunner()
        let opener = RecordingFileOpener()
        let model = try await model(runner: runner)
        model.fileOpener = opener
        await model.perform(.loadActivity(day: nil))
        #expect(model.activity?.events("failed").first?.text == "Brain call timed out after 240 s")
        model.moveActivityDay(-1, calendar: .utc)
        #expect(model.activityDay == "2026-09-22")
        model.moveActivityDay(1, calendar: .utc)
        #expect(model.activityDay == nil)

        model.viewMode = .artifacts
        await model.perform(.loadArtifacts)
        #expect(model.focusOrder == ["cc33dd44/artifacts/cc33dd44/quote-note.md"])
        model.moveCardFocus(1)
        model.openFocusedFile()
        let opened = try #require(model.paths.map { model.artifacts[0].url(in: $0) })
        await model.perform(.open(opened))
        #expect(await opener.opened == [opened])
        #expect(model.focusedDiscussion?.title == "Sam approved the budget; confirm the quote date")

        model.viewMode = .charter
        await model.perform(.loadCharter)
        #expect(model.charter?.sections.count == 6)
        #expect(model.rungs.map(\.rung) == ["status_note@sample-project", "task_close@*"])
        model.focusCard("task_close@*")
        model.removeFocusedRung()
        await model.perform(.never(rung: "task_close@*"))
        model.openAddRule()
        model.addRule?.text = "Newsletters"
        model.submitAddRule()
        await model.perform(.rule(text: "Newsletters", scope: "all"))
        model.openFocusedFile()
        await model.perform(.open(URL(fileURLWithPath: "/tmp/chief-of-staff-charter.md")))
        #expect(await opener.opened.last == URL(fileURLWithPath: "/tmp/chief-of-staff-charter.md"))
        let writes = await runner.writes
        #expect(writes.contains(.never(rung: "task_close@*")))
        #expect(writes.contains(.rule(text: "Newsletters", scope: "all")))
    }

    @Test func notificationsSkipAutoCardsTimeMeetingsAndQuietTheMorning() async throws {
        let items = try CosFixture.items().compactMap(\.proposal)
        let morning = try #require(items.first { $0.id == "mo123456" })
        let meeting = try #require(items.first { $0.id == "me654321" })
        let auto = try #require(items.first { $0.id == "au777777" })
        let notices = ChiefOfStaffNotificationRules.notices(
            for: [auto, morning, meeting], now: cosNow, quietHours: QuietHours(startHour: 0, endHour: 0)
        )
        #expect(notices == [
            .meeting(meeting, deliverAt: cosNow.addingTimeInterval(5 * 60)),
            .card(morning, .passive),
        ])
        let content = ChiefOfStaffNotificationContent(notices[0])
        #expect(content.interruptionLevel == .active)
        #expect(content.deliverAt == cosNow.addingTimeInterval(5 * 60))
        // A meeting already under ten minutes away notifies at once.
        let soon = ChiefOfStaffNotificationRules.notices(
            for: [meeting], now: cosNow.addingTimeInterval(10 * 60), quietHours: QuietHours(startHour: 0, endHour: 0)
        )
        #expect(soon == [.meeting(meeting, deliverAt: nil)])
    }

    @Test func autoCardsLeaveEarlierForFYI() throws {
        let items = try CosFixture.items()
        #expect(!ChiefOfStaffThread.history(in: items).contains { $0.id == "au777777" || $0.proposal?.id == "au777777" })
    }
}

@Suite("Chief of Staff contract v1 window", .serialized)
@MainActor
struct ChiefOfStaffV1WindowTests {
    private func rig() async throws -> (AIChatWindowModel, ChiefOfStaffModel, RecordingCosRunner) {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let chat = QuickViewModel(settings: settings, service: MockQuickService())
        let suite = "ChiefOfStaffV1WindowTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        window.window = FakeAIChatWindow()
        let runner = RecordingCosRunner()
        let cos = ChiefOfStaffModel(paths: try CosFixture.home(), runner: runner, clock: { cosNow })
        await cos.reload(force: true)
        chat.chiefOfStaff = cos
        chat.chiefOfStaffOpener = { window.openChiefOfStaff(proposalID: $0) }
        return (window, cos, runner)
    }

    private func key(_ window: AIChatWindowModel, _ key: VirtualKey?, _ characters: String? = nil, _ modifiers: NSEvent.ModifierFlags = []) -> Bool {
        window.handleChiefOfStaffKey(key: key, characters: characters, modifiers: modifiers)
    }

    @Test func cardKeysForFeedbackUndoAndDiscuss() async throws {
        let (window, cos, _) = try await rig()
        window.openChiefOfStaff(proposalID: "ee55ff66")
        #expect(key(window, nil, "=", [.command]))
        #expect(key(window, nil, "-", [.command]))
        #expect(window.focus == .cosForm)
        #expect(cos.lessPrompt?.proposalID == "ee55ff66")
        #expect(window.handleEscape())
        #expect(cos.lessPrompt == nil)
        #expect(window.focus == .cards)
        // ⌥⌘3 to ⌥⌘5 switch the pages; ⌘N in the Charter adds a rule.
        #expect(key(window, nil, "5", [.command, .option]))
        #expect(cos.viewMode == .charter)
        #expect(key(window, nil, "n", [.command]))
        #expect(cos.addRule != nil)
        #expect(window.focus == .cosForm)
        #expect(window.handleEscape())
        #expect(cos.addRule == nil)
        #expect(key(window, nil, "1", [.command, .option]))
        #expect(cos.viewMode == .list)
        withExtendedLifetime(cos) {}
    }

    @Test func aRungOfferIsAnsweredWithCommandYOrEscape() async throws {
        let (window, cos, runner) = try await rig()
        await runner.setStdout("OK   task_add: added\n")
        window.openChiefOfStaff()
        await cos.perform(.doIt(id: "ee55ff66"))
        #expect(cos.rungOffer != nil)
        #expect(window.handleEscape())
        #expect(cos.rungOffer == nil)
        await cos.perform(.doIt(id: "ee55ff66"))
        #expect(key(window, nil, "y", [.command]))
        #expect(cos.rungOffer == nil)
        // No offer, no ⌘Y: the key stays unhandled.
        #expect(!key(window, nil, "y", [.command]))
    }

    /// Discuss opens a NEW ordinary chat: the default provider and tools,
    /// titled with the headline, the card and its files on the tray; the
    /// pinned conversation is left and nothing is written to the thread.
    @Test func discussOpensANewOrdinaryChat() async throws {
        let (window, cos, runner) = try await rig()
        window.openChiefOfStaff(proposalID: "cc33dd44")
        let pinnedMessages = window.chat.currentConversation?.messages
        #expect(key(window, nil, "d", [.command]))
        #expect(!window.isChiefOfStaffOpen)
        let conversation = try #require(window.chat.currentConversation)
        #expect(conversation.id != ChiefOfStaffModel.conversationID)
        #expect(conversation.customTitle == "Sam approved the budget; confirm the quote date")
        #expect(conversation.enabledTools == nil)
        #expect(conversation.providerID == window.chat.settings.quickAIProvider?.id)
        #expect(conversation.messages.isEmpty)
        let names = window.chat.attachmentTray.items.map(\.name)
        #expect(names.first?.contains("Chief of Staff") == true)
        #expect(window.focus == .composer)
        #expect(await runner.writes.isEmpty)
        #expect(pinnedMessages?.isEmpty == true)
        withExtendedLifetime(cos) {}
    }

    @Test func theNewKeysDoNothingOutsideThePinnedConversation() async throws {
        let (window, cos, _) = try await rig()
        window.open(handoff: nil)
        for (characters, modifiers) in [
            ("=", NSEvent.ModifierFlags.command), ("-", [.command]), ("z", [.command]), ("d", [.command]),
            ("y", [.command]), ("3", [.command, .option]), ("5", [.command, .option]), ("[", [.command, .option]),
        ] as [(String, NSEvent.ModifierFlags)] {
            #expect(!key(window, nil, characters, modifiers))
        }
        withExtendedLifetime(cos) {}
    }
}

// MARK: - Memory design

@Suite("Chief of Staff memory design")
struct ChiefOfStaffMemoryDataTests {
    @Test func learningsDecodeAndNameTheirScope() throws {
        let rows = try CosLearning.decodeList(RecordingCosRunner.learningsJSON)
        #expect(rows.map(\.key) == ["k-newsletters", "k-charlie"])
        #expect(rows[0].created == Date(timeIntervalSince1970: 1_790_157_600))
        #expect(rows[1].source == "inferred" && rows[1].weight == 0.55)
        #expect(rows[0].scopeLabel() == "Everywhere")
        #expect(rows[1].scopeLabel { $0 == "sample-project" ? "Sample Project" : nil } == "Project: Sample Project")
        #expect(CosLearning(key: "k", text: "t", scope: "sender:Charlie").scopeLabel() == "Sender: Charlie")
        #expect(CosLearning(key: "k", text: "t", scope: "kind:meeting").scopeLabel() == "Cards: meeting")
        #expect(try CosLearning.decodeList("[]").isEmpty)
    }

    @Test func statusCarriesTheCallBudget() throws {
        let status = try CosStatus.decode(RecordingCosRunner.statusJSON)
        let calls = try #require(status.modelCalls)
        #expect(calls.maker == 12 && calls.cap.maker == 40 && calls.reviewer == 3 && calls.cap.reviewer == 10)
        #expect(calls.line == "Model calls today: 12 of 40, reviews 3 of 10")
        let paused = try CosStatus.decode(#"""
        {"paused": false, "model_calls": {"maker": 40, "reviewer": 1, "cap": {"maker": 40, "reviewer": 10},
         "failures_in_row": 3, "paused_until": "2026-09-24T10:30"}}
        """#)
        #expect(paused.modelCalls?.line.hasPrefix("Model calls today: 40 of 40, reviews 1 of 10. Paused until ") == true)
        #expect(paused.modelCalls?.line.hasSuffix("after 3 failures") == true)
        // An older cos without the budget still reads.
        #expect(try CosStatus.decode(#"{"paused": true}"#).modelCalls == nil)
    }

    @Test func runningCutOffAndConflictCardsDecode() throws {
        func card(_ extra: String) throws -> Proposal {
            let json = #"{"kind": "proposal", "id": "c", "status": "pending", "message": "m", "actions": [{"type": "status_note", "note": "n"}]\#(extra)}"#
            let values = try JSONDecoder().decode(ExtraFields.self, from: Data(json.utf8))
            return try #require(Proposal(values: values, fallbackText: "", fallbackDate: nil))
        }
        let plain = try card("")
        #expect(plain.canDoIt && !plain.isRunning && !plain.outcomeUnknown)
        let running = try card(#", "running": {"since": "2026-09-24T09:00:00Z", "pid": 42}"#)
        #expect(running.isRunning && !running.canDoIt)
        #expect(running.runningSince == Date(timeIntervalSince1970: 1_790_240_400))
        let cut = try card(#", "outcome_unknown": {"since": "2026-09-24T09:00:00Z"}, "tier": "decide""#)
        #expect(cut.outcomeUnknown && !cut.canDoIt)
        let offline = try card(#", "event_kind": "morning", "made_offline": true, "made_by": "rules""#)
        #expect(offline.madeOffline && offline.madeBy == "rules")
        #expect(!plain.madeOffline && plain.madeBy == nil)
        let conflict = try card(#", "event_kind": "learnings", "conflict": {"scope": "project:globex", "keys": ["a", "b"], "texts": ["Always", "Never"]}"#)
        #expect(conflict.conflict == Proposal.Conflict(scope: "project:globex", keys: ["a", "b"], texts: ["Always", "Never"]))
        let activity = try CosActivity.decode(#"{"day": "d", "ran": {"count": 1, "items": [{"time": "09:00", "text": "Status note", "state": "running", "run": "r1", "action": 0}]}}"#)
        #expect(activity.events("ran").first?.didNotFinish == true)
    }

    @Test func conflictKeysOnlyOnAConflictCard() {
        func route(_ c: String, conflict: Bool) -> ChiefOfStaffKeys.Action? {
            ChiefOfStaffKeys.route(key: nil, characters: c, modifiers: [], place: .card(board: false), hasCards: true, onConflict: conflict)
        }
        #expect(route("1", conflict: true) == .forgetConflict(0))
        #expect(route("2", conflict: true) == .forgetConflict(1))
        #expect(route("3", conflict: true) == nil)
        #expect(route("1", conflict: false) == nil)
    }
}

@Suite("Chief of Staff memory design model", .serialized)
@MainActor
struct ChiefOfStaffMemoryModelTests {
    private func model(runner: RecordingCosRunner = RecordingCosRunner()) async throws -> ChiefOfStaffModel {
        let model = ChiefOfStaffModel(paths: try CosFixture.home(), runner: runner, clock: { cosNow })
        await model.reload(force: true)
        return model
    }

    @Test func aCutOffOrRunningCardNeverRunsFromAKey() async throws {
        let runner = RecordingCosRunner()
        let model = try await model(runner: runner)
        var cut = Proposal(id: "cut", message: "m", tier: "today", actions: [ProposalAction(type: "status_note", fields: ["note": "n"])])
        cut.outcomeUnknownSince = cosNow
        var busy = Proposal(id: "busy", message: "m", tier: "today", actions: [ProposalAction(type: "task_add", fields: ["title": "t"])])
        busy.runningSince = cosNow
        let ok = Proposal(id: "ok", message: "m", tier: "today", actions: [ProposalAction(type: "task_add", fields: ["title": "t"])])
        model.override(items: [.proposal(turnID: "1", cut), .proposal(turnID: "2", busy), .proposal(turnID: "3", ok)], status: nil)
        model.focusCard("cut")
        model.doFocused()
        model.focusCard("busy")
        model.doFocused()
        model.doAllToday()
        #expect(model.bulkArmed == ["ok"])
        // Edit stays: an edited run is Tristan's explicit choice.
        model.focusCard("cut")
        model.editFocused()
        #expect(model.isEditingFocusedCard)
        #expect(await runner.writes.isEmpty)
    }

    @Test func charterShowsLearningsAndForgetsThem() async throws {
        let runner = RecordingCosRunner()
        let model = try await model(runner: runner)
        model.viewMode = .charter
        await model.perform(.loadCharter)
        #expect(model.learnings.map(\.key) == ["k-newsletters", "k-charlie"])
        #expect(model.focusOrder.prefix(2) == ["learning:k-newsletters", "learning:k-charlie"])
        model.focusCard("learning:k-charlie")
        model.removeFocusedRung()
        await model.perform(.forget(key: "k-charlie"))
        #expect(await runner.writes.contains(.forget(key: "k-charlie")))
        #expect(model.notice == "Forgotten.")
    }

    @Test func addRuleOffersThisProjectAndThisSenderFromTheCard() async throws {
        let runner = RecordingCosRunner()
        let model = try await model(runner: runner)
        model.openAddRule()
        #expect(model.addRule?.isAvailable(.project) == false)
        #expect(model.addRule?.isAvailable(.sender) == false)
        model.setAddRuleScope(.project)
        #expect(model.addRule?.scope == .everywhere)
        model.addRule = nil
        model.focusCard("cc33dd44")
        model.viewMode = .charter
        model.openAddRule()
        #expect(model.addRule?.project == "sample-project")
        #expect(model.addRule?.sender == "Sam Client")
        model.setAddRuleScope(.sender)
        model.addRule?.text = "Sam's dates are firm"
        model.submitAddRule()
        await model.perform(.rule(text: "Sam's dates are firm", scope: "sender:Sam Client"))
        #expect(await runner.writes.contains(.rule(text: "Sam's dates are firm", scope: "sender:Sam Client")))
        // Voice is a charter line, not a learning, and needs no card.
        model.openAddRule()
        model.setAddRuleScope(.voice)
        model.addRule?.text = "Warmer with clients"
        model.submitAddRule()
        await model.perform(.charterLine(text: "Warmer with clients", section: "voice"))
        #expect(await runner.writes.last == .charterLine(text: "Warmer with clients", section: "voice"))
        #expect(ChiefOfStaffModel.senderName("Charlie <w@example.com>") == "Charlie")
        #expect(ChiefOfStaffModel.senderName("Alex") == "Alex")
    }

    @Test func aConflictCardForgetsTheRowItNames() async throws {
        let runner = RecordingCosRunner()
        let model = try await model(runner: runner)
        var conflict = Proposal(id: "lc", eventKind: "learnings", message: "Two rules disagree", tier: "today")
        conflict.conflict = Proposal.Conflict(scope: "project:globex", keys: ["a", "b"], texts: ["Always", "Never"])
        model.override(items: [.proposal(turnID: "1", conflict)], status: nil)
        model.focusCard("lc")
        model.forgetConflict(1)
        await model.perform(.forget(key: "b"))
        #expect(await runner.writes == [.forget(key: "b")])
    }

    @Test func activityShowsTodaysCallBudget() async throws {
        let model = try await model()
        #expect(model.status?.modelCalls?.line == "Model calls today: 12 of 40, reviews 3 of 10")
    }
}
