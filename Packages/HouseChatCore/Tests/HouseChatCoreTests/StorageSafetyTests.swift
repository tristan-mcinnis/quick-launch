import Foundation
import Testing
@testable import HouseChatCore

/// Counts overlapping holders of a critical section.
private final class HolderCounter: @unchecked Sendable {
    /// `NSLock` guards `value` and `peakValue`.
    private let lock = NSLock()
    private var value = 0
    private var peakValue = 0

    func enter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        peakValue = max(peakValue, value)
        return value
    }

    func leave() {
        lock.lock()
        defer { lock.unlock() }
        value -= 1
    }

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakValue
    }
}

/// The storage-safety contract: a failed commit never deletes bytes, and a
/// commit never interleaves with a deletion.
@Suite("Storage safety")
struct StorageSafetyTests {
    private func makeStores(_ prefix: String) throws -> (AttachmentArchive, ConversationArchive, URL) {
        let temp = try TempDirectory(prefix: prefix)
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let chats = try ConversationArchive(root: temp.appending("chats"))
        return (attachments, chats, temp.url)
    }

    @Test("A failed commit cannot delete bytes another commit already holds")
    func sameBytesTwoCommitsCannotLoseTheBlob() async throws {
        let temp = try TempDirectory(prefix: "ab-race")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))

        // A: a coordinator whose conversation store cannot be written.
        let failingConversationRoot = temp.appending("chats-failing")
        try FileManager.default.createDirectory(at: failingConversationRoot, withIntermediateDirectories: true)
        let failingConversations = try ConversationArchive(root: failingConversationRoot)
        let failing = ChatCommitCoordinator(attachments: attachments, conversations: failingConversations)

        // B: a healthy coordinator over its own conversation store.
        let chats = try ConversationArchive(root: temp.appending("chats"))
        let healthy = ChatCommitCoordinator(attachments: attachments, conversations: chats)

        let data = Data("the same bytes for both chats".utf8)
        let digest = SHA256Digest.hex(data)

        // B stores the bytes and receives a ref; B's conversation is not saved yet.
        let bRef = try await attachments.store(data, kind: .original, fileExtension: "txt")
        #expect(bRef.sha256 == digest)

        // A writes the same bytes (idempotent, no new file) and fails to save.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: failingConversationRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failingConversationRoot.path)
        }
        let aAttachment = AttachmentRecord(id: "a1", kind: .text, name: "n.txt", contentHash: digest)
        let aConversation = ConversationRecord(
            id: "a-fails",
            turns: [TurnRecord(role: .user, text: "hi", attachments: [aAttachment])]
        )
        await #expect(throws: ChatCommitError.self) {
            try await failing.commit(
                conversation: aConversation,
                turnIndex: 0,
                artifacts: [PendingArtifact(role: .original, data: data, fileExtension: "txt", attachmentIndex: 0)]
            )
        }

        // B's save now succeeds. The bytes it points at must still be there.
        let bAttachment = AttachmentRecord(id: "b1", kind: .text, name: "n.txt", contentHash: digest)
        let bConversation = ConversationRecord(
            id: "b-saves",
            turns: [TurnRecord(role: .user, text: "hi", attachments: [bAttachment])]
        )
        _ = try await healthy.commit(
            conversation: bConversation,
            turnIndex: 0,
            artifacts: [PendingArtifact(role: .original, data: data, fileExtension: "txt", attachmentIndex: 0)]
        )

        let saved = try await chats.load(id: "b-saves")
        let ref = try #require(saved.turns[0].attachments[0].artifacts?.original)
        #expect(ref.sha256 == digest)
        #expect(try await attachments.read(ref) == data, "B points at bytes A's failure removed")
        #expect(await attachments.contains(bRef))
    }

    @Test("The root lock serializes critical sections across lock values")
    func rootLockSerializes() async throws {
        let temp = try TempDirectory(prefix: "root-lock")
        let root = temp.appending("archive")
        let first = try ArchiveRootLock(root: root)
        let second = try ArchiveRootLock(root: root)
        #expect(first.lockFileURL == second.lockFileURL)

        let holders = HolderCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let lock = index.isMultiple(of: 2) ? first : second
                group.addTask {
                    try await lock.withLock {
                        let current = holders.enter()
                        try? await Task.sleep(for: .milliseconds(2))
                        holders.leave()
                        #expect(current == 1, "two critical sections overlapped")
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(holders.peak == 1)
        #expect(AtomicFile.isRegularFile(first.lockFileURL))
        #expect(AtomicFile.permissions(of: first.lockFileURL) == 0o600)
        // The lock file is inside the root, which stays owner-only.
        #expect(AtomicFile.permissions(of: root) == 0o700)
    }

    @Test("A request snapshot is submitted through the commit and matches the receipt")
    func requestSnapshotTravelsWithTheCommit() async throws {
        let temp = try TempDirectory(prefix: "snapshot-commit")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let chats = try ConversationArchive(root: temp.appending("chats"))
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: chats)

        let requestJSON = Data(#"{"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        // Precomputed before the commit: the receipt needs the hash, and the
        // commit writes the bytes it names.
        let snapshot = AttachmentSnapshotRef(snapshotData: requestJSON, kind: "requestSnapshot")
        #expect(snapshot.snapshotHash == SHA256Digest.hex(requestJSON))
        #expect(snapshot.byteCount == requestJSON.count)

        let body = Data("the attached bytes".utf8)
        let attachment = AttachmentRecord(id: "a1", kind: .text, name: "n.txt")
        let receipt = RequestReceipt(status: .completed, attachmentRefs: [snapshot])
        let turn = TurnRecord(role: .user, text: "hi", attachments: [attachment], request: receipt)
        let conversation = ConversationRecord(id: "c1", turns: [turn])

        let commit = try await coordinator.commit(
            conversation: conversation,
            turnIndex: 0,
            artifacts: [
                PendingArtifact(role: .original, data: body, fileExtension: "txt", attachmentIndex: 0),
                PendingArtifact(role: .requestSnapshot, data: requestJSON, fileExtension: "json"),
            ]
        )

        let snapshotRef = try #require(commit.artifacts.first { $0.kind == .requestSnapshot })
        #expect(snapshotRef.sha256 == snapshot.snapshotHash)
        #expect(try await attachments.read(snapshotRef) == requestJSON)

        let saved = try await chats.load(id: "c1")
        #expect(saved.turns[0].request?.attachmentRefs.first?.snapshotHash == snapshotRef.sha256)
        // The snapshot belongs to the turn, not to the attached file.
        #expect(saved.turns[0].attachments[0].artifacts?.original?.sha256 == SHA256Digest.hex(body))
        #expect(saved.turns[0].attachments[0].artifacts?.extractedText == nil)

        // The receipt references it, so a deletion scan keeps it.
        #expect(try await coordinator.removeArtifactsIfUnreferenced([snapshotRef]).isEmpty)
        #expect(await attachments.contains(snapshotRef))

        // Submitting the same snapshot again writes nothing new.
        let again = try await coordinator.commit(
            conversation: ConversationRecord(
                id: "c2",
                turns: [TurnRecord(role: .user, text: "hi", request: receipt)]
            ),
            turnIndex: 0,
            artifacts: [PendingArtifact(role: .requestSnapshot, data: requestJSON, fileExtension: "json")]
        )
        #expect(again.artifacts.first?.sha256 == snapshotRef.sha256)
        #expect(again.createdDigests.isEmpty)
    }

    @Test("A request snapshot this commit wrote survives a failed save")
    func requestSnapshotRetainedOnFailure() async throws {
        let temp = try TempDirectory(prefix: "snapshot-failure")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let failingRoot = temp.appending("chats-failing")
        try FileManager.default.createDirectory(at: failingRoot, withIntermediateDirectories: true)
        let conversations = try ConversationArchive(root: failingRoot)
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)

        let requestJSON = Data(#"{"messages":[],"unique":"snapshot orphan"}"#.utf8)
        let ref = ArtifactRef(
            kind: .requestSnapshot,
            sha256: SHA256Digest.hex(requestJSON),
            byteCount: requestJSON.count
        )
        let conversation = ConversationRecord(id: "c1", turns: [TurnRecord(role: .user, text: "hi")])

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: failingRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: failingRoot.path)
        }

        var thrown: ChatCommitError?
        do {
            _ = try await coordinator.commit(
                conversation: conversation,
                turnIndex: 0,
                artifacts: [PendingArtifact(role: .requestSnapshot, data: requestJSON, fileExtension: "json")]
            )
            Issue.record("Expected the commit to fail")
        } catch let error as ChatCommitError {
            thrown = error
        }

        guard case .commitFailed(_, _, _, let orphans)? = thrown else {
            Issue.record("Expected commitFailed, got \(String(describing: thrown))")
            return
        }
        #expect(orphans.map(\.sha256) == [ref.sha256])
        #expect(await attachments.contains(ref), "a failed commit deleted the snapshot")
        #expect(try await attachments.read(ref) == requestJSON)
    }

    @Test("A request snapshot with an attachment index is refused")
    func snapshotIndexRefused() async throws {
        let temp = try TempDirectory(prefix: "snapshot-index")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let chats = try ConversationArchive(root: temp.appending("chats"))
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: chats)

        let attachment = AttachmentRecord(id: "a1", kind: .text, name: "n.txt")
        let conversation = ConversationRecord(
            id: "c1",
            turns: [TurnRecord(role: .user, text: "hi", attachments: [attachment])]
        )
        await #expect(throws: ChatCommitError.requestSnapshotCannotAttach(turnIndex: 0, attachmentIndex: 0)) {
            try await coordinator.commit(
                conversation: conversation,
                turnIndex: 0,
                artifacts: [PendingArtifact(role: .requestSnapshot, data: Data("{}".utf8), attachmentIndex: 0)]
            )
        }
        // Refused before anything was written.
        #expect(try await attachments.list().isEmpty)
        #expect(chats.contains("c1") == false)
    }

    @Test("A pristine nested root works on the first commit")
    func pristineNestedRoot() async throws {
        let temp = try TempDirectory(prefix: "nested-root")
        // None of these directories exist yet: no app asset root, no parent chain.
        let nested = temp.url
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("c", isDirectory: true)
        let assets = nested.appendingPathComponent("assets", isDirectory: true)
        let chats = nested.appendingPathComponent("chats", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: assets.path))
        #expect(!FileManager.default.fileExists(atPath: nested.path))

        let attachments = try AttachmentArchive(root: assets)
        let conversations = try ConversationArchive(root: chats)
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)

        let data = Data("first send into a fresh root".utf8)
        let attachment = AttachmentRecord(id: "a1", kind: .text, name: "n.txt")
        let conversation = ConversationRecord(
            id: "c1",
            turns: [TurnRecord(role: .user, text: "hi", attachments: [attachment])]
        )
        let commit = try await coordinator.commit(
            conversation: conversation,
            turnIndex: 0,
            artifacts: [PendingArtifact(role: .original, data: data, fileExtension: "txt", attachmentIndex: 0)]
        )

        let ref = try #require(commit.artifacts.first)
        #expect(try await attachments.read(ref) == data)
        #expect(try await conversations.load(id: "c1").id == "c1")
        #expect(AtomicFile.permissions(of: assets) == 0o700)
        #expect(AtomicFile.permissions(of: chats) == 0o700)
        // The lock file lives in the byte root.
        let lockFile = assets.appendingPathComponent(ArchiveRootLock.fileName)
        #expect(FileManager.default.fileExists(atPath: lockFile.path))
        #expect(AtomicFile.permissions(of: lockFile) == 0o600)
    }

    @Test("A symlink where the lock file belongs is refused")
    func lockRefusesSymlink() async throws {
        let temp = try TempDirectory(prefix: "root-lock-symlink")
        let root = temp.appending("archive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let elsewhere = temp.appending("elsewhere")
        try Data("not a lock".utf8).write(to: elsewhere)
        let lockFile = root.appendingPathComponent(ArchiveRootLock.fileName)
        try FileManager.default.createSymbolicLink(at: lockFile, withDestinationURL: elsewhere)

        let lock = try ArchiveRootLock(root: root)
        await #expect(throws: ArchiveRootLockError.self) {
            try await lock.withLock { 1 }
        }
    }

    @Test("Interleaved commits and deletions never lose a referenced blob")
    func gcDoesNotRaceCommits() async throws {
        let temp = try TempDirectory(prefix: "gc-race")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let conversations = try ConversationArchive(root: temp.appending("chats"))

        // Two coordinators, one shared lock value and one built from the same
        // default, both writing the same root.
        let first = ChatCommitCoordinator(attachments: attachments, conversations: conversations)
        let second = ChatCommitCoordinator(
            attachments: attachments,
            conversations: conversations,
            lock: try ArchiveRootLock(root: attachments.root)
        )

        let data = Data("contended bytes".utf8)
        let digest = SHA256Digest.hex(data)
        let ref = ArtifactRef(kind: .original, sha256: digest, byteCount: data.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                if index.isMultiple(of: 2) {
                    let coordinator = index.isMultiple(of: 4) ? first : second
                    group.addTask {
                        let attachment = AttachmentRecord(
                            id: "a\(index)",
                            kind: .text,
                            name: "n.txt",
                            contentHash: digest
                        )
                        let conversation = ConversationRecord(
                            id: "c\(index)",
                            turns: [TurnRecord(role: .user, text: "hi", attachments: [attachment])]
                        )
                        _ = try await coordinator.commit(
                            conversation: conversation,
                            turnIndex: 0,
                            artifacts: [PendingArtifact(
                                role: .original,
                                data: data,
                                fileExtension: "txt",
                                attachmentIndex: 0
                            )]
                        )
                    }
                } else {
                    let coordinator = index.isMultiple(of: 3) ? second : first
                    group.addTask {
                        _ = try await coordinator.removeArtifactsIfUnreferenced([ref])
                    }
                }
            }
            try await group.waitForAll()
        }

        // Every saved conversation still points at bytes that read.
        var saved = 0
        for summary in try await conversations.list() where summary.issue == nil {
            let conversation = try await conversations.load(id: summary.id)
            for attachment in conversation.attachments {
                let original = try #require(attachment.artifacts?.original)
                #expect(try await attachments.read(original) == data, "\(summary.id) lost its bytes")
                saved += 1
            }
        }
        #expect(saved == 12, "expected every commit to have saved")
        #expect(await attachments.contains(ref))
    }
}
