import Foundation
import HouseChatCore
import Testing
@testable import QuickLaunch

@Suite("Archive projection merge", .timeLimit(.minutes(1)))
struct ArchiveProjectionMergeTests {
    private let finishedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = ChatToolRecord(
        kind: .web, summary: "Later result", sources: [ChatSource(title: "Later source")]
    )
    private let earlier = ChatToolRecord(
        kind: .memory, summary: "Earlier result", sources: [ChatSource(title: "Earlier source")], failed: true
    )

    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("projection-merge-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Read persisted bytes, not the writer's cache (which can retain finer
    /// timestamp precision than the archive's date encoding).
    private func readRecord(root: URL, id: UUID) throws -> ConversationRecord {
        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("chats", isDirectory: true), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        try #require(files.count == 1)
        let record = try HouseChatCoding.makeDecoder()
            .decode(ConversationEnvelope.self, from: Data(contentsOf: files[0])).conversation
        try #require(record.id == id.uuidString)
        return record
    }

    private func conversation() -> QuickConversation {
        QuickConversation(providerID: UUID(), model: "fixture-model", messages: [
            QuickMessage(role: .user, content: "Fixture question"),
            QuickMessage(role: .assistant, content: String(repeating: "a", count: 1_000), toolRecords: [later]),
        ], isPinned: true)
    }

    @Test func replayDoesNotUndoADurableUnpin() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let older = conversation()
        try await archive.syncConversation(older)
        try await archive.setPinned(id: older.id.uuidString, isPinned: false)
        let before = try readRecord(root: directory, id: older.id)
        try #require(before.appPayload?["isPinned"] == .bool(false))

        try await archive.applyProjection(older, replay: true)

        let after = try readRecord(root: directory, id: older.id)
        #expect(after.appPayload?["isPinned"] == .bool(false))
    }

    @Test(arguments: [false, true])
    func staleProjectionKeepsTextAndBothToolListsAndAttachmentValues(replay: Bool) async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        var stored = conversation()
        let keptAttachment = ChatAttachmentRef(kind: .text, name: "later.txt", characterCount: 5, addedAt: finishedAt)
        let addedAttachment = ChatAttachmentRef(kind: .text, name: "earlier.txt", characterCount: 7, addedAt: finishedAt)
        stored.messages[1].attachments = [keptAttachment]
        try await archive.syncConversation(stored)
        let answerID = stored.messages[1].id.uuidString
        // This is the same terminal update used by completeTurn, with a
        // deterministic date so codec precision is not the subject of this test.
        _ = try await archive.checkpoint(
            conversationID: stored.id.uuidString, turnID: answerID,
            update: .completed(text: stored.messages[1].content, at: finishedAt)
        )
        let before = try readRecord(root: directory, id: stored.id)
        let beforeAnswer = try #require(before.turns.first { $0.id == answerID })
        try #require(beforeAnswer.request?.status == .completed)
        let beforeAttachment = try #require(beforeAnswer.attachments.first)

        var older = stored
        older.messages[1].content = String(repeating: "a", count: 800)
        older.messages[1].toolRecords = [earlier, later, earlier]
        var staleAttachment = keptAttachment
        staleAttachment.name = "stale-name.txt"
        older.messages[1].attachments = [staleAttachment, addedAttachment]
        try await archive.applyProjection(older, replay: replay)

        let after = try readRecord(root: directory, id: stored.id)
        let answer = try #require(after.turns.first { $0.id == answerID })
        #expect(answer.text == beforeAnswer.text)
        #expect(answer.request == beforeAnswer.request)
        let records = try #require(ChatArchive.decodeValue(
            answer.appPayload?["toolRecords"] ?? .null, as: [ChatToolRecord].self
        ))
        #expect(records == [later, earlier], "keep stored values and append distinct missing records once")
        #expect(answer.attachments.first { $0.id == beforeAttachment.id } == beforeAttachment)
        #expect(answer.attachments.contains { $0.id == addedAttachment.id.uuidString })
    }

    @Test func aShorterCurrentToolListStillAddsItsDistinctRecords() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let secondKept = ChatToolRecord(kind: .skill, summary: "Saved instruction")
        var stored = conversation()
        stored.messages[1].toolRecords = [later, secondKept]
        try await archive.syncConversation(stored)
        let answerID = stored.messages[1].id.uuidString
        _ = try await archive.completeTurn(
            conversationID: stored.id.uuidString, turnID: answerID, text: stored.messages[1].content
        )
        var live = stored
        live.messages[1].toolRecords = [earlier]

        try await archive.syncConversation(live)

        let record = try readRecord(root: directory, id: stored.id)
        let answer = try #require(record.turns.first { $0.id == answerID })
        let records = try #require(ChatArchive.decodeValue(
            answer.appPayload?["toolRecords"] ?? .null, as: [ChatToolRecord].self
        ))
        #expect(records == [later, secondKept, earlier])
    }

    @Test(arguments: [JSONValue.null, .string("malformed"), .array([.string("not a record")])])
    func replayLeavesMalformedStoredToolPayloadUntouched(malformed: JSONValue) {
        var stored = ChatArchive.turn(for: QuickMessage(role: .assistant, content: "answer", toolRecords: [later]))
        stored.appPayload?["toolRecords"] = malformed
        let live = ChatArchive.turn(for: QuickMessage(role: .assistant, content: "answer", toolRecords: [earlier]))

        let merged = ChatArchive.mergeReplay(liveTurn: live, into: stored)

        #expect(merged.appPayload?["toolRecords"] == malformed)
    }

    @Test func replayLeavesValidStoredToolsWhenIncomingPayloadIsMalformed() {
        let stored = ChatArchive.turn(for: QuickMessage(role: .assistant, content: "answer", toolRecords: [later]))
        var live = ChatArchive.turn(for: QuickMessage(role: .assistant, content: "answer", toolRecords: [earlier]))
        live.appPayload?["toolRecords"] = .string("malformed")

        let merged = ChatArchive.mergeReplay(liveTurn: live, into: stored)

        #expect(merged.appPayload?["toolRecords"] == stored.appPayload?["toolRecords"])
    }

    @Test func replayFillsAnAbsentToolPayload() throws {
        let stored = ChatArchive.turn(for: QuickMessage(role: .assistant, content: "answer"))
        let live = ChatArchive.turn(for: QuickMessage(role: .assistant, content: "answer", toolRecords: [earlier]))

        let merged = ChatArchive.mergeReplay(liveTurn: live, into: stored)

        let records = try #require(ChatArchive.decodeValue(
            merged.appPayload?["toolRecords"] ?? .null, as: [ChatToolRecord].self
        ))
        #expect(records == [earlier])
    }
}
