import Testing
import Foundation
@testable import QuickLaunch

@Suite("Quick history store")
struct QuickHistoryStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.quicklaunch.history-tests.\(UUID().uuidString)")!
    }

    private func freshFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-history-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func loadDropsTheRetiredPinnedConversationAndKeepsTheRest() {
        let folder = freshFolder()
        let file = folder.appendingPathComponent(QuickHistoryStore.fileName)
        let retired = QuickConversation(
            id: QuickHistoryStore.retiredPinnedChatID,
            providerID: InferenceProvider.deepSeekID,
            model: "retired"
        )
        let ordinary = QuickConversation(providerID: InferenceProvider.deepSeekID, model: "ordinary")
        QuickHistoryStore.save([retired, ordinary], limit: 10, to: file)
        QuickHistoryStore.waitForPendingWrites()

        let loaded = QuickHistoryStore.load(from: file, migratingFrom: nil)

        #expect(loaded.map(\.model) == ["ordinary"])
    }

    @Test func aChatSavedWithRetiredCardFieldsStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","createdAt":0,"updatedAt":0,
         "providerID":"\(UUID().uuidString)","model":"m","isPinned":false,"cosCard":"3fa91c07",
         "messages":[{"id":"\(UUID().uuidString)","role":"assistant","content":"Done.",
                      "cosTell":{"card":"3fa91c07"}}]}
        """
        let conversation = try JSONDecoder().decode(QuickConversation.self, from: Data(json.utf8))

        #expect(conversation.messages.map(\.content) == ["Done."])
        #expect(conversation.model == "m")
    }

    @Test func upsertKeepsNewestConversationAndBoundsHistory() {
        let providerID = InferenceProvider.deepSeekID
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

    @Test func saveAndLoadRoundTrip() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chat-history.json")
        let conversation = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "deepseek-v4-flash",
            messages: [QuickMessage(role: .user, content: "Hello")]
        )

        QuickHistoryStore.save([conversation], limit: 20, to: file)
        QuickHistoryStore.waitForPendingWrites()
        let loaded = QuickHistoryStore.load(from: file, migratingFrom: nil)

        #expect(loaded == [conversation])
        #expect(loaded.first?.title == "Hello")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        // The file carries the schema envelope.
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == QuickHistoryStore.schemaVersion)
    }

    @Test func clearRemovesSavedHistory() {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chat-history.json")
        let defaults = freshDefaults()
        defaults.set(Data("[]".utf8), forKey: QuickHistoryStore.defaultsKey)
        let conversation = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "apple-foundationmodel"
        )
        QuickHistoryStore.save([conversation], limit: 20, to: file)

        QuickHistoryStore.clear(from: file, defaults: defaults)
        QuickHistoryStore.waitForPendingWrites()

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(defaults.data(forKey: QuickHistoryStore.defaultsKey) == nil)
        #expect(QuickHistoryStore.load(from: file, migratingFrom: defaults).isEmpty)
    }

    @Test func firstLoadMigratesUserDefaultsBlobIntoTheFile() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chat-history.json")
        let defaults = freshDefaults()
        let conversation = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "legacy",
            messages: [QuickMessage(role: .user, content: "From defaults")]
        )
        defaults.set(try JSONEncoder().encode([conversation]), forKey: QuickHistoryStore.defaultsKey)

        let migrated = QuickHistoryStore.load(from: file, migratingFrom: defaults)

        #expect(migrated == [conversation])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(defaults.data(forKey: QuickHistoryStore.defaultsKey) == nil)
        // A second load reads the file and no longer needs UserDefaults.
        #expect(QuickHistoryStore.load(from: file, migratingFrom: nil) == [conversation])
    }

    @Test func existingFileWinsOverStaleDefaults() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chat-history.json")
        let defaults = freshDefaults()
        let fromFile = QuickConversation(providerID: InferenceProvider.deepSeekID, model: "file")
        let fromDefaults = QuickConversation(providerID: InferenceProvider.deepSeekID, model: "defaults")
        defaults.set(try JSONEncoder().encode([fromDefaults]), forKey: QuickHistoryStore.defaultsKey)
        QuickHistoryStore.save([fromFile], limit: 20, to: file)
        QuickHistoryStore.waitForPendingWrites()

        #expect(QuickHistoryStore.load(from: file, migratingFrom: defaults) == [fromFile])
    }
}
