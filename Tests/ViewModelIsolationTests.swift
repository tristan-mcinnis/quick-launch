// ViewModelIsolationTests — a view model built without its system seams
// touches nothing on the Mac: its pasteboard is in memory and its chat
// history never reaches disk. The app passes the real ones (AppDelegate).
// Every other suite relies on this, so a test run cannot replace the user's
// clipboard or chat-history.json.

import Foundation
import Testing
@testable import QuickLaunch

@Suite("View model isolation", .serialized)
@MainActor
struct ViewModelIsolationTests {
    private func freshFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-isolation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func answer(_ vm: QuickViewModel, _ mock: MockQuickService, _ question: String) async {
        await mock.setResponses([StreamDelta(text: "An answer.", finishReason: "stop")])
        vm.input = question
        await vm.submit()
    }

    @Test func theDefaultPasteboardIsInMemory() {
        let vm = QuickViewModel()
        #expect(vm.pasteboard is InMemoryPasteboard, "never SystemPasteboard unless the app passes it")
        vm.pasteboard.writeString("kept here")
        #expect(vm.pasteboard.readString() == "kept here")
    }

    @Test func historyStaysInMemoryWithoutAFile() async {
        let mock = MockQuickService()
        let vm = QuickViewModel(service: mock)
        #expect(vm.historyFileURL == nil)
        #expect(vm.settings.historyEnabled, "the default setting is on, and still writes nothing")
        await answer(vm, mock, "hello")
        #expect(vm.history.count == 1, "Recent Chats still has the chat")

        vm.loadHistory()
        #expect(vm.history.isEmpty, "there is no file to read")
        vm.clearHistory()
        #expect(vm.history.isEmpty)
    }

    @Test func historyGoesToTheFileItIsGiven() async throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chat-history.json")
        let mock = MockQuickService()
        let vm = QuickViewModel(service: mock, historyFileURL: file)
        await answer(vm, mock, "/grammar teh text")
        QuickHistoryStore.waitForPendingWrites()

        let saved = QuickHistoryStore.load(from: file, migratingFrom: nil)
        #expect(saved.count == 1)
        #expect(saved.first?.titleSource == "/grammar teh text", "the typed question is kept for the title")

        let reopened = QuickViewModel(historyFileURL: file)
        reopened.loadHistory()
        #expect(reopened.history.map(\.id) == saved.map(\.id))
        #expect(reopened.title(of: reopened.history[0]) == "Teh text")

        reopened.clearHistory()
        QuickHistoryStore.waitForPendingWrites()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
