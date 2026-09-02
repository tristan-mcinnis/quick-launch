import Testing
import Foundation
@testable import QuickLaunch

@Suite("JSON file store")
struct JSONFileStoreTests {
    private struct Note: Codable, Equatable, Sendable {
        var title: String
        var count: Int
    }

    private func freshFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-json-store-tests-\(UUID().uuidString)")
    }

    @Test func roundTripCreatesFolderAndKeepsFileOwnerOnly() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JSONFileStore<[Note]>(fileURL: folder.appendingPathComponent("nested/notes.json"))
        #expect(store.load() == nil)
        #expect(!store.exists)

        store.save([Note(title: "a", count: 1)])
        store.save([Note(title: "a", count: 1), Note(title: "b", count: 2)])
        store.flush()

        #expect(store.exists)
        #expect(store.load() == [Note(title: "a", count: 1), Note(title: "b", count: 2)])
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func bareFormatIsByteCompatibleWithPlainJSONEncoder() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JSONFileStore<[Note]>(fileURL: folder.appendingPathComponent("notes.json"))
        let value = [Note(title: "x", count: 3)]
        try store.saveNow(value)
        // Same shape a plain `JSONEncoder` writes: a bare array, no envelope.
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? NSArray
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSArray
        #expect(written == plain)
        #expect(written?.count == 1)
    }

    @Test func envelopeIsWrittenAndLegacyBareFilesStillDecode() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("notes.json")
        // A file written before the envelope existed.
        try JSONEncoder().encode([Note(title: "legacy", count: 0)]).write(to: url)

        let store = JSONFileStore<[Note]>(fileURL: url, schemaVersion: 2)
        #expect(store.load() == [Note(title: "legacy", count: 0)])

        try store.saveNow([Note(title: "new", count: 1)])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == 2)
        #expect(store.load() == [Note(title: "new", count: 1)])

        // A build without the envelope still reads the payload.
        let bare = JSONFileStore<[Note]>(fileURL: url)
        #expect(bare.load() == [Note(title: "new", count: 1)])
    }

    @Test func newerSchemaVersionIsRefusedInsteadOfMisread() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("notes.json")
        try JSONFileStore<[Note]>(fileURL: url, schemaVersion: 5).saveNow([Note(title: "future", count: 9)])

        let older = JSONFileStore<[Note]>(fileURL: url, schemaVersion: 1)
        #expect(older.load() == nil)
        #expect(throws: JSONFileStore<[Note]>.LoadError.self) { try older.loadOrThrow() }
    }

    @Test func atomicWriteLeavesNoTemporaryFilesAndCorruptFilesLoadAsNil() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JSONFileStore<Note>(fileURL: folder.appendingPathComponent("note.json"))
        for index in 0..<50 { store.save(Note(title: "n", count: index)) }
        store.flush()
        let listing = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(listing == ["note.json"])
        #expect(store.load()?.count == 49)

        try Data("{not json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        #expect(throws: (any Error).self) { try store.loadOrThrow() }
    }

    @Test func deleteRemovesTheFileAndMissingFilesAreNotErrors() throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = JSONFileStore<Note>(fileURL: folder.appendingPathComponent("note.json"))
        store.delete()
        store.flush()
        try store.saveNow(Note(title: "t", count: 1))
        store.delete()
        store.flush()
        #expect(!store.exists)
        #expect(throws: (any Error).self) { try store.loadOrThrow() }
        do {
            _ = try store.loadOrThrow()
        } catch {
            #expect(AppLog.isMissingFile(error))
        }
    }

    @Test @MainActor func legacyClipboardFilesStillLoad() async throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Shape written by builds before pins existed: no `pinned` key.
        let clipboard = folder.appendingPathComponent("clipboard-history.json")
        try Data(#"[{"id":"abc","value":"hello","capturedAt":0}]"#.utf8).write(to: clipboard)
        let store = ClipboardHistoryStore(fileURL: clipboard)
        #expect(store.entries.map(\.value) == ["hello"])
    }
}
