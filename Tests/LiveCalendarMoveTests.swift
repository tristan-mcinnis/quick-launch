import Foundation
import Testing
@testable import QuickLaunch

/// The event move on the real work calendar, through the app's own code:
/// find the event by its words, propose the move, apply it, and read it
/// back. Opt-in, because it writes: make a solo hold first, then
///   QUICK_LAUNCH_LIVE_CALENDAR="<subject>|<yyyy-MM-dd HH:mm new start>" \
///     swift test --filter LiveCalendarMoveTests
/// and cancel the hold afterwards. Nothing here creates or deletes an event.
@Suite("Live calendar move", .enabled(if: ProcessInfo.processInfo.environment["QUICK_LAUNCH_LIVE_CALENDAR"] != nil))
struct LiveCalendarMoveTests {
    @Test func aSoloHoldMovesAndReadsBackAtItsNewTime() async throws {
        let spec = try #require(ProcessInfo.processInfo.environment["QUICK_LAUNCH_LIVE_CALENDAR"])
        let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
        try #require(parts.count == 2)
        let (subject, newStart) = (parts[0], parts[1])
        let harness = try #require(HarnessScripts.installed(), "the skills scripts are on this Mac")
        let toolbox = ChatToolbox(enabled: [.calendar], harness: harness)

        let outcome = try #require(await toolbox.run(
            "propose_event_move",
            arguments: "{\"event\":\"\(subject)\",\"new_start\":\"\(newStart)\"}"
        ))
        let change = try #require(outcome.record.change, "one solo event matched: \(outcome.content)")
        #expect(change.kind == .moveEvent)
        try await harness.apply(change)

        let after = try await harness.findEvents(subject)
        #expect(after.contains { $0.id == change.targetID && $0.start == newStart }, "read back at \(newStart): \(after)")

        // ⌘Z: the inverse puts it back.
        try await harness.apply(change.inverse)
        let back = try await harness.findEvents(subject)
        #expect(back.contains { $0.id == change.targetID && $0.start == change.from })
    }
}
