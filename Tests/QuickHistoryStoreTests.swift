import Testing
import Foundation
@testable import QuickLaunch

@Suite("Quick history store")
struct QuickHistoryStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.quicklaunch.history-tests.\(UUID().uuidString)")!
    }

    @Test func upsertKeepsNewestConversationAndBoundsHistory() {
        let providerID = InferenceProvider.managedApfelID
        let old = QuickConversation(
            updatedAt: Date(timeIntervalSince1970: 1),
            providerID: providerID,
            model: "old"
        )
        let newest = QuickConversation(
            updatedAt: Date(timeIntervalSince1970: 3),
            providerID: providerID,
            model: "new"
        )
        let middle = QuickConversation(
            updatedAt: Date(timeIntervalSince1970: 2),
            providerID: providerID,
            model: "middle"
        )

        var result = QuickHistoryStore.upserting(old, into: [], limit: 2)
        result = QuickHistoryStore.upserting(newest, into: result, limit: 2)
        result = QuickHistoryStore.upserting(middle, into: result, limit: 2)

        #expect(result.map(\.model) == ["new", "middle"])
    }

    @Test func saveAndLoadRoundTrip() {
        let defaults = freshDefaults()
        let conversation = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "deepseek-v4-flash",
            messages: [QuickMessage(role: .user, content: "Hello")]
        )

        QuickHistoryStore.save([conversation], limit: 20, to: defaults)
        let loaded = QuickHistoryStore.load(from: defaults)

        #expect(loaded == [conversation])
        #expect(loaded.first?.title == "Hello")
    }

    @Test func clearRemovesSavedHistory() {
        let defaults = freshDefaults()
        let conversation = QuickConversation(
            providerID: InferenceProvider.managedApfelID,
            model: "apple-foundationmodel"
        )
        QuickHistoryStore.save([conversation], limit: 20, to: defaults)

        QuickHistoryStore.clear(from: defaults)

        #expect(QuickHistoryStore.load(from: defaults).isEmpty)
    }
}
