import Foundation

/// One artifact to write as part of a turn commit.
public struct PendingArtifact: Sendable, Equatable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        /// The exact bytes the user attached.
        case original
        /// The image as sent to a model.
        case normalizedImage
        /// The text the extractor produced.
        case extractedText
        /// The exact request body a provider received, for audit. Usually has
        /// no `attachmentIndex`: it belongs to the turn, not to one attached
        /// file. Submit it here rather than calling `AttachmentArchive.store`
        /// directly, so the snapshot is written under the same root lock as the
        /// conversation that references it and cannot race a deletion scan.
        case requestSnapshot
    }

    public var role: Role
    public var data: Data
    public var fileExtension: String?
    /// Index into the committed turn's attachments. Nil writes the artifact
    /// without attaching it to a record; the caller records its hash itself
    /// (for a request snapshot, with `AttachmentSnapshotRef(snapshotData:)`).
    ///
    /// A `.requestSnapshot` must be nil: the shared schema has no snapshot slot
    /// on an attachment record, so an index is refused rather than written into
    /// a role that does not own it.
    public var attachmentIndex: Int?

    public init(
        role: Role,
        data: Data,
        fileExtension: String? = nil,
        attachmentIndex: Int? = nil
    ) {
        self.role = role
        self.data = data
        self.fileExtension = fileExtension
        self.attachmentIndex = attachmentIndex
    }

    var artifactKind: ArtifactRef.Kind {
        switch role {
        case .original: .original
        case .normalizedImage: .normalizedImage
        case .extractedText: .extractedText
        case .requestSnapshot: .requestSnapshot
        }
    }
}

/// The result of an atomic commit.
public struct TurnCommit: Sendable {
    /// The conversation as saved, with the artifact refs attached.
    public var conversation: ConversationRecord
    public var turnIndex: Int
    public var artifacts: [ArtifactRef]
    /// Digests this commit wrote (files that did not exist before).
    public var createdDigests: [String]
    public var savedAt: Date

    public var createdArtifacts: [ArtifactRef] {
        artifacts.filter { createdDigests.contains($0.sha256) }
    }
}

/// Why a commit was refused.
public enum ChatCommitError: Error, Sendable, Equatable, LocalizedError {
    case noSuchTurn(conversationID: String, turnIndex: Int)
    case noSuchAttachment(turnIndex: Int, attachmentIndex: Int)
    /// A request snapshot was given an attachment index. The shared schema has
    /// no snapshot slot on `AttachmentArtifacts`, so this is refused rather
    /// than filed under the wrong role.
    case requestSnapshotCannotAttach(turnIndex: Int, attachmentIndex: Int)
    /// The commit failed. `retainedOrphans` are the artifacts this commit wrote
    /// (files that did not exist before). They are **retained, never deleted**,
    /// so another commit that already holds a ref to the same bytes cannot be
    /// left pointing at a missing file. Clean up with
    /// `removeArtifactsIfUnreferenced(_:)` when the caller wants to.
    case commitFailed(
        conversationID: String,
        turnIndex: Int,
        detail: String,
        retainedOrphans: [ArtifactRef]
    )
    /// A conversation file could not be read, so the set of artifacts still in
    /// use is unknown. Nothing is deleted on an unknown.
    case referenceScanIncomplete(id: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .noSuchTurn(let id, let index): "Conversation \(id) has no turn \(index)"
        case .noSuchAttachment(let turn, let attachment): "Turn \(turn) has no attachment \(attachment)"
        case .requestSnapshotCannotAttach(let turn, let attachment):
            "A request snapshot cannot be attached to attachment \(attachment) of turn \(turn)"
        case .commitFailed(let id, let turn, let detail, let orphans):
            "Commit of \(id) turn \(turn) failed: \(detail) (\(orphans.count) artifact(s) retained)"
        case .referenceScanIncomplete(let id, let detail):
            "Reference scan is incomplete (\(id): \(detail)); refusing to delete artifacts"
        }
    }
}

/// The transaction across the two archives.
///
/// A turn and the bytes it points at are one fact, so they commit together:
/// artifacts are written first, the conversation is saved second. **Every blob
/// goes through this call**, request snapshots included; a direct
/// `AttachmentArchive.store` in a send path would be outside the root lock and
/// could race a deletion scan. A failure
/// leaves **everything in place**: the bytes this commit wrote are retained and
/// reported in `ChatCommitError.commitFailed(retainedOrphans:)`, and nothing a
/// previous commit wrote is ever touched. There is no rollback by deletion,
/// because deleting a blob another commit already holds a ref to would lose
/// those bytes.
///
/// When a lock is configured (the default is an `ArchiveRootLock` over the
/// attachments root), the whole commit and the explicit deletion scan run under
/// it, so two coordinators, two chats, or two processes never interleave a
/// store with a delete. The lock is advisory: every writer of one root must go
/// through the same coordinator or the same lock.
///
/// The caller owns the decision to commit: it builds the conversation with the
/// turn already appended, lists the artifacts the turn needs, and calls
/// `commit`.
public actor ChatCommitCoordinator {
    public nonisolated let attachments: AttachmentArchive
    public nonisolated let conversations: ConversationArchive
    /// Serializes commits and deletions over one root, across coordinators and
    /// processes. Nil disables it: single-writer callers only.
    public nonisolated let lock: ArchiveRootLock?

    /// Defaults to a lock over the attachments root, the byte store every
    /// commit writes to.
    public init(attachments: AttachmentArchive, conversations: ConversationArchive) {
        self.attachments = attachments
        self.conversations = conversations
        self.lock = try? ArchiveRootLock(root: attachments.root)
    }

    /// Pass `lock: nil` only when this process is the sole writer of the root.
    public init(
        attachments: AttachmentArchive,
        conversations: ConversationArchive,
        lock: ArchiveRootLock?
    ) {
        self.attachments = attachments
        self.conversations = conversations
        self.lock = lock
    }

    /// Writes the artifacts and the conversation, under the root lock when one
    /// is configured.
    @discardableResult
    public func commit(
        conversation: ConversationRecord,
        turnIndex: Int,
        artifacts: [PendingArtifact],
        savedAt: Date = Date()
    ) async throws -> TurnCommit {
        guard let lock else {
            return try await performCommit(
                conversation: conversation,
                turnIndex: turnIndex,
                artifacts: artifacts,
                savedAt: savedAt
            )
        }
        return try await lock.withLock {
            try await self.performCommit(
                conversation: conversation,
                turnIndex: turnIndex,
                artifacts: artifacts,
                savedAt: savedAt
            )
        }
    }

    private func performCommit(
        conversation: ConversationRecord,
        turnIndex: Int,
        artifacts: [PendingArtifact],
        savedAt: Date
    ) async throws -> TurnCommit {
        guard conversation.turns.indices.contains(turnIndex) else {
            throw ChatCommitError.noSuchTurn(conversationID: conversation.id, turnIndex: turnIndex)
        }
        for artifact in artifacts {
            guard let index = artifact.attachmentIndex else { continue }
            guard conversation.turns[turnIndex].attachments.indices.contains(index) else {
                throw ChatCommitError.noSuchAttachment(turnIndex: turnIndex, attachmentIndex: index)
            }
            // A request snapshot has no slot on an attachment record; refuse an
            // index outright instead of filing it under a role it does not own.
            guard artifact.role != .requestSnapshot else {
                throw ChatCommitError.requestSnapshotCannotAttach(turnIndex: turnIndex, attachmentIndex: index)
            }
        }

        // Which files already exist, so only the files this commit wrote are
        // reported as orphans if it fails. Keyed by kind **and** digest: the
        // same bytes archived under another kind is not this kind's file, and
        // treating it as pre-existing would hide bytes this commit wrote from
        // the caller's `removeArtifactsIfUnreferenced` cleanup.
        var preexisting = Set<String>()
        for artifact in artifacts {
            let digest = SHA256Digest.hex(artifact.data)
            let probe = ArtifactRef(kind: artifact.artifactKind, sha256: digest, byteCount: artifact.data.count)
            if await attachments.contains(probe) {
                preexisting.insert(Self.artifactKey(kind: artifact.artifactKind, digest: digest))
            }
        }

        var refs: [ArtifactRef] = []
        var created: [ArtifactRef] = []
        do {
            for artifact in artifacts {
                let ref = try await attachments.store(
                    artifact.data,
                    kind: artifact.artifactKind,
                    fileExtension: artifact.fileExtension
                )
                refs.append(ref)
                if !preexisting.contains(Self.artifactKey(kind: ref.kind, digest: ref.sha256)) {
                    created.append(ref)
                }
            }

            var updated = conversation
            var turn = updated.turns[turnIndex]
            for (position, artifact) in artifacts.enumerated() {
                guard let index = artifact.attachmentIndex else { continue }
                var attachment = turn.attachments[index]
                var archived = attachment.artifacts ?? AttachmentArtifacts()
                switch artifact.role {
                case .original: archived.original = refs[position]
                case .normalizedImage: archived.normalizedImage = refs[position]
                case .extractedText: archived.extractedText = refs[position]
                // Unreachable: an index is refused for a snapshot above.
                case .requestSnapshot: continue
                }
                attachment.artifacts = archived
                turn.attachments[index] = attachment
            }
            updated.turns[turnIndex] = turn

            try await conversations.save(updated, savedAt: savedAt)

            return TurnCommit(
                conversation: updated,
                turnIndex: turnIndex,
                artifacts: refs,
                createdDigests: created.map(\.sha256),
                savedAt: savedAt
            )
        } catch {
            if let error = error as? ChatCommitError { throw error }
            // Never delete on failure. Bytes this commit wrote stay on disk and
            // are reported to the caller: another commit may already hold a ref
            // to the same content, and the reference scan cannot see a commit
            // that has not saved yet.
            throw ChatCommitError.commitFailed(
                conversationID: conversation.id,
                turnIndex: turnIndex,
                detail: error.localizedDescription,
                retainedOrphans: created
            )
        }
    }

    static func artifactKey(kind: ArtifactRef.Kind, digest: String) -> String {
        "\(kind.rawValue):\(digest)"
    }

    // MARK: Reference checks

    /// Every readable conversation. Throws `referenceScanIncomplete` when any
    /// file is unreadable, corrupt, or written by a newer schema, so a caller
    /// can never mistake "could not read" for "not referenced".
    private func readableConversations() async throws -> [ConversationRecord] {
        var records: [ConversationRecord] = []
        for summary in try await conversations.list() {
            if let issue = summary.issue {
                throw ChatCommitError.referenceScanIncomplete(id: summary.id, detail: issue.rawValue)
            }
            do {
                records.append(try await conversations.load(id: summary.id))
            } catch {
                throw ChatCommitError.referenceScanIncomplete(
                    id: summary.id,
                    detail: String(describing: error)
                )
            }
        }
        return records
    }

    /// Every digest any conversation references: original content hashes, the
    /// artifacts attached to a record, and request snapshots.
    ///
    /// Throws when any conversation file cannot be read, so this never returns
    /// a set that is missing an owner's references.
    public func referencedDigests() async throws -> Set<String> {
        var digests = Set<String>()
        for conversation in try await readableConversations() {
            for attachment in conversation.attachments {
                if let hash = attachment.contentHash { digests.insert(hash) }
                let refs = [
                    attachment.artifacts?.original,
                    attachment.artifacts?.normalizedImage,
                    attachment.artifacts?.extractedText,
                ]
                for ref in refs {
                    if let ref { digests.insert(ref.sha256) }
                }
            }
            for turn in conversation.turns {
                for snapshot in turn.request?.attachmentRefs ?? [] {
                    if let hash = snapshot.snapshotHash { digests.insert(hash) }
                    if let hash = snapshot.contentHash { digests.insert(hash) }
                }
            }
        }
        return digests
    }

    /// The IDs of the conversations that reference a digest, for a deletion
    /// check across every chat, not just the one on screen. Throws when any
    /// conversation file cannot be read.
    public func owners(of digest: String) async throws -> [String] {
        var owners: [String] = []
        for conversation in try await readableConversations() {
            var references = false
            for attachment in conversation.attachments {
                if attachment.contentHash == digest { references = true }
                if attachment.artifacts?.original?.sha256 == digest
                    || attachment.artifacts?.normalizedImage?.sha256 == digest
                    || attachment.artifacts?.extractedText?.sha256 == digest {
                    references = true
                }
            }
            for turn in conversation.turns where !references {
                for snapshot in turn.request?.attachmentRefs ?? [] {
                    if snapshot.snapshotHash == digest || snapshot.contentHash == digest {
                        references = true
                    }
                }
            }
            if references { owners.append(conversation.id) }
        }
        return owners.sorted()
    }

    /// Removes the given artifacts only when no conversation references them,
    /// and returns the ones actually removed. This is the only bulk removal
    /// path in the package and it never runs on a timer.
    ///
    /// Runs under the same root lock as `commit`, so a deletion can never
    /// interleave with a commit that is storing or saving: by the time the scan
    /// runs, every commit that held the lock has finished, and its conversation
    /// is either saved (and therefore visible) or failed (and therefore
    /// retained).
    ///
    /// Fail closed: if any conversation file cannot be read, this throws
    /// `ChatCommitError.referenceScanIncomplete` and removes nothing.
    @discardableResult
    public func removeArtifactsIfUnreferenced(_ refs: [ArtifactRef]) async throws -> [ArtifactRef] {
        guard let lock else { return try await performRemoval(refs) }
        return try await lock.withLock {
            try await self.performRemoval(refs)
        }
    }

    private func performRemoval(_ refs: [ArtifactRef]) async throws -> [ArtifactRef] {
        let referenced = try await referencedDigests()
        var removed: [ArtifactRef] = []
        for ref in refs where !referenced.contains(ref.sha256) {
            guard await attachments.contains(ref) else { continue }
            try await attachments.remove(ref)
            removed.append(ref)
        }
        return removed
    }
}
