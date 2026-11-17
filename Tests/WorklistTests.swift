import Foundation
import Testing
@testable import QuickLaunch

/// The plate as a worklist: numbered rows, and "3", "3 done", "3 open".
@Suite("Plate worklist")
@MainActor
struct WorklistTests {
    private static let json = #"""
    {"sections": {
      "Clean up": [{"key": "t:9", "text": "Old thing", "note": "looks done", "url": "https://app.todoist.com/app/task/9"}],
      "Do now": [{"key": "t:1", "text": "Send the guide", "note": "p1", "url": "https://app.todoist.com/app/task/1", "new": true}],
      "Next 3 days": [
        {"key": "c:2026-11-1707:30 Run club", "text": "Run club", "note": "Today"},
        {"key": "t:2", "text": "Check the backup drive", "note": "Wed 18 · p2", "url": "https://app.todoist.com/app/task/2"},
        {"key": "c:x3", "text": "C", "note": ""}, {"key": "c:x4", "text": "D", "note": ""},
        {"key": "c:x5", "text": "E", "note": ""}, {"key": "c:x6", "text": "F", "note": ""}
      ],
      "Ready to review": [{"key": "f:Runs:topline", "text": "topline v2", "note": ""}]
    }, "down": [], "more": {"Ready to review": 2}}
    """#

    @Test func rowsAreNumberedInThePlatesOwnOrderAndCaps() throws {
        let plate = try PlateSnapshot(json: Data(Self.json.utf8))
        #expect(plate.items.map(\.text) == ["Send the guide", "Run club", "Check the backup drive", "C", "D", "E", "topline v2", "Old thing"])
        #expect(plate.items.map(\.number) == Array(1...8))
        #expect(plate.text.contains("### Do now\n\n1. Send the guide · p1 · new"))
        #expect(plate.text.contains("+1 more"), "Next 3 days shows five; the sixth is counted")
        #expect(plate.text.contains("+2 more"), "the plate's own uncounted extras")
        #expect(plate.items[1].kindName == "work calendar event")
        #expect(plate.items[6].url == nil)
    }

    private func make() throws -> (QuickViewModel, MockQuickService, FakeWorkspace) {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let mock = MockQuickService()
        let workspace = FakeWorkspace()
        let vm = QuickViewModel(settings: settings, service: mock, workspace: workspace)
        return (vm, mock, workspace)
    }

    private func showPlate(_ vm: QuickViewModel, _ mock: MockQuickService) async throws {
        await mock.setResponses([StreamDelta(text: "Your plate…", finishReason: "stop")])
        vm.openQuickAI()
        vm.input = "whats on my plate"
        await vm.submit()
        let plate = try PlateSnapshot(json: Data(Self.json.utf8))
        let index = try #require(vm.currentConversation?.messages.indices.last)
        vm.currentConversation?.messages[index].toolRecords = [
            ChatToolRecord(kind: .plate, summary: "Read the plate", worklist: plate.items),
        ]
    }

    @Test func numbersBecomeTheRowsOwnWords() async throws {
        let (vm, mock, _) = try make()
        try await showPlate(vm, mock)

        guard case .ask(let focus) = vm.worklistCommand(for: "2") else { Issue.record("2 is a row"); return }
        #expect(focus.contains("“Run club”") && focus.contains("work calendar event") && focus.contains("no search first"))
        guard case .ask(let done) = vm.worklistCommand(for: "3 done") else { Issue.record("3 done"); return }
        #expect(done == "Plate item 3, “Check the backup drive” (Todoist task, Wed 18 · p2): done")
        #expect(vm.worklistCommand(for: "3. push to friday") != nil)
        guard case .ask(let verbFirst) = vm.worklistCommand(for: "move 2 to 18:00") else { Issue.record("verb first"); return }
        #expect(verbFirst.hasSuffix("“Run club” (work calendar event, Today): move to 18:00"))
        guard case .open = vm.worklistCommand(for: "open 3") else { Issue.record("open 3"); return }
        #expect(vm.worklistCommand(for: "call 3 people") == nil, "only the listed verbs lead")

        #expect(vm.worklistCommand(for: "42") == nil, "no such row")
        #expect(vm.worklistCommand(for: "3 people came to the group and stayed late") == nil, "a sentence")
        #expect(vm.worklistCommand(for: "3 what is this?") == nil, "a question about a number")
        #expect(vm.worklistCommand(for: "1500 words please") == nil)
    }

    @Test func openOpensTheRowsLinkWithoutTheModel() async throws {
        let (vm, mock, workspace) = try make()
        try await showPlate(vm, mock)
        vm.input = "3 open"
        await vm.submitTypedText()
        #expect(workspace.openedURLs == [URL(string: "https://app.todoist.com/app/task/2")!])
        #expect(vm.input.isEmpty)
        #expect(vm.composerConfirmation == "Opened 3. Check the backup drive")

        // A row with no link asks the model to open it.
        guard case .ask(let text) = vm.worklistCommand(for: "7 open") else { Issue.record("7 open"); return }
        #expect(text.hasPrefix("Open plate item 7"))
    }

    @Test func aTypedCommandReachesTheModelAsTheRow() async throws {
        let (vm, mock, _) = try make()
        try await showPlate(vm, mock)
        await mock.setResponses([StreamDelta(text: "Mark it done?", finishReason: "stop")])
        vm.input = "3 done"
        await vm.submitTypedText()
        let sent = await mock.lastMessages
        #expect(sent.last?.content == "Plate item 3, “Check the backup drive” (Todoist task, Wed 18 · p2): done")

        // Return in the composer takes the same road, past aliases and math.
        await mock.setResponses([StreamDelta(text: "Shown.", finishReason: "stop")])
        let index = try #require(vm.currentConversation?.messages.indices.last)
        vm.currentConversation?.messages[index].toolRecords = [
            ChatToolRecord(kind: .plate, summary: "Read the plate", worklist: try PlateSnapshot(json: Data(Self.json.utf8)).items),
        ]
        vm.input = "2"
        vm.submitFromComposer()
        await vm.composerSubmitTask?.value
        #expect(await mock.lastMessages.last?.content.hasPrefix("Plate item 2, “Run club”") == true)

        // After that answer a bare number is that answer's own list again,
        // while "N verb" still means the plate row.
        #expect(vm.worklistCommand(for: "1") == nil)
        #expect(vm.worklistCommand(for: "1 done") != nil)
    }
}
