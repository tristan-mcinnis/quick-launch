import Foundation
import Testing
@testable import HouseChatCore

@Suite("Conversation archive")
struct ConversationArchiveTests {
    @Test("Saves, loads, and writes owner-only files")
    func savesAndLoads() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let root = temp.appending("chat")
        let archive = try ConversationArchive(root: root)
        let record = Fixtures.conversation()

        let summary = try await archive.save(record)
        #expect(summary.id == record.id)
        #expect(summary.turnCount == 2)

        let loaded = try await archive.load(id: record.id)
        #expect(loaded == record)
        #expect(archive.contains(record.id))

        let file = archive.fileURL(for: record.id)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(AtomicFile.permissions(of: file) == 0o600)
        #expect(AtomicFile.permissions(of: root) == 0o700)
        // The file is inside the root.
        #expect(file.path.hasPrefix(root.path + "/"))
    }

    @Test("A missing file and a damaged file are different errors")
    func missingVersusCorrupt() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let archive = try ConversationArchive(root: temp.appending("chat"))

        await #expect(throws: ConversationArchiveError.missing(id: "nope")) {
            try await archive.load(id: "nope")
        }

        let good = Fixtures.conversation(id: "broken")
        try await archive.save(good)
        let file = archive.fileURL(for: "broken")
        try Data("this is not json".utf8).write(to: file)

        await #expect(throws: ConversationArchiveError.corrupt(id: "broken", detail: "not a conversation envelope")) {
            try await archive.load(id: "broken")
        }
    }

    @Test("Listing reports damaged files instead of hiding them, newest first")
    func listReportsIssues() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let archive = try ConversationArchive(root: temp.appending("chat"))

        var older = Fixtures.conversation(id: "older")
        older.updatedAt = Date(timeIntervalSince1970: 1_000)
        var newer = Fixtures.conversation(id: "newer")
        newer.updatedAt = Date(timeIntervalSince1970: 2_000)
        try await archive.save(older)
        try await archive.save(newer)

        let broken = Fixtures.conversation(id: "broken")
        try await archive.save(broken)
        try Data("{".utf8).write(to: archive.fileURL(for: "broken"))

        let summaries = try await archive.list()
        #expect(summaries.count == 3)
        #expect(summaries.map(\.id) == ["newer", "older", "broken"])
        #expect(summaries[0].issue == nil)
        #expect(summaries[2].issue == .corrupt)
    }

    @Test("A newer schema version is refused, and listed as such")
    func refusesNewerSchema() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let root = temp.appending("chat")
        let archive = try ConversationArchive(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = Fixtures.conversation(id: "future")
        let envelope = ConversationEnvelope(schemaVersion: 99, conversation: record)
        let data = try HouseChatCoding.makeEncoder(prettyPrinted: false).encode(envelope)
        try data.write(to: archive.fileURL(for: "future"))

        await #expect(throws: ConversationArchiveError.unsupportedSchema(id: "future", version: 99)) {
            try await archive.load(id: "future")
        }
        let summaries = try await archive.list()
        #expect(summaries.first?.issue == .unsupportedSchema)
    }

    @Test("A file whose conversation ID does not match its name is corrupt")
    func refusesMismatchedID() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let root = temp.appending("chat")
        let archive = try ConversationArchive(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = Fixtures.conversation(id: "wrong-id")
        let envelope = ConversationEnvelope(conversation: record)
        let data = try HouseChatCoding.makeEncoder(prettyPrinted: false).encode(envelope)
        try data.write(to: archive.fileURL(for: "asked-for"))

        await #expect(throws: ConversationArchiveError.corrupt(id: "asked-for", detail: "conversation ID does not match the file")) {
            try await archive.load(id: "asked-for")
        }
    }

    @Test("A JSON file that is not a conversation envelope is corrupt")
    func refusesUnexpectedFormat() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let root = temp.appending("chat")
        let archive = try ConversationArchive(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let envelope = ConversationEnvelope(format: "some-other-app", conversation: Fixtures.conversation(id: "x"))
        let data = try HouseChatCoding.makeEncoder(prettyPrinted: false).encode(envelope)
        try data.write(to: archive.fileURL(for: "x"))

        await #expect(throws: ConversationArchiveError.corrupt(id: "x", detail: "unexpected format some-other-app")) {
            try await archive.load(id: "x")
        }
    }

    @Test("An unreadable root throws; it is never reported as an empty archive")
    func unreadableRootThrows() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let root = temp.appending("chat")
        let archive = try ConversationArchive(root: root)
        try await archive.save(Fixtures.conversation(id: "one"))
        // An archive with nothing saved yet is empty, not unreadable.
        let empty = try ConversationArchive(root: temp.appending("nothing"))
        #expect(try await empty.list().isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        await #expect(throws: ConversationArchiveError.rootUnreadable(path: root.path)) {
            try await archive.list()
        }
    }

    @Test("Saving twice replaces the file; saveIfAbsent does not")
    func saveIfAbsentIsIdempotent() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let archive = try ConversationArchive(root: temp.appending("chat"))
        var record = Fixtures.conversation(id: "once")

        #expect(try await archive.saveIfAbsent(record) == true)
        #expect(try await archive.saveIfAbsent(record) == false)

        record.title = "Renamed"
        #expect(try await archive.saveIfAbsent(record) == false)
        #expect(try await archive.load(id: "once").title == "Revenue")

        try await archive.save(record)
        #expect(try await archive.load(id: "once").title == "Renamed")
    }

    @Test("Delete removes one file and is an error when it is gone")
    func delete() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let archive = try ConversationArchive(root: temp.appending("chat"))
        try await archive.save(Fixtures.conversation(id: "gone"))

        try await archive.delete(id: "gone")
        #expect(archive.contains("gone") == false)
        await #expect(throws: ConversationArchiveError.missing(id: "gone")) {
            try await archive.delete(id: "gone")
        }
    }

    @Test("Export returns the stored envelope; exportAll bundles the readable ones")
    func export() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let archive = try ConversationArchive(root: temp.appending("chat"))
        try await archive.save(Fixtures.conversation(id: "one"))
        try await archive.save(Fixtures.conversation(id: "two"))

        let one = try await archive.export(id: "one")
        let envelope = try HouseChatCoding.makeDecoder().decode(ConversationEnvelope.self, from: one)
        #expect(envelope.conversation.id == "one")

        let all = try await archive.exportAll()
        let bundle = try HouseChatCoding.makeDecoder().decode(ConversationBundle.self, from: all)
        #expect(bundle.conversations.map(\.id).sorted() == ["one", "two"])
        #expect(bundle.format == "house-chat-bundle")
    }

    @Test("Saving a conversation newer than this build is refused, not written")
    func saveRefusesNewerConversationVersion() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let archive = try ConversationArchive(root: temp.appending("chat"))
        var record = Fixtures.conversation(id: "future")
        record.schemaVersion = HouseChatCoding.schemaVersion + 1

        await #expect(throws: ConversationArchiveError.unsupportedSchema(
            id: "future",
            version: HouseChatCoding.schemaVersion + 1
        )) {
            try await archive.save(record)
        }
        #expect(archive.contains("future") == false)
        #expect(try await archive.list().isEmpty)
    }

    @Test("exportAll throws rather than silently omitting a file list vouched for")
    func exportAllFailsClosedOnALoadFailure() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let root = temp.appending("chat")
        let archive = try ConversationArchive(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // list() reports this record under its own id ("mismatched"); load(that
        // id) looks for a different file and cannot find it. The old `try?`
        // swallowed it and exported a bundle quietly short a chat.
        let envelope = ConversationEnvelope(conversation: Fixtures.conversation(id: "mismatched"))
        let data = try HouseChatCoding.makeEncoder(prettyPrinted: false).encode(envelope)
        try data.write(to: archive.fileURL(for: "asked-for"))

        let summaries = try await archive.list()
        #expect(summaries.map(\.id) == ["mismatched"])
        #expect(summaries.first?.issue == nil)

        await #expect(throws: ConversationArchiveError.missing(id: "mismatched")) {
            try await archive.exportAll()
        }
    }

    @Test("IDs that look like paths stay inside the root")
    func pathLikeIDs() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let root = temp.appending("chat")
        let archive = try ConversationArchive(root: root)

        for id in ["../escape", "a/b", "..", "/absolute", "weird:name"] {
            try await archive.save(Fixtures.conversation(id: id))
            let file = archive.fileURL(for: id)
            #expect(file.path.hasPrefix(root.path + "/"), "\(id) -> \(file.path)")
            // A slug may begin with dots; what matters is the real parent.
            #expect(
                file.standardizedFileURL.deletingLastPathComponent().path
                    == root.standardizedFileURL.path,
                "\(id) -> \(file.path)"
            )
            #expect(try await archive.load(id: id).id == id)
        }
    }

    @Test("An empty or NUL-bearing ID is refused")
    func invalidIDs() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let archive = try ConversationArchive(root: temp.appending("chat"))
        await #expect(throws: ConversationArchiveError.invalidID("")) {
            try await archive.save(Fixtures.conversation(id: ""))
        }
        await #expect(throws: ConversationArchiveError.invalidID("a\u{0}b")) {
            try await archive.save(Fixtures.conversation(id: "a\u{0}b"))
        }
    }

    @Test("Two saves leave no temporary files behind")
    func noTempFiles() async throws {
        let temp = try TempDirectory(prefix: "conversations")
        let root = temp.appending("chat")
        let archive = try ConversationArchive(root: root)
        try await archive.save(Fixtures.conversation(id: "one"))
        try await archive.save(Fixtures.conversation(id: "one"))

        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(contents.allSatisfy { !$0.hasPrefix(".house-chat-") })
        #expect(contents.count == 1)
    }
}
