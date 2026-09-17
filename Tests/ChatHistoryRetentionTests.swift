import Testing
import Foundation
import HouseChatCore
@testable import QuickLaunch

/// Keep-all retention: the canonical archive is the authority for what is
/// read and kept, a confirmed deletion really empties it, and a damaged
/// record blocks the deletion instead of being reported as cleared.
@Suite("Chat history retention", .serialized)
@MainActor
struct ChatHistoryRetentionTests {

    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-history-\(UUID())")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func answeringService(_ text: String = "the answer") async -> MockQuickService {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: text, finishReason: "stop")])
        return service
    }

    private func waitForClear(_ vm: QuickViewModel) async {
        for _ in 0..<600 {
            if !vm.isClearingHistory { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func chatFiles(in directory: URL) -> [URL] {
        let chats = directory.appendingPathComponent("chats")
        return (try? FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
    }

    // MARK: - Clear and reload

    @Test func confirmedDeletionEmptiesTheArchiveAndReloadsEmpty() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyFile = directory.appendingPathComponent("chat-history.json")
        let vm = QuickViewModel(
            service: await answeringService(),
            historyFileURL: historyFile,
            archiveRootURL: directory
        )
        vm.settings.autoCopy = false
        vm.input = "keep this"
        await vm.submit()

        let archive = try #require(vm.chatArchive)
        #expect(try await archive.loadAll().count == 1)
        #expect(vm.history.count == 1)

        vm.clearHistory()
        #expect(vm.isClearingHistory, "the operation is visible while it runs")
        await waitForClear(vm)

        #expect(vm.savedHistoryOperationError == nil)
        #expect(vm.history.isEmpty)
        #expect(vm.currentConversation == nil)
        // A genuinely fresh reader of the same root sees nothing.
        let reloaded = try ChatArchive(root: directory)
        #expect(try await reloaded.loadAll().isEmpty)
        #expect(QuickHistoryStore.load(from: historyFile).isEmpty)
    }

    @Test func aDamagedRecordBlocksTheDeletionAndIsNotReportedAsCleared() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        // Two chats, seeded straight into the archive so nothing else can be
        // mid-write when the record is damaged.
        for text in ["keep me", "and me"] {
            var conversation = QuickConversation(providerID: UUID(), model: "m")
            conversation.messages.append(QuickMessage(role: .user, content: text))
            _ = try await archive.submit(TurnSubmission(
                conversation: conversation,
                requestSnapshot: Data(#"{"model":"m"}"#.utf8)
            ))
        }
        let file = try #require(chatFiles(in: directory).first)
        try Data("{ not a record".utf8).write(to: file)

        let vm = QuickViewModel(
            service: await answeringService(),
            historyFileURL: directory.appendingPathComponent("chat-history.json"),
            archiveRootURL: directory
        )
        vm.history = try await archive.rebuildProjections()
        let before = vm.history.count
        #expect(before == 1, "the readable chat is the list; the damaged one is reported separately")

        vm.clearHistory()
        await waitForClear(vm)

        #expect(vm.savedHistoryOperationError != nil, "a refused deletion is reported")
        #expect(vm.history.count == before, "the list is not falsely emptied")
        #expect(try await archive.readableRecords().damaged.count == 1, "the damaged record is still there")
        #expect(try await archive.readableRecords().records.count == 1, "the readable chat was not deleted")
        #expect(FileManager.default.fileExists(atPath: file.path), "the damaged record is retained, never destroyed")
    }

    @Test func deleteAllRefusesWhenAnyRecordCannotBeRead() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        var conversation = QuickConversation(providerID: UUID(), model: "m")
        let message = QuickMessage(role: .user, content: "keep")
        conversation.messages.append(message)
        _ = try await archive.submit(TurnSubmission(conversation: conversation, requestSnapshot: Data("{}".utf8)))
        let file = try #require(chatFiles(in: directory).first)
        try Data("{ not a record".utf8).write(to: file)

        await #expect(throws: (any Error).self) {
            _ = try await archive.deleteAll()
        }
        #expect(!(await archive.isDeleted(id: conversation.id.uuidString)))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - The legacy switch no longer gates the canonical store

    @Test func aDisabledLegacySwitchDoesNotGateOrHideTheCanonicalArchive() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyFile = directory.appendingPathComponent("chat-history.json")
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        settings.historyLimit = 20
        let vm = QuickViewModel(
            settings: settings,
            service: await answeringService(),
            historyFileURL: historyFile,
            archiveRootURL: directory
        )
        vm.input = "still kept"
        await vm.submit()

        let archive = try #require(vm.chatArchive)
        #expect(try await archive.loadAll().count == 1, "the canonical archive keeps the chat")
        #expect(vm.history.count == 1, "the chat is not hidden from the list")
        #expect(vm.settings.historyEnabled == false, "the old key is preserved for rollback")
        #expect(vm.settings.historyLimit == 20, "the old count is preserved too")
    }

    @Test func theCanonicalArchiveIsNotCappedByTheLegacyCount() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyFile = directory.appendingPathComponent("chat-history.json")
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyLimit = 1
        let service = await answeringService()
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            historyFileURL: historyFile,
            archiveRootURL: directory
        )
        for text in ["one", "two", "three"] {
            vm.startNewConversation()
            vm.input = text
            await vm.submit()
        }
        let archive = try #require(vm.chatArchive)
        #expect(try await archive.loadAll().count == 3)
        #expect(vm.history.count == 3, "the list is the archive, not the bounded cache")
    }

    // MARK: - Deletion is reference-safe and final

    @Test func deletingOneChatKeepsABlobAnotherChatStillReferences() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let shared = Data("the same attached bytes".utf8)

        func submit() async throws -> String {
            let conversation = QuickConversation(providerID: UUID(), model: "m")
            var provisional = conversation
            provisional.messages.append(QuickMessage(role: .user, content: "q"))
            _ = try await archive.submit(TurnSubmission(
                conversation: provisional,
                requestSnapshot: shared,
                requestSnapshotKind: "requestSansKey"
            ))
            return conversation.id.uuidString
        }

        let first = try await submit()
        let second = try await submit()
        _ = try await archive.delete(id: first)

        let refs = try await archive.load(id: second)
        let turn = try #require(refs.turns.first { $0.role == .user })
        let snapshot = try #require(turn.request?.attachmentRefs.first { $0.kind == "requestSansKey" })
        let hash = try #require(snapshot.snapshotHash)
        let data = try await archive.readArtifact(ArtifactRef(
            kind: .requestSnapshot,
            sha256: hash,
            byteCount: snapshot.byteCount ?? 0
        ))
        #expect(data == shared, "the other chat's bytes are still there")
    }

    @Test func deleteAllTombstonesEveryChatSoALateWriteCannotRecreateOne() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let conversation = QuickConversation(providerID: UUID(), model: "m")
        let message = QuickMessage(role: .user, content: "q")
        var provisional = conversation
        provisional.messages.append(message)
        _ = try await archive.submit(TurnSubmission(
            conversation: provisional,
            requestSnapshot: Data("{}".utf8)
        ))

        let report = try await archive.deleteAll()
        #expect(report.isComplete)
        #expect(report.deletedIDs == [conversation.id.uuidString])
        #expect(report.failedIDs.isEmpty)
        #expect(await archive.isDeleted(id: conversation.id.uuidString))
        #expect(try await archive.loadAll().isEmpty)

        // An answer already in flight cannot bring the chat back.
        await #expect(throws: (any Error).self) {
            _ = try await archive.checkpoint(
                conversationID: conversation.id.uuidString,
                turnID: UUID().uuidString,
                update: .completed(text: "late")
            )
        }
    }

    // MARK: - The legacy store keeps its old behavior

    @Test func withoutAnArchiveTheOldSwitchStillBoundsTheOnlyStore() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let historyFile = directory.appendingPathComponent("chat-history.json")
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: await answeringService(),
            historyFileURL: historyFile
        )
        vm.input = "not kept"
        await vm.submit()
        #expect(vm.history.isEmpty, "the legacy switch still decides when it is the only store")
        #expect(QuickHistoryStore.load(from: historyFile).isEmpty)

        vm.clearHistory()
        await waitForClear(vm)
        #expect(vm.savedHistoryOperationError == nil)
    }
}
