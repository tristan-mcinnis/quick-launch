import Foundation
import Testing
@testable import HouseChatCore

@Suite("Commit coordinator")
struct ChatCommitCoordinatorTests {
    @Test("A commit writes the artifacts and saves the turn with their refs")
    func commitsAtomically() async throws {
        let temp = try TempDirectory(prefix: "commit")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let conversations = try ConversationArchive(root: temp.appending("conversations"))
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)

        let original = Data("%PDF-1.7 bytes with private content".utf8)
        let text = Data(Fixtures.english.utf8)
        let attachment = AttachmentRecord(
            id: "a1",
            kind: .pdf,
            name: "report.pdf",
            contentHash: SHA256Digest.hex(original),
            extractorVersion: 1
        )
        let turn = TurnRecord(role: .user, text: "read this", attachments: [attachment])
        let conversation = ConversationRecord(id: "c1", surface: .rtiCopilot, turns: [turn])

        let commit = try await coordinator.commit(
            conversation: conversation,
            turnIndex: 0,
            artifacts: [
                PendingArtifact(role: .original, data: original, fileExtension: "pdf", attachmentIndex: 0),
                PendingArtifact(role: .extractedText, data: text, fileExtension: "txt", attachmentIndex: 0),
            ]
        )

        #expect(commit.createdDigests.count == 2)
        let saved = try await conversations.load(id: "c1")
        let archived = try #require(saved.turns[0].attachments[0].artifacts)
        #expect(archived.original?.sha256 == SHA256Digest.hex(original))
        #expect(archived.extractedText?.sha256 == SHA256Digest.hex(text))
        // The original bytes are kept exactly, never silently redacted.
        let originalRef = try #require(archived.original)
        #expect(try await attachments.read(originalRef) == original)

        #expect(try await coordinator.owners(of: SHA256Digest.hex(original)) == ["c1"])
    }

    @Test("A failed save retains the bytes this commit wrote, and reports them")
    func failedCommitRetainsCreatedBytes() async throws {
        let temp = try TempDirectory(prefix: "commit")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let conversationRoot = temp.appending("conversations")
        try FileManager.default.createDirectory(at: conversationRoot, withIntermediateDirectories: true)
        let conversations = try ConversationArchive(root: conversationRoot)
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)

        // A pre-existing artifact that no failure may touch.
        let shared = Data("already archived".utf8)
        let existing = try await attachments.store(shared, kind: .original)
        let fresh = Data("new in this commit".utf8)
        let freshRef = ArtifactRef(kind: .extractedText, sha256: SHA256Digest.hex(fresh), byteCount: fresh.count)

        let attachment = AttachmentRecord(id: "a1", kind: .pdf, name: "report.pdf")
        let turn = TurnRecord(role: .user, text: "read this", attachments: [attachment])
        let conversation = ConversationRecord(id: "c1", turns: [turn])

        // Make the conversation root unwritable so the save fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: conversationRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: conversationRoot.path)
        }

        var thrown: ChatCommitError?
        do {
            _ = try await coordinator.commit(
                conversation: conversation,
                turnIndex: 0,
                artifacts: [
                    PendingArtifact(role: .original, data: shared, attachmentIndex: 0),
                    PendingArtifact(role: .extractedText, data: fresh, attachmentIndex: 0),
                ]
            )
            Issue.record("Expected the commit to fail")
        } catch let error as ChatCommitError {
            thrown = error
        }

        guard case .commitFailed(let id, let turnIndex, _, let orphans)? = thrown else {
            Issue.record("Expected commitFailed, got \(String(describing: thrown))")
            return
        }
        #expect(id == "c1")
        #expect(turnIndex == 0)
        #expect(orphans.map(\.sha256) == [freshRef.sha256], "the orphan list must name what was retained")

        // Nothing is deleted on failure: the created bytes are still there, and
        // so is the pre-existing artifact.
        #expect(await attachments.contains(freshRef), "a failed commit deleted bytes")
        #expect(try await attachments.read(freshRef) == fresh)
        #expect(await attachments.contains(existing))

        // Nothing was saved.
        #expect(conversations.contains("c1") == false)

        // Cleanup is explicit, later, and reference-checked.
        let removed = try await coordinator.removeArtifactsIfUnreferenced(orphans)
        #expect(removed.map(\.sha256) == [freshRef.sha256])
        #expect(await attachments.contains(freshRef) == false)
        #expect(await attachments.contains(existing), "cleanup must not touch a referenced artifact")
    }

    @Test("The same bytes under another kind are not mistaken for a pre-existing file")
    func sameBytesDifferentKindAreCreated() async throws {
        let temp = try TempDirectory(prefix: "commit")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let conversationRoot = temp.appending("conversations")
        try FileManager.default.createDirectory(at: conversationRoot, withIntermediateDirectories: true)
        let conversations = try ConversationArchive(root: conversationRoot)
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)

        // The bytes already exist on disk, but only as `.original`.
        let shared = Data("same bytes, another kind".utf8)
        _ = try await attachments.store(shared, kind: .original)

        let attachment = AttachmentRecord(id: "a1", kind: .text, name: "notes.txt")
        let turn = TurnRecord(role: .user, text: "hi", attachments: [attachment])
        let conversation = ConversationRecord(id: "c1", turns: [turn])

        // Make the conversation root unwritable so the save fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: conversationRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: conversationRoot.path)
        }

        var thrown: ChatCommitError?
        do {
            _ = try await coordinator.commit(
                conversation: conversation,
                turnIndex: 0,
                artifacts: [
                    PendingArtifact(role: .original, data: shared, attachmentIndex: 0),
                    PendingArtifact(role: .extractedText, data: shared, fileExtension: "txt", attachmentIndex: 0),
                ]
            )
            Issue.record("Expected the commit to fail")
        } catch let error as ChatCommitError {
            thrown = error
        }

        guard case .commitFailed(_, _, _, let orphans)? = thrown else {
            Issue.record("Expected commitFailed, got \(String(describing: thrown))")
            return
        }
        // The `.extractedText` file is new. A digest-only pre-existing set
        // would hide it, so the caller's cleanup would never be offered it.
        #expect(orphans.map(\.kind) == [.extractedText], "only the newly created kind is an orphan")
        #expect(await attachments.contains(ArtifactRef(
            kind: .extractedText,
            sha256: SHA256Digest.hex(shared),
            byteCount: shared.count
        )))
    }

    @Test("A commit refuses a turn or attachment that is not there")
    func refusesBadIndices() async throws {
        let temp = try TempDirectory(prefix: "commit")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let conversations = try ConversationArchive(root: temp.appending("conversations"))
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)

        let conversation = ConversationRecord(id: "c1", turns: [TurnRecord(role: .user, text: "hi")])
        await #expect(throws: ChatCommitError.noSuchTurn(conversationID: "c1", turnIndex: 4)) {
            try await coordinator.commit(conversation: conversation, turnIndex: 4, artifacts: [])
        }
        await #expect(throws: ChatCommitError.noSuchAttachment(turnIndex: 0, attachmentIndex: 2)) {
            try await coordinator.commit(
                conversation: conversation,
                turnIndex: 0,
                artifacts: [PendingArtifact(role: .original, data: Data("x".utf8), attachmentIndex: 2)]
            )
        }
    }

    @Test("Artifacts are removed only when no other conversation references them")
    func deletionReferenceChecks() async throws {
        let temp = try TempDirectory(prefix: "commit")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let conversations = try ConversationArchive(root: temp.appending("conversations"))
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)

        let data = Data("shared by two chats".utf8)
        let digest = SHA256Digest.hex(data)
        for id in ["c1", "c2"] {
            let attachment = AttachmentRecord(
                id: "a-\(id)",
                kind: .text,
                name: "notes.txt",
                contentHash: digest
            )
            let conversation = ConversationRecord(id: id, turns: [TurnRecord(role: .user, text: "hi", attachments: [attachment])])
            try await coordinator.commit(
                conversation: conversation,
                turnIndex: 0,
                artifacts: [PendingArtifact(role: .original, data: data, fileExtension: "txt", attachmentIndex: 0)]
            )
        }

        #expect(try await coordinator.owners(of: digest) == ["c1", "c2"])
        let ref = ArtifactRef(kind: .original, sha256: digest, byteCount: data.count)
        #expect(try await coordinator.removeArtifactsIfUnreferenced([ref]).isEmpty)
        #expect(await attachments.contains(ref))

        // Delete one chat: the other chat still owns the bytes.
        try await conversations.delete(id: "c1")
        #expect(try await coordinator.owners(of: digest) == ["c2"])
        #expect(try await coordinator.removeArtifactsIfUnreferenced([ref]).isEmpty)

        // Delete the last one: now the artifact can go.
        try await conversations.delete(id: "c2")
        #expect(try await coordinator.referencedDigests().isEmpty)
        #expect(try await coordinator.removeArtifactsIfUnreferenced([ref]).count == 1)
        #expect(await attachments.contains(ref) == false)
    }
}

@Suite("Root integrity")
struct RootIntegrityTests {
    @Test("The file system root is refused as an archive root")
    func refusesFileSystemRoot() throws {
        #expect(throws: AttachmentArchiveError.invalidRoot("/")) {
            try AttachmentArchive(root: URL(fileURLWithPath: "/"))
        }
        #expect(throws: ConversationArchiveError.invalidRoot("/")) {
            try ConversationArchive(root: URL(fileURLWithPath: "/"))
        }
    }

    @Test("A root reached through a symlink writes only inside the resolved directory")
    func symlinkedRoot() async throws {
        let temp = try TempDirectory(prefix: "root-symlink")
        let real = temp.appending("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = temp.appending("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let root = link.appendingPathComponent("archive")
        let archive = try AttachmentArchive(root: root)
        let ref = try await archive.store(Data("payload".utf8), kind: .original)
        let url = AttachmentArchive.fileURL(root: root, kind: ref.kind, sha256: ref.sha256)

        // The path stays under the given root…
        #expect(url.path.hasPrefix(root.path))
        // …and the bytes land in the resolved directory, nowhere else.
        let resolved = real.appendingPathComponent("archive/original/\(ref.sha256.prefix(2))/\(ref.sha256)")
        #expect(FileManager.default.fileExists(atPath: resolved.path))
        #expect(FileManager.default.fileExists(atPath: temp.appending("original").path) == false)
        #expect(AtomicFile.permissions(of: resolved) == 0o600)
    }

    @Test("A traversal ID stays under the conversation root and does not shadow a sibling")
    func traversalIDStaysInside() async throws {
        let temp = try TempDirectory(prefix: "root-traversal")
        let root = temp.appending("conversations")
        let archive = try ConversationArchive(root: root)
        let sibling = temp.appending("sibling.json")
        try Data("not ours".utf8).write(to: sibling)

        let id = "../sibling"
        try await archive.save(Fixtures.conversation(id: id))
        let file = archive.fileURL(for: id)
        #expect(file.path.hasPrefix(root.path + "/"))
        #expect(
            file.standardizedFileURL.deletingLastPathComponent().path
                == root.standardizedFileURL.path
        )
        #expect(try Data(contentsOf: sibling) == Data("not ours".utf8))
        #expect(try await archive.load(id: id).id == id)
    }
}
