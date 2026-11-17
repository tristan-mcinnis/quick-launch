import Foundation
import Testing
@testable import QuickLaunch

/// Rescheduling, finishing and moving things that already exist
/// (2026-11-17). The model names an item in words; only one exact match
/// becomes a proposal; Return makes the change and ⌘Z puts it back.
@Suite("Change tools")
@MainActor
struct ChangeToolsTests {
    private static let backup = TaskMatch(id: "t1", content: "Check the backup drive", dueDate: "2026-11-18", recurring: false)
    private static func runClub(_ start: String, attendees: Int = 0) -> EventMatch {
        EventMatch(id: "e-\(start)", subject: "Run club", start: start, attendees: attendees, isAllDay: false)
    }

    // MARK: - Proposing

    @Test func oneMatchingTaskBecomesAProposal() async throws {
        let harness = FakeHarness()
        await harness.setTasks([Self.backup])
        let toolbox = ChatToolbox(enabled: [.tasks], harness: harness)
        let outcome = try #require(await toolbox.run("propose_task_change", arguments: #"{"task":"RAM","action":"reschedule","due":"friday"}"#))
        let change = try #require(outcome.record.change)
        #expect(change == ChangeProposal(id: change.id, kind: .reschedule, targetID: "t1", title: "Check the backup drive", from: "2026-11-18", to: "friday"))
        #expect(outcome.content.contains("not changed"))
        #expect(await harness.applied.isEmpty, "proposing changes nothing")
    }

    @Test func manyOrNoOrRepeatingTasksProposeNothing() async throws {
        let harness = FakeHarness()
        let toolbox = ChatToolbox(enabled: [.tasks], harness: harness)
        let args = #"{"task":"review","action":"complete"}"#

        let none = try #require(await toolbox.run("propose_task_change", arguments: args))
        #expect(none.record.change == nil)
        #expect(none.status == .refused)

        await harness.setTasks([Self.backup, TaskMatch(id: "t2", content: "Review the deck", dueDate: "", recurring: false)])
        let many = try #require(await toolbox.run("propose_task_change", arguments: args))
        #expect(many.record.change == nil)
        #expect(many.content.contains("Review the deck") && many.content.contains("which one"))

        await harness.setTasks([TaskMatch(id: "t3", content: "Weekly review", dueDate: "2026-11-21", recurring: true)])
        let repeating = try #require(await toolbox.run("propose_task_change", arguments: args))
        #expect(repeating.record.change == nil)
        #expect(repeating.content.contains("repeats"))

        let noDate = try #require(await toolbox.run("propose_task_change", arguments: #"{"task":"RAM","action":"reschedule"}"#))
        #expect(noDate.status == .refused)
    }

    @Test func anEventMovesOnlyWhenItIsOneSoloEventAhead() async throws {
        let harness = FakeHarness()
        let toolbox = ChatToolbox(enabled: [.calendar], harness: harness)
        // A repeating event: past ones are ignored, and the one on the day
        // it moves within is the one.
        await harness.setEvents([Self.runClub("2026-11-12 19:30"), Self.runClub("2026-11-17 07:30"), Self.runClub("2026-11-19 19:30")])
        let move = await toolbox.proposeEventMove(harness, arguments: #"{"event":"run club","new_start":"2026-11-17 18:00"}"#, today: "2026-11-17")
        let change = try #require(move.record.change)
        #expect(change.kind == .moveEvent && change.targetID == "e-2026-11-17 07:30" && change.to == "2026-11-17 18:00")

        // Moving it to a day with no Run club is ambiguous between the two ahead.
        let vague = await toolbox.proposeEventMove(harness, arguments: #"{"event":"run club","new_start":"2026-11-18 18:00"}"#, today: "2026-11-17")
        #expect(vague.record.change == nil)
        #expect(vague.content.contains("which one"))
        let named = await toolbox.proposeEventMove(harness, arguments: #"{"event":"run club","on_date":"2026-11-19","new_start":"2026-11-18 18:00"}"#, today: "2026-11-17")
        #expect(named.record.change?.targetID == "e-2026-11-19 19:30")

        // Attendees would be emailed: refused.
        await harness.setEvents([Self.runClub("2026-11-17 07:30", attendees: 2)])
        let shared = await toolbox.proposeEventMove(harness, arguments: #"{"event":"run club","new_start":"2026-11-17 18:00"}"#, today: "2026-11-17")
        #expect(shared.record.change == nil)
        #expect(shared.status == .refused && shared.content.contains("Outlook"))

        let badTime = await toolbox.proposeEventMove(harness, arguments: #"{"event":"run club","new_start":"6pm"}"#, today: "2026-11-17")
        #expect(badTime.status == .refused)
    }

    // MARK: - Return and ⌘Z

    @Test func returnMakesTheChangeAndUndoPutsItBack() async throws {
        let mock = MockQuickService()
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: mock)
        let harness = FakeHarness()
        vm.harnessScripts = harness
        await mock.setResponses([StreamDelta(text: "Move Run club to 18:00?", finishReason: "stop")])
        vm.openQuickAI()
        vm.input = "move run club to 18:00"
        await vm.submit()
        let change = ChangeProposal(kind: .moveEvent, targetID: "e1", title: "Run club", from: "2026-11-17 07:30", to: "2026-11-17 18:00")
        let index = try #require(vm.currentConversation?.messages.indices.last)
        vm.currentConversation?.messages[index].toolRecords = [
            ChatToolRecord(kind: .changeProposal, summary: change.line, change: change),
        ]
        #expect(vm.quickAIComposerAction.label == "Move Event")
        #expect(vm.undoableChange == nil)

        await vm.submitTypedText()
        #expect(await harness.applied == [change])
        #expect(vm.pendingAction == nil)
        #expect(vm.undoableChange?.change == change)
        #expect(vm.conversationMessages.last?.tools.last?.kind == .changeDone)

        await vm.undoLastChange()
        let undo = try #require(await harness.applied.last)
        #expect(undo.kind == .moveEvent && undo.to == "2026-11-17 07:30", "the inverse goes back to the old start")
        #expect(vm.undoableChange == nil, "one undo per change")
        #expect(vm.composerConfirmation == "Undone")
    }

    @Test func inversesPutThingsBack() {
        let reschedule = ChangeProposal(kind: .reschedule, targetID: "t1", title: "Backup", from: "2026-11-18", to: "friday")
        #expect(reschedule.inverse.to == "2026-11-18")
        #expect(ChangeProposal(kind: .complete, targetID: "t1", title: "Backup").inverse.kind == .reopen)
    }

    // MARK: - The scripts

    @Test func eachChangeRunsItsScriptWithSeparateArguments() async throws {
        let runs = RunLog()
        let scripts = HarnessScripts(run: runs.runner(stdout: #"{"before": {}}"#), python: { URL(fileURLWithPath: "/usr/bin/true") }, root: HarnessToolsTests.skillsStub())
        try await scripts.apply(ChangeProposal(kind: .reschedule, targetID: "t1", title: "x", to: "2026-11-18"))
        try await scripts.apply(ChangeProposal(kind: .reschedule, targetID: "t1", title: "x", to: "next friday"))
        try await scripts.apply(ChangeProposal(kind: .complete, targetID: "t1", title: "x"))
        let calls = await runs.calls.map { Array($0.dropFirst()) }
        #expect(calls == [
            ["reschedule", "t1", "--due-date", "2026-11-18"],
            ["reschedule", "t1", "--due", "next friday"],
            ["complete", "t1"],
        ])
    }

    @Test func aMoveThatOnlyPrintedADryRunIsAFailure() async {
        let scripts = HarnessScripts(
            run: RunLog().runner(stdout: #"{"dry_run": true, "summary": "move it"}"#),
            python: { URL(fileURLWithPath: "/usr/bin/true") }, root: HarnessToolsTests.skillsStub()
        )
        await #expect(throws: HarnessScriptError.self) {
            try await scripts.apply(ChangeProposal(kind: .moveEvent, targetID: "e1", title: "x", to: "2026-11-17 18:00"))
        }
    }
}
