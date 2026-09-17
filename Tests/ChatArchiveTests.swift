import Testing
import Foundation
import HouseChatCore
@testable import QuickLaunch

/// The durable keep-all archive: legacy migration, idempotency, fail-closed
/// reads, the frozen per-turn route, tombstones, and structured retention.
@Suite("Chat archive", .serialized)
struct ChatArchiveTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-archive-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func legacyConversation(
        id: UUID = UUID(),
        assistantID: UUID? = nil,
        enabledTools: Set<ChatToolKind>? = [.memory, .vault],
        messages: [QuickMessage]? = nil
    ) -> QuickConversation {
        QuickConversation(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            providerID: UUID(),
            model: "deepseek-chat",
            messages: messages ?? [
                QuickMessage(role: .user, content: "Summarize the report"),
                QuickMessage(role: .assistant, content: "It grew."),
            ],
            customTitle: "Quarterly",
            titleSource: "Summarize the report",
            isPinned: true,
            enabledTools: enabledTools,
            assistantID: assistantID
        )
    }

    private func firstFile(in directory: URL) throws -> URL {
        try #require(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
    }

    // MARK: - Migration

    @Test func migrationImportsAndIsIdempotent() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let conversation = legacyConversation()

        let first = await archive.migrate(legacy: [conversation], appVersion: "1.0.0")
        #expect(first.imported == 1)
        #expect(first.failed == 0)
        #expect(first.verified)
        #expect(first.isClean)
        #expect(archive.contains(id: conversation.id.uuidString))

        let second = await archive.migrate(legacy: [conversation], appVersion: "1.0.0")
        #expect(second.imported == 0)
        #expect(second.alreadyPresent == 1)
        #expect(second.isClean)

        let records = try await archive.loadAll()
        #expect(records.count == 1)
        #expect(records[0].turns.count == 2)
    }

    @Test func migrationPreservesQuickLaunchFields() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let assistantID = UUID()
        let card = AskUserQuestion(
            question: "Which one?",
            options: [AskUserQuestionOption(label: "A", detail: nil), AskUserQuestionOption(label: "B", detail: nil)],
            selectedIndex: 1
        )
        let toolRecords = [ChatToolRecord(kind: .vault, summary: "Searched vault", sources: [
            ChatSource(title: "Acme", day: "2026-09-01", path: "/tmp/acme.md"),
        ])]
        let conversation = legacyConversation(
            assistantID: assistantID,
            messages: [
                QuickMessage(role: .user, content: "Ask me"),
                QuickMessage(role: .assistant, content: "Which?", askUserQuestion: card, toolRecords: toolRecords),
            ]
        )
        _ = await archive.migrate(legacy: [conversation], appVersion: "1.0.0")
        let record = try await archive.load(id: conversation.id.uuidString)

        #expect(record.appPayload?["titleSource"]?.stringValue == "Summarize the report")
        #expect(record.appPayload?["isPinned"]?.boolValue == true)
        #expect(record.appPayload?["assistantID"]?.stringValue == assistantID.uuidString)
        #expect(record.appPayload?["enabledTools"]?.arrayValue?.count == 2)
        #expect(record.appPayload?["customTitle"]?.stringValue == "Quarterly")

        // The card and the tool records survive in the assistant turn's payload.
        let assistantTurn = try #require(record.turns.last)
        let decodedCard = try #require(ChatArchive.decodeValue(
            assistantTurn.appPayload?["askUserQuestion"] ?? .null,
            as: AskUserQuestion.self
        ))
        #expect(decodedCard.selectedIndex == 1)
        #expect(decodedCard.options.count == 2)
        let decodedTools = try #require(ChatArchive.decodeValue(
            assistantTurn.appPayload?["toolRecords"] ?? .null,
            as: [ChatToolRecord].self
        ))
        #expect(decodedTools.first?.summary == "Searched vault")
        #expect(decodedTools.first?.sources.first?.path == "/tmp/acme.md")

        // A rebuild keeps the same fields.
        let rebuilt = try #require(await archive.rebuildProjections().first)
        #expect(rebuilt.id == conversation.id)
        #expect(rebuilt.customTitle == "Quarterly")
        #expect(rebuilt.titleSource == "Summarize the report")
        #expect(rebuilt.isPinned == true)
        #expect(rebuilt.assistantID == assistantID)
        #expect(rebuilt.messages.last?.askUserQuestion?.selectedIndex == 1)
        #expect(rebuilt.messages.last?.toolRecords?.first?.summary == "Searched vault")
    }

    @Test func migrationLeavesMissingBytesMissingAndNeverFetches() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let ref = ChatAttachmentRef(
            kind: .link,
            name: "Example",
            byteCount: 1200,
            characterCount: 900,
            contentHash: SHA256Digest.hex("body"),
            url: URL(string: "https://example.com/story")!
        )
        let conversation = legacyConversation(messages: [
            QuickMessage(role: .user, content: "Read this", attachments: [ref]),
        ])
        _ = await archive.migrate(legacy: [conversation], appVersion: "1.0.0")
        let record = try await archive.load(id: conversation.id.uuidString)
        let attachment = try #require(record.turns.first?.attachments.first)
        #expect(attachment.artifacts == nil, "a legacy reference has no archived bytes")
        #expect(attachment.contentHash == SHA256Digest.hex("body"), "the reference is preserved, not re-fetched")
        let artifacts = try await archive.attachments.list()
        #expect(artifacts.isEmpty, "migration never reads or fetches a source")

        let retained = try #require(await archive.retainedSource(conversationID: record.id, attachmentID: attachment.id))
        #expect(!retained.hasBytes)
        #expect(retained.missingRoles.count == 3)
    }

    @Test func aCorruptConversationIsNeverReplacedByAnEmptyStore() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let conversation = legacyConversation()
        _ = await archive.migrate(legacy: [conversation], appVersion: "1.0.0")

        // Damage one conversation file.
        let chatsRoot = directory.appendingPathComponent("chats", isDirectory: true)
        let file = try firstFile(in: chatsRoot)
        try "not json at all".write(to: file, atomically: true, encoding: .utf8)

        let summaries = try await archive.conversations.list()
        #expect(summaries.contains { $0.issue != nil }, "the damaged file is reported, not hidden")

        // A strict read fails closed instead of inventing an empty record.
        do {
            _ = try await archive.loadAll()
            Issue.record("loadAll must fail closed on a damaged record")
        } catch let error as ChatArchiveError {
            guard case .recordUnreadable = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }

        // Migrating again must not overwrite the damaged file with a fresh one.
        let report = await archive.migrate(legacy: [conversation], appVersion: "1.0.0")
        #expect(report.alreadyPresent == 1, "an existing (even damaged) file is not replaced")
        let after = try Data(contentsOf: file)
        #expect(after == Data("not json at all".utf8), "the damaged bytes are untouched")
    }

    @Test func aNewerSchemaIsReportedNotSilentlyDowngraded() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let chatsRoot = directory.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsRoot, withIntermediateDirectories: true)
        let envelope = """
        {"format":"house-chat-conversation","schemaVersion":999,"conversation":{"id":"future","schemaVersion":999,"turns":[]}}
        """
        try envelope.write(
            to: chatsRoot.appendingPathComponent("future-abc.json"),
            atomically: true,
            encoding: .utf8
        )
        let summaries = try await archive.conversations.list()
        #expect(summaries.first?.issue == .unsupportedSchema, "a newer record is flagged, not read as empty")
    }

    @Test func aNewerSchemaBlocksARewrite() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let id = UUID().uuidString
        let conversations = archive.conversations
        let file = conversations.fileURL(for: id)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("chats", isDirectory: true),
            withIntermediateDirectories: true
        )
        let future = """
        {"format":"house-chat-conversation","schemaVersion":999,"conversation":{"id":"\(id)","schemaVersion":999,"turns":[]}}
        """
        try future.write(to: file, atomically: true, encoding: .utf8)

        let live = legacyConversation(id: UUID(uuidString: id)!)
        do {
            try await archive.syncConversation(live)
            Issue.record("a rewrite of a newer record must be refused")
        } catch {
            // Expected: unsupportedSchema propagates.
        }
        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(after.contains("\"schemaVersion\":999"), "the newer record is untouched")
    }

    // MARK: - Rounds and rewrites

    @Test func commitUserTurnArchivesTheTextAndFreezesTheRoute() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let ref = ChatAttachmentRef(
            kind: .text,
            name: "notes.txt",
            byteCount: 5,
            characterCount: 5,
            contentHash: SHA256Digest.hex("hello")
        )
        let conversation = legacyConversation(messages: [
            QuickMessage(role: .user, content: "What does it say", attachments: [ref]),
        ])
        let content = AttachmentContent(ref: ref, text: "hello")
        let selection = ModelSelection(
            chosen: ModelChoice(provider: "DeepSeek", model: "deepseek-chat", thinking: "low"),
            effective: ModelChoice(provider: "DeepSeek", model: "deepseek-chat", thinking: "low")
        )

        try await archive.commitUserTurn(conversation, attachmentContents: [content], model: selection)

        let record = try await archive.load(id: conversation.id.uuidString)
        let turn = try #require(record.turns.first)
        #expect(turn.model?.chosen?.model == "deepseek-chat")
        #expect(turn.model?.chosen?.thinking == "low")
        let attachment = try #require(turn.attachments.first)
        let textRef = try #require(attachment.artifacts?.extractedText)
        let bytes = try await archive.attachments.read(textRef)
        #expect(String(data: bytes, encoding: .utf8) == "hello")

        // The original file bytes are absent (there is no file), so the
        // original artifact is not fabricated.
        #expect(attachment.artifacts?.original == nil)
    }

    @Test func aSecondCommitKeepsTheFirstTurnsArtifactsAndRoute() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let ref1 = ChatAttachmentRef(kind: .text, name: "a.txt", characterCount: 5, contentHash: SHA256Digest.hex("hello"))
        let ref2 = ChatAttachmentRef(kind: .text, name: "b.txt", characterCount: 5, contentHash: SHA256Digest.hex("world"))
        let first = legacyConversation(messages: [QuickMessage(role: .user, content: "one", attachments: [ref1])])
        let selection1 = ModelSelection(ModelChoice(provider: "DeepSeek", model: "deepseek-chat", thinking: "low"))
        try await archive.commitUserTurn(
            first,
            attachmentContents: [AttachmentContent(ref: ref1, text: "hello")],
            model: selection1
        )

        var second = first
        second.messages.append(QuickMessage(role: .assistant, content: "answer"))
        second.messages.append(QuickMessage(role: .user, content: "two", attachments: [ref2]))
        let selection2 = ModelSelection(ModelChoice(provider: "DeepSeek", model: "deepseek-reasoner", thinking: "high"))
        try await archive.commitUserTurn(
            second,
            attachmentContents: [AttachmentContent(ref: ref2, text: "world")],
            model: selection2
        )

        let record = try await archive.load(id: first.id.uuidString)
        let firstTurn = try #require(record.turns.first)
        #expect(firstTurn.model?.chosen?.model == "deepseek-chat", "the first turn's frozen route survives")
        let firstAttachment = try #require(firstTurn.attachments.first)
        let textRef = try #require(firstAttachment.artifacts?.extractedText, "the first turn's artifact ref survives")
        #expect(String(data: try await archive.attachments.read(textRef), encoding: .utf8) == "hello")
        #expect(record.turns.last?.model?.chosen?.model == "deepseek-reasoner")
    }

    @Test func unknownFieldsSurviveARewrite() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)

        let ref = ChatAttachmentRef(
            kind: .text,
            name: "notes.txt",
            characterCount: 5,
            contentHash: SHA256Digest.hex("hello")
        )
        var record = ChatArchive.record(for: legacyConversation(messages: [
            QuickMessage(role: .user, content: "one", attachments: [ref]),
        ]))
        // Seed a newer build's fields at every level.
        record.extra["futureConversation"] = .string("c")
        record.appPayload?["futureApp"] = .string("p")
        record.turns[0].extra["futureTurn"] = .string("t")
        record.turns[0].appPayload = AppPayload(namespace: ChatArchive.namespace)
        record.turns[0].appPayload?["futureTurnApp"] = .string("ta")
        record.turns[0].attachments[0].extra["futureAttachment"] = .string("a")
        record.turns[0].attachments[0].artifacts = AttachmentArtifacts(
            original: ArtifactRef(
                kind: .original,
                sha256: SHA256Digest.hex("hello"),
                byteCount: 5,
                extra: ExtraFields(["futureArtifact": .string("x")])
            )
        )
        record.turns[0].request = RequestReceipt(extra: ExtraFields(["futureReceipt": .string("r")]))
        try await archive.conversations.save(record)

        // A live projection with the same IDs, and newer metadata.
        var live = try #require(ChatArchive.legacyConversation(for: record))
        live.messages[0].content = "changed text"
        live.updatedAt = (record.updatedAt ?? Date()).addingTimeInterval(100)
        try await archive.syncConversation(live)

        let merged = try await archive.load(id: record.id)
        #expect(merged.extra["futureConversation"]?.stringValue == "c")
        #expect(merged.appPayload?["futureApp"]?.stringValue == "p")
        #expect(merged.turns[0].extra["futureTurn"]?.stringValue == "t")
        #expect(merged.turns[0].appPayload?["futureTurnApp"]?.stringValue == "ta")
        #expect(merged.turns[0].attachments[0].extra["futureAttachment"]?.stringValue == "a")
        #expect(merged.turns[0].attachments[0].artifacts?.original?.extra["futureArtifact"]?.stringValue == "x")
        #expect(merged.turns[0].request?.extra["futureReceipt"]?.stringValue == "r")
        #expect(merged.turns[0].text == "changed text", "the live turn text is applied")
    }

    @Test func aCorruptRecordBlocksARewriteAndIsNotReplaced() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let conversation = legacyConversation(messages: [QuickMessage(role: .user, content: "one")])
        _ = await archive.migrate(legacy: [conversation], appVersion: "1.0.0")

        let chatsRoot = directory.appendingPathComponent("chats", isDirectory: true)
        let file = try firstFile(in: chatsRoot)
        try "garbage".write(to: file, atomically: true, encoding: .utf8)

        var live = conversation
        live.messages[0].content = "changed"
        do {
            try await archive.syncConversation(live)
            Issue.record("a rewrite over a corrupt record must be refused")
        } catch let error as ChatArchiveError {
            guard case .recordUnreadable = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "garbage")
    }

    // MARK: - Keep-all, restart, deletion

    @Test func allChatsStayVisiblePastTheLegacyCacheLimit() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let conversations = (0..<150).map { index in
            legacyConversation(messages: [
                QuickMessage(role: .user, content: "question \(index)"),
                QuickMessage(role: .assistant, content: "answer \(index)"),
            ])
        }
        let report = await archive.migrate(legacy: conversations, appVersion: "1.0.0")
        #expect(report.imported == 150)
        #expect(report.isClean)

        // The canonical archive is uncapped.
        #expect(try await archive.loadAll().count == 150)
        #expect(try await archive.rebuildProjections().count == 150)

        // The legacy UI cache is still bounded in memory, but that bound never
        // touches the canonical rows. Unpinned, so the bound actually applies.
        let unpinned = conversations.map { conversation -> QuickConversation in
            var copy = conversation
            copy.isPinned = false
            return copy
        }
        #expect(QuickHistoryStore.bounded(unpinned, limit: 100).count == 100)
    }

    @Test func restartAndOriginalDeletionStillReadsRetainedBytes() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let missingPath = "/tmp/quick-launch-missing-\(UUID().uuidString).txt"
        let bytes = Data("hello original".utf8)
        let ref = ChatAttachmentRef(
            kind: .text,
            name: "notes.txt",
            byteCount: bytes.count,
            characterCount: bytes.count,
            contentHash: SHA256Digest.hex(bytes),
            path: missingPath
        )
        let conversation = legacyConversation(messages: [
            QuickMessage(role: .user, content: "read", attachments: [ref]),
        ])
        try await archive.commitUserTurn(
            conversation,
            attachmentContents: [AttachmentContent(ref: ref, text: "hello original", originalBytes: bytes)],
            model: nil
        )

        // A fresh instance, as after a restart, reads the archive, not the
        // original path that no longer exists.
        let restarted = try ChatArchive(root: directory)
        let original = try #require(await restarted.retainedBytes(
            conversationID: conversation.id.uuidString,
            attachmentID: ref.id.uuidString,
            role: .original
        ))
        #expect(original == bytes)
        #expect(try await restarted.retainedText(
            conversationID: conversation.id.uuidString,
            attachmentID: ref.id.uuidString
        ) == "hello original")
        #expect(!FileManager.default.fileExists(atPath: missingPath))
    }

    @Test func sharedBytesSurviveDeletingOneOwner() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let bytes = Data("shared body".utf8)
        let hash = SHA256Digest.hex(bytes)

        func conversation() -> (QuickConversation, ChatAttachmentRef) {
            let ref = ChatAttachmentRef(
                kind: .text,
                name: "shared.txt",
                byteCount: bytes.count,
                contentHash: hash
            )
            let conversation = legacyConversation(messages: [
                QuickMessage(role: .user, content: "read", attachments: [ref]),
            ])
            return (conversation, ref)
        }

        let (first, firstRef) = conversation()
        let (second, _) = conversation()
        for conversation in [first, second] {
            try await archive.commitUserTurn(
                conversation,
                attachmentContents: [AttachmentContent(ref: conversation.messages[0].attachments![0], text: "shared body", originalBytes: bytes)],
                model: nil
            )
        }

        let firstRecord = try await archive.load(id: first.id.uuidString)
        let storedRef = try #require(firstRecord.attachments.first?.artifacts?.original)

        let report = try await archive.delete(id: first.id.uuidString)
        #expect(report.gcIssue == nil)
        // The bytes are still referenced by the second chat, so they stay.
        #expect(try await archive.attachments.read(storedRef) == bytes)
        #expect(await archive.attachments.contains(ArtifactRef(
            kind: .original,
            sha256: hash,
            byteCount: bytes.count
        )))
        _ = second
        _ = firstRef
    }

    @Test func deletingUsesTheTombstoneAndCannotBeResurrected() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let ref = ChatAttachmentRef(kind: .text, name: "a.txt", characterCount: 5, contentHash: SHA256Digest.hex("hello"))
        let conversation = legacyConversation(messages: [
            QuickMessage(role: .user, content: "one", attachments: [ref]),
        ])
        try await archive.commitUserTurn(
            conversation,
            attachmentContents: [AttachmentContent(ref: ref, text: "hello", originalBytes: Data("hello".utf8))],
            model: nil
        )

        let report = try await archive.delete(id: conversation.id.uuidString)
        #expect(!report.wasAlreadyMissing)
        #expect(await archive.isDeleted(id: conversation.id.uuidString))
        #expect(await archive.deletedIDs() == [conversation.id.uuidString])
        #expect(!archive.contains(id: conversation.id.uuidString))

        // A late answer for the deleted thread is refused, not recreated.
        await #expect(throws: ChatArchiveError.conversationDeleted(id: conversation.id.uuidString)) {
            _ = try await archive.completeTurn(
                conversationID: conversation.id.uuidString,
                turnID: UUID().uuidString,
                text: "late answer"
            )
        }
        await #expect(throws: ChatArchiveError.conversationDeleted(id: conversation.id.uuidString)) {
            try await archive.syncConversation(conversation)
        }
        await #expect(throws: ChatArchiveError.conversationDeleted(id: conversation.id.uuidString)) {
            try await archive.rename(id: conversation.id.uuidString, customTitle: "zombie")
        }
        #expect((try? await archive.load(id: conversation.id.uuidString)) == nil)
    }

    @Test func deletingOneOfTwoOwnersReclaimsOnlyItsUnsharedBlobs() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let bytes = Data("only mine".utf8)
        let ref = ChatAttachmentRef(kind: .text, name: "a.txt", characterCount: 9, contentHash: SHA256Digest.hex(bytes))
        let conversation = legacyConversation(messages: [
            QuickMessage(role: .user, content: "one", attachments: [ref]),
        ])
        try await archive.commitUserTurn(
            conversation,
            attachmentContents: [AttachmentContent(ref: ref, text: "only mine", originalBytes: bytes)],
            model: nil
        )
        let record = try await archive.load(id: conversation.id.uuidString)
        let original = try #require(record.attachments.first?.artifacts?.original)
        #expect(await archive.attachments.contains(original))

        _ = try await archive.delete(id: conversation.id.uuidString)
        #expect(!(await archive.attachments.contains(original)), "an unshared blob is reclaimed")
    }

    // MARK: - Concurrency, checkpoints, receipts

    @Test func concurrentRenameAndCheckpointBothApply() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let ref = ChatAttachmentRef(kind: .text, name: "a.txt", characterCount: 5, contentHash: SHA256Digest.hex("hello"))
        let conversation = legacyConversation(messages: [
            QuickMessage(role: .user, content: "one", attachments: [ref]),
        ])
        try await archive.commitUserTurn(
            conversation,
            attachmentContents: [AttachmentContent(ref: ref, text: "hello")],
            model: nil
        )
        let answerID = UUID().uuidString

        async let rename: Void = archive.rename(id: conversation.id.uuidString, customTitle: "Renamed")
        async let checkpoint = archive.checkpoint(
            conversationID: conversation.id.uuidString,
            turnID: answerID,
            update: .checkpoint(text: "partial")
        )
        _ = try await rename
        _ = try await checkpoint

        let record = try await archive.load(id: conversation.id.uuidString)
        #expect(record.appPayload?["customTitle"]?.stringValue == "Renamed")
        #expect(record.turns.contains { $0.id == answerID && $0.text == "partial" })
    }

    @Test func checkpointAndCompletionRecordTheReceiptAndSnapshot() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let ref = ChatAttachmentRef(kind: .text, name: "a.txt", characterCount: 5, contentHash: SHA256Digest.hex("hello"))
        let conversation = legacyConversation(messages: [
            QuickMessage(role: .user, content: "one", attachments: [ref]),
        ])
        let requestBody = Data(#"{"model":"deepseek-chat","messages":[]}"#.utf8)
        let selection = ModelSelection(ModelChoice(provider: "DeepSeek", model: "deepseek-chat", thinking: "off"))
        try await archive.submit(TurnSubmission(
            conversation: conversation,
            attachmentContents: [AttachmentContent(ref: ref, text: "hello", originalBytes: Data("hello".utf8))],
            model: selection,
            context: ContextReceipt(scope: .currentSource, matched: true),
            tools: [.vault],
            requestSnapshot: requestBody,
            requestSnapshotKind: "request",
            endpoint: EndpointDescriptor(scheme: "https", host: "api.deepseek.com", path: "/v1/chat"),
            startedAt: Date()
        ))

        let answerID = UUID().uuidString
        _ = try await archive.checkpoint(
            conversationID: conversation.id.uuidString,
            turnID: answerID,
            update: .checkpoint(text: "Hel")
        )
        _ = try await archive.completeTurn(
            conversationID: conversation.id.uuidString,
            turnID: answerID,
            text: "Hello",
            receipt: RequestReceipt(status: .completed, usage: TokenUsage(inputTokens: 10, outputTokens: 2))
        )

        let record = try await archive.load(id: conversation.id.uuidString)
        let userTurn = try #require(record.turns.first)
        let request = try #require(userTurn.request)
        #expect(request.status == .pending, "the submit receipt keeps the state it was written with")
        #expect(request.extra["tools"]?.arrayValue?.map(\.stringValue) == ["vault"])
        #expect(request.context?.scope == .currentSource)
        let snapshot = try #require(request.attachmentRefs.first { $0.kind == "request" })
        #expect(snapshot.snapshotHash == SHA256Digest.hex(requestBody))
        // The snapshot is a real, referenced blob.
        let snapshotRef = ArtifactRef(
            kind: .requestSnapshot,
            sha256: try #require(snapshot.snapshotHash),
            byteCount: try #require(snapshot.byteCount)
        )
        #expect(try await archive.attachments.read(snapshotRef) == requestBody)

        let answer = try #require(record.turns.last)
        #expect(answer.text == "Hello")
        #expect(answer.request?.status == .completed)
        #expect(answer.request?.usage?.inputTokens == 10)
        // The submit-time snapshot refs stay on the turn that made the request,
        // and the digest is still referenced after the answer completes.
        #expect(userTurn.request?.attachmentRefs == request.attachmentRefs)
        #expect(try await archive.attachments.read(snapshotRef) == requestBody,
                "the snapshot is still referenced by record and scan")
        #expect(try await archive.coordinator.referencedDigests().contains(snapshotRef.sha256))
    }

    // MARK: - Structured retention

    @Test func structuredExtractionSurvivesResumeWithoutRereading() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let missingPath = "/tmp/quick-launch-gone-\(UUID().uuidString).pdf"
        let original = Data("pdf-bytes".utf8)
        let document = ExtractedDocument(
            kind: .pdf,
            kindLabel: "PDF",
            name: "report.pdf",
            sections: [
                DocumentSection(label: "Page 1", unit: .page, index: 1, range: DocumentRange(start: 1, end: 1), text: "Revenue rose."),
                DocumentSection(label: "Page 2", unit: .page, index: 2, range: DocumentRange(start: 2, end: 2), text: "Costs fell."),
            ],
            sectionUnit: .page,
            unitCount: 2,
            contentHash: SHA256Digest.hex(original),
            byteCount: original.count,
            characterCount: 23,
            text: "Revenue rose.\nCosts fell.",
            path: missingPath
        )
        let ref = ChatAttachmentRef(
            kind: .pdf,
            name: "report.pdf",
            byteCount: original.count,
            pageCount: 2,
            characterCount: 23,
            contentHash: SHA256Digest.hex(original),
            path: missingPath
        )
        let conversation = legacyConversation(messages: [
            QuickMessage(role: .user, content: "summarize", attachments: [ref]),
        ])
        try await archive.submit(TurnSubmission(
            conversation: conversation,
            attachmentContents: [AttachmentContent(
                ref: ref,
                text: document.text,
                originalBytes: original,
                extractedDocument: document
            )]
        ))

        // A resume reads the preserved structured extraction, not the file.
        let restarted = try ChatArchive(root: directory)
        let restored = try #require(await restarted.retainedDocument(
            conversationID: conversation.id.uuidString,
            attachmentID: ref.id.uuidString
        ))
        #expect(restored.sections.count == 2)
        #expect(restored.sections[1].label == "Page 2")
        #expect(restored.sections[1].range?.start == 2)
        #expect(restored.sectionUnit == .page)
        #expect(restored.unitCount == 2)
        #expect(restored.text == "Revenue rose.\nCosts fell.")
        #expect(try await restarted.retainedText(
            conversationID: conversation.id.uuidString,
            attachmentID: ref.id.uuidString
        ) == "Revenue rose.\nCosts fell.")
        #expect(!FileManager.default.fileExists(atPath: missingPath))

        // The extraction is one referenced artifact, not a second blob.
        let sources = try await restarted.retainedSources(conversationID: conversation.id.uuidString)
        #expect(sources.first?.extractedText != nil)
        #expect(try await restarted.coordinator.referencedDigests().contains(
            try #require(sources.first?.extractedText?.sha256)
        ))
    }

    // MARK: - Failure and health

    @Test func aWriteFailureBlocksTheTurnAndRetainsItsBytes() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        // The chats root is a regular file, so reads see "missing" but the
        // conversation save cannot succeed. This is the disk-failure shape.
        try "not a directory".write(
            to: directory.appendingPathComponent("chats"),
            atomically: true,
            encoding: .utf8
        )

        let ref = ChatAttachmentRef(kind: .text, name: "a.txt", characterCount: 5, contentHash: SHA256Digest.hex("hello"))
        let conversation = legacyConversation(messages: [QuickMessage(role: .user, content: "one", attachments: [ref])])
        await #expect(throws: (any Error).self) {
            try await archive.commitUserTurn(
                conversation,
                attachmentContents: [AttachmentContent(ref: ref, text: "hello")],
                model: nil
            )
        }
        // The turn is blocked: no conversation record was written, so the
        // caller keeps the draft and never calls a provider.
        #expect((try? await archive.load(id: conversation.id.uuidString)) == nil)
        // The core retains any bytes a failed save wrote so a concurrent
        // commit cannot lose them.
        let orphans = try await archive.attachments.list()
        #expect(!orphans.isEmpty, "the failed commit's bytes are retained, not lost mid-write")
    }

    @Test func commitUserTurnRefusesAConversationWithNoUserTurn() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let conversation = legacyConversation(messages: [
            QuickMessage(role: .assistant, content: "orphan answer"),
        ])
        await #expect(throws: ChatArchiveError.noUserTurn(conversationID: conversation.id.uuidString)) {
            try await archive.commitUserTurn(conversation, attachmentContents: [])
        }
    }

    @Test func aCheckpointForAnAbsentChatIsRefused() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        await #expect(throws: ChatArchiveError.noConversation(conversationID: "absent")) {
            _ = try await archive.checkpoint(
                conversationID: "absent",
                turnID: "turn",
                update: .checkpoint(text: "x")
            )
        }
    }

    @Test func sharedInstanceIsOnePerRoot() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        ChatArchiveRegistry.reset()
        let first = try ChatArchive.shared(root: directory)
        let second = try ChatArchive.shared(root: directory)
        #expect(first === second, "both windows share one serialized archive")
        // A different root is a different archive.
        let otherDirectory = try root()
        defer { try? FileManager.default.removeItem(at: otherDirectory) }
        #expect((try ChatArchive.shared(root: otherDirectory)) !== first)
    }

    @Test func legacyCacheDistinguishesCorruptFromMissingAndKeepsRollback() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(QuickHistoryStore.fileName)

        #expect(QuickHistoryStore.loadResult(from: file, migratingFrom: nil) == .missing)

        // A damaged legacy file is rollback evidence, never read as empty.
        try "garbage".write(to: file, atomically: true, encoding: .utf8)
        #expect(QuickHistoryStore.loadResult(from: file, migratingFrom: nil) == .corrupt)
        #expect(QuickHistoryStore.load(from: file, migratingFrom: nil).isEmpty)

        let backup = try #require(try QuickHistoryStore.backupForRollback(from: file))
        #expect(try Data(contentsOf: backup) == Data("garbage".utf8))

        // The cache can be rebuilt from the archive's projection, bounded.
        let conversations = (0..<150).map { index -> QuickConversation in
            QuickConversation(
                providerID: UUID(),
                model: "deepseek-chat",
                messages: [QuickMessage(role: .user, content: "q\(index)")],
                isPinned: false
            )
        }
        QuickHistoryStore.rebuildCache(conversations, limit: 100, to: file)
        QuickHistoryStore.waitForPendingWrites()
        guard case .loaded(let loaded) = QuickHistoryStore.loadResult(from: file, migratingFrom: nil) else {
            Issue.record("the rebuilt cache should load")
            return
        }
        #expect(loaded.count == 100)
    }

    @Test func surveyAndProjectionReportDamageInsteadOfHidingIt() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try ChatArchive(root: directory)
        let good = legacyConversation(messages: [QuickMessage(role: .user, content: "good")])
        let bad = legacyConversation(messages: [QuickMessage(role: .user, content: "bad")])
        _ = await archive.migrate(legacy: [good, bad], appVersion: "1.0.0")

        let chatsRoot = directory.appendingPathComponent("chats", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: chatsRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        // Corrupt exactly one.
        try "garbage".write(to: files[0], atomically: true, encoding: .utf8)

        let survey = try await archive.survey()
        #expect(survey.damagedCount == 1)
        #expect(survey.conversationCount == 1)
        #expect(!survey.isHealthy)

        let projection = try await archive.projectReadable()
        #expect(projection.conversations.count == 1)
        #expect(projection.damaged.count == 1)
    }
}
