import Foundation
import Testing
@testable import QuickLaunch

/// The calendar as a numbered worklist, the clock away from China, and the
/// plate's five-minute memory.
@Suite("Calendar rows and the plate cache")
struct CalendarAndCacheTests {
    /// 2026-11-18 13:43 in Beijing.
    static let at = Date(timeIntervalSince1970: 1_794_980_580)

    static let agenda = """
        Wed 2026-11-18
          2026-11-18 12:00-13:00  Naming workshop   @Forum  [16 attendees]  org:Someone
          2026-11-18 15:00-16:00  Diagnosis catch-up   @Right Room  [2 attendees]
        Thu 2026-11-19
          2026-11-19 09:00-09:30  Run club
        """

    @Test func eventsAreNumberedAndAFinishedOneSaysOver() {
        #expect(CalendarListing.minute(Self.at) == "2026-11-18 13:43")
        let listing = CalendarListing.numbered(Self.agenda, now: Self.at)
        #expect(listing.items.map(\.number) == [1, 2, 3])
        #expect(listing.items.map(\.text) == ["Naming workshop", "Diagnosis catch-up", "Run club"])
        #expect(listing.items[0].note.hasSuffix(", over"))
        #expect(!listing.items[1].note.contains("over"))
        #expect(listing.text.contains("### Wed 2026-11-18\n\n1. 12:00-13:00 Naming workshop @Forum [16 attendees] org:Someone · over"))
        #expect(listing.text.contains("### Thu 2026-11-19\n\n3. 09:00-09:30 Run club"))
        #expect(listing.items[1].reference.hasPrefix("calendar row 2, “Diagnosis catch-up” (work calendar event"))
        let rendered = MarkdownRenderer.render(listing.text).string
        #expect(rendered.contains("2. 15:00-16:00 Diagnosis catch-up"), "numbers survive markdown")
    }

    @Test func freeSlotsAndOddTextPassThroughUnnumbered() {
        let listing = CalendarListing.numbered("Thu 10:00-11:00 free", now: Self.at)
        #expect(listing.items.isEmpty)
        #expect(listing.text == "Thu 10:00-11:00 free")
    }

    @Test func theClockNamesTheLocalTimeOnlyAwayFromChina() throws {
        #expect(ChatToolbox.localNote(Self.at, local: try #require(TimeZone(identifier: "Asia/Shanghai"))) == "")
        let london = try #require(TimeZone(identifier: "Europe/London"))
        #expect(ChatToolbox.nowLine(Self.at, local: london)
            .contains("Now: Wednesday 2026-11-18 13:43, China Standard Time; where the user is it is Wednesday 2026-11-18 05:43 (Europe/London)"))
        #expect(QuickViewModel.todayLine(Self.at, local: london).hasPrefix("Today is Wednesday 2026-11-18, China Standard Time; where the user is"))
    }

    @Test func aCalendarReadIsAWorklistTheUserCanActOn() async throws {
        let harness = AgendaHarness(text: Self.agenda)
        let toolbox = ChatToolbox(enabled: [.calendar], harness: harness, now: { Self.at })
        let outcome = try #require(await toolbox.run("read_calendar", arguments: #"{"mode":"agenda"}"#))
        #expect(outcome.record.worklist?.count == 3)
        #expect(outcome.content.contains("2. 15:00-16:00 Diagnosis catch-up"))
        let free = try #require(await toolbox.run("read_calendar", arguments: #"{"mode":"free"}"#))
        #expect(free.record.worklist == nil, "free slots are not events")
    }

    @Test func thePlateIsReusedForFiveMinutesAndForgottenAfterAWrite() async throws {
        let inner = CountingHarness()
        let clock = CacheTestClock(Self.at)
        let cached = CachedHarness(inner, now: { clock.now })
        let first = try await cached.plate()
        #expect(first.readAt == Self.at)
        clock.now = Self.at.addingTimeInterval(240)
        _ = try await cached.plate()
        #expect(await inner.reads == 1, "four minutes later the first read comes back")
        _ = try await cached.plate(fresh: true)
        #expect(await inner.reads == 2, "a refresh reads again")
        try await cached.apply(ChangeProposal(kind: .complete, targetID: "1", title: "x"))
        _ = try await cached.plate()
        #expect(await inner.reads == 3, "a change makes the copy old")
        clock.now = Self.at.addingTimeInterval(240 + 301)
        _ = try await cached.plate()
        #expect(await inner.reads == 4, "after five minutes it reads again")
    }

    @Test func anOldPlateSaysWhenItWasRead() async throws {
        let inner = CountingHarness()
        let clock = CacheTestClock(Self.at)
        let cached = CachedHarness(inner, now: { clock.now })
        _ = try await cached.plate()
        clock.now = Self.at.addingTimeInterval(180)
        let toolbox = ChatToolbox(enabled: [.tasks], harness: cached, now: { clock.now })
        let outcome = try #require(await toolbox.run("show_plate", arguments: "{}"))
        #expect(outcome.content.contains("read at 13:43, 3 min ago"))
        _ = try #require(await toolbox.run("show_plate", arguments: #"{"refresh":true}"#))
        #expect(await inner.reads == 2)
    }

    @Test func memorysTaskListStepsBackWhenThePlateIsOffered() {
        func description(_ toolbox: ChatToolbox) -> String {
            let tool = toolbox.definitions.first { ($0["function"] as? [String: Any])?["name"] as? String == "recall_tasks_today" }
            return ((tool?["function"] as? [String: Any])?["description"] as? String) ?? ""
        }
        let alone = ChatToolbox(enabled: [.tasks], memory: FakeMemory())
        let withPlate = ChatToolbox(enabled: [.tasks], memory: FakeMemory(), harness: CountingHarness())
        #expect(description(alone).contains("what is on their plate"))
        #expect(description(withPlate).contains("call show_plate instead"))
        #expect(!description(withPlate).hasPrefix("Read the user's tasks due today"))
    }
}

final class CacheTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

actor CountingHarness: HarnessScripting {
    private(set) var reads = 0
    func plate() async throws -> PlateSnapshot {
        reads += 1
        return PlateSnapshot(items: [], text: "### Do now\n\n1. Thing")
    }
    func calendar(_ arguments: [String]) async throws -> String { "" }
    func addTodoist(_ proposal: TodoistProposal) async throws -> TodoistAdded { TodoistAdded(url: "") }
    func findTasks(_ words: String) async throws -> [TaskMatch] { [] }
    func findEvents(_ words: String) async throws -> [EventMatch] { [] }
    func apply(_ change: ChangeProposal) async throws {}
}

struct AgendaHarness: HarnessScripting {
    var text: String
    func plate() async throws -> PlateSnapshot { PlateSnapshot(items: [], text: "") }
    func calendar(_ arguments: [String]) async throws -> String { arguments.first == "free" ? "Thu 10:00-11:00 free" : text }
    func addTodoist(_ proposal: TodoistProposal) async throws -> TodoistAdded { TodoistAdded(url: "") }
    func findTasks(_ words: String) async throws -> [TaskMatch] { [] }
    func findEvents(_ words: String) async throws -> [EventMatch] { [] }
    func apply(_ change: ChangeProposal) async throws {}
}
