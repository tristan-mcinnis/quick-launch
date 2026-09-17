import Foundation
import Testing
@testable import HouseChatCore

/// One test per verifier finding. Each name says what must not regress.
@Suite("Verifier regressions")
struct VerifierRegressionTests {
    // MARK: P1 - unknown keys survive every nesting level

    @Test("Unknown keys survive a round trip in every nested schema type")
    func nestedUnknownKeysSurvive() throws {
        let json = #"""
        {
          "model": {"provider":"deepseek","model":"chat","futureModelChoice":1},
          "context": {"scope":"currentSource","futureContextReceipt":2},
          "usage": {"totalTokens":10,"futureUsage":3},
          "calls": [{"name":"web_search","futureCall":4}],
          "sections": [{"label":"Page 1","text":"body","futureSection":5}],
          "notes": [{"kind":"ocr","futureNote":6}],
          "truncation": {"keptCharacters":5,"futureTruncation":7}
        }
        """#
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        let model = try HouseChatCoding.makeDecoder().decode(
            ModelChoice.self,
            from: try JSONSerialization.data(withJSONObject: object["model"]!)
        )
        #expect(model.extra["futureModelChoice"] == .number(1))

        let context = try HouseChatCoding.makeDecoder().decode(
            ContextReceipt.self,
            from: try JSONSerialization.data(withJSONObject: object["context"]!)
        )
        #expect(context.extra["futureContextReceipt"] == .number(2))

        let usage = try HouseChatCoding.makeDecoder().decode(
            TokenUsage.self,
            from: try JSONSerialization.data(withJSONObject: object["usage"]!)
        )
        #expect(usage.extra["futureUsage"] == .number(3))

        let calls = try HouseChatCoding.makeDecoder().decode(
            [ToolCall].self,
            from: try JSONSerialization.data(withJSONObject: object["calls"]!)
        )
        #expect(calls[0].extra["futureCall"] == .number(4))

        let sections = try HouseChatCoding.makeDecoder().decode(
            [DocumentSection].self,
            from: try JSONSerialization.data(withJSONObject: object["sections"]!)
        )
        #expect(sections[0].extra["futureSection"] == .number(5))

        let notes = try HouseChatCoding.makeDecoder().decode(
            [DocumentNote].self,
            from: try JSONSerialization.data(withJSONObject: object["notes"]!)
        )
        #expect(notes[0].extra["futureNote"] == .number(6))

        let truncation = try HouseChatCoding.makeDecoder().decode(
            TextTruncation.self,
            from: try JSONSerialization.data(withJSONObject: object["truncation"]!)
        )
        #expect(truncation.extra["futureTruncation"] == .number(7))

        // Every unknown key is still there after a rewrite.
        for (value, key) in [
            (try HouseChatCoding.makeEncoder().encode(model), "futureModelChoice"),
            (try HouseChatCoding.makeEncoder().encode(context), "futureContextReceipt"),
            (try HouseChatCoding.makeEncoder().encode(usage), "futureUsage"),
            (try HouseChatCoding.makeEncoder().encode(calls), "futureCall"),
            (try HouseChatCoding.makeEncoder().encode(sections), "futureSection"),
            (try HouseChatCoding.makeEncoder().encode(notes), "futureNote"),
            (try HouseChatCoding.makeEncoder().encode(truncation), "futureTruncation"),
        ] {
            #expect(String(decoding: value, as: UTF8.self).contains(key), "lost \(key)")
        }
    }

    // MARK: P2 - an unknown artifact kind is never treated as original

    @Test("An unknown artifact kind is preserved and every operation refuses it")
    func unknownArtifactKindRefused() async throws {
        let digest = String(repeating: "a", count: 64)
        let json = #"{"kind":"quantum","sha256":"\#(digest)","byteCount":4}"#
        let ref = try HouseChatCoding.makeDecoder().decode(ArtifactRef.self, from: Data(json.utf8))

        #expect(ref.kind == .unknown)
        #expect(ref.kindRaw == "quantum")
        #expect(ref.isReadable == false)

        let rewritten = try HouseChatCoding.makeDecoder().decode(
            ArtifactRef.self,
            from: HouseChatCoding.makeEncoder().encode(ref)
        )
        #expect(rewritten.kindRaw == "quantum")

        let temp = try TempDirectory(prefix: "unknown-kind")
        let archive = try AttachmentArchive(root: temp.appending("archive"))
        await #expect(throws: AttachmentArchiveError.unsupportedKind("quantum")) {
            try await archive.read(ref)
        }
        await #expect(throws: AttachmentArchiveError.unsupportedKind("quantum")) {
            try await archive.remove(ref)
        }
        #expect(await archive.contains(ref) == false)
        #expect(try await archive.verify(ref) == .missing)
        #expect(try await archive.list().isEmpty)
        await #expect(throws: AttachmentArchiveError.unsupportedKind("unknown")) {
            try await archive.store(Data("x".utf8), kind: .unknown)
        }
    }

    // MARK: P3/P4 - garbage collection fails closed

    @Test("GC refuses to delete bytes whose only owner record is corrupt")
    func gcFailsClosedOnCorruptOwner() async throws {
        let temp = try TempDirectory(prefix: "gc-corrupt")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let conversations = try ConversationArchive(root: temp.appending("conversations"))
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)

        let data = Data("only copy".utf8)
        let digest = SHA256Digest.hex(data)
        let attachment = AttachmentRecord(id: "a1", kind: .text, name: "notes.txt", contentHash: digest)
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

        // Dam the only owner record.
        try Data("not json".utf8).write(to: conversations.fileURL(for: "c1"))

        await #expect(throws: ChatCommitError.self) {
            try await coordinator.referencedDigests()
        }
        await #expect(throws: ChatCommitError.self) {
            try await coordinator.owners(of: digest)
        }
        await #expect(throws: ChatCommitError.self) {
            try await coordinator.removeArtifactsIfUnreferenced([ref])
        }
        #expect(await attachments.contains(ref), "the last copy was deleted")
        #expect(try await attachments.read(ref) == data)
    }

    @Test("GC refuses to delete bytes owned by a newer-schema record")
    func gcFailsClosedOnUnsupportedSchema() async throws {
        let temp = try TempDirectory(prefix: "gc-schema")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let conversations = try ConversationArchive(root: temp.appending("conversations"))
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)

        let data = Data("newer owner".utf8)
        let digest = SHA256Digest.hex(data)
        let ref = try await attachments.store(data, kind: .original, fileExtension: "txt")
        let attachment = AttachmentRecord(id: "a1", kind: .text, name: "notes.txt", contentHash: digest)
        let conversation = ConversationRecord(
            id: "c1",
            turns: [TurnRecord(role: .user, text: "hi", attachments: [attachment])]
        )
        // A record written by a newer build, referencing the same bytes.
        let envelope = ConversationEnvelope(schemaVersion: 99, conversation: conversation)
        try FileManager.default.createDirectory(at: conversations.root, withIntermediateDirectories: true)
        try HouseChatCoding.makeEncoder().encode(envelope)
            .write(to: conversations.fileURL(for: "c1"))

        await #expect(throws: ChatCommitError.self) {
            try await coordinator.removeArtifactsIfUnreferenced([ref])
        }
        #expect(await attachments.contains(ref), "bytes owned by a newer schema were deleted")
    }

    @Test("A rollback leaves created bytes in place when the reference scan is incomplete")
    func rollbackFailsClosedOnIncompleteScan() async throws {
        let temp = try TempDirectory(prefix: "rollback-failclosed")
        let attachments = try AttachmentArchive(root: temp.appending("attachments"))
        let conversationRoot = temp.appending("conversations")
        try FileManager.default.createDirectory(at: conversationRoot, withIntermediateDirectories: true)
        let conversations = try ConversationArchive(root: conversationRoot)
        let coordinator = ChatCommitCoordinator(attachments: attachments, conversations: conversations)

        // A damaged owner file makes the reference scan incomplete.
        try Data("{".utf8).write(to: conversations.fileURL(for: "damaged"))

        let fresh = Data("created by a commit that fails".utf8)
        let turn = TurnRecord(role: .user, text: "hi", attachments: [AttachmentRecord(id: "a1", kind: .pdf, name: "r.pdf")])
        let conversation = ConversationRecord(id: "c1", turns: [turn])

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: conversationRoot.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: conversationRoot.path)
        }

        await #expect(throws: ChatCommitError.self) {
            try await coordinator.commit(
                conversation: conversation,
                turnIndex: 0,
                artifacts: [PendingArtifact(role: .original, data: fresh, attachmentIndex: 0)]
            )
        }

        // Fail closed: the scan was incomplete, so nothing was deleted.
        let ref = ArtifactRef(kind: .original, sha256: SHA256Digest.hex(fresh), byteCount: fresh.count)
        #expect(await attachments.contains(ref), "bytes were deleted while an owner was unreadable")
        #expect(conversations.contains("c1") == false)
    }

    // MARK: P11 - endpoint sanitization in every path

    @Test("The memberwise endpoint initializer strips a query and redacts a key in the path")
    func memberwiseEndpointSanitized() throws {
        let withQuery = EndpointDescriptor(
            scheme: "https",
            host: "api.example.com",
            port: 8443,
            path: "/v1/chat?api_key=sk-live-123#frag"
        )
        #expect(withQuery.sanitized == "https://api.example.com:8443/v1/chat")
        #expect(withQuery.path == "/v1/chat")

        let withUserinfo = EndpointDescriptor(
            scheme: "https",
            host: "user:secret@api.example.com",
            path: "/v1/chat"
        )
        #expect(withUserinfo.sanitized == "https://api.example.com/v1/chat")

        let keyInPath = EndpointDescriptor(
            scheme: "https",
            host: "gateway.example.com",
            path: "/sk-live-123/v1/chat"
        )
        #expect(keyInPath.sanitized == "https://gateway.example.com/[redacted]/v1/chat")
        #expect(!keyInPath.sanitized.contains("sk-live-123"))

        // An unusable authority produces an empty descriptor, never a leak.
        let unusable = EndpointDescriptor(scheme: "https", host: "  ", path: "/v1")
        #expect(unusable.isUsable == false)
        #expect(unusable.sanitized.isEmpty)
        #expect(unusable.host == nil)

        // The validating initializer rejects instead.
        #expect(EndpointDescriptor(validatingScheme: "https", host: "  ", path: "/v1") == nil)
        #expect(EndpointDescriptor(validatingScheme: "", host: "api.example.com") == nil)
        #expect(EndpointDescriptor(validatingScheme: "https", host: "bad host/v1") == nil)
        #expect(EndpointDescriptor(validatingScheme: "https", host: "user:secret@api.example.com") != nil)
    }

    @Test("Decoding an endpoint re-sanitizes it, so a stored query cannot leak back")
    func decodedEndpointResanitized() throws {
        let json = #"""
        {"scheme":"https","host":"user:secret@api.example.com","port":8443,
         "path":"/v1/chat?api_key=sk-live-123","sanitized":"https://api.example.com/v1/chat?api_key=sk-live-123"}
        """#
        let endpoint = try HouseChatCoding.makeDecoder().decode(EndpointDescriptor.self, from: Data(json.utf8))
        #expect(endpoint.sanitized == "https://api.example.com:8443/v1/chat")
        #expect(endpoint.path == "/v1/chat")
        #expect(!endpoint.sanitized.contains("api_key"))
        #expect(!endpoint.sanitized.contains("secret"))

        // A receipt holding it cannot serialize the secret either.
        let receipt = RequestReceipt(endpoint: endpoint)
        let text = String(decoding: try HouseChatCoding.makeEncoder().encode(receipt), as: UTF8.self)
        for secret in ["api_key", "sk-live-123", "secret"] {
            #expect(!text.contains(secret), "leaked \(secret)")
        }

        // An endpoint with no usable authority decodes as an empty endpoint,
        // never as a partial leak and never as a decode failure.
        let unusable = try HouseChatCoding.makeDecoder().decode(
            EndpointDescriptor.self,
            from: Data(#"{"host":"","sanitized":"https://x"}"#.utf8)
        )
        #expect(unusable.isUsable == false)
        #expect(unusable.sanitized.isEmpty)
    }

    // MARK: P9 - bare cues never widen a grounded question

    @Test("A grounded question stays inside the conversation even with no literal 'this file'")
    func bareCueSuppressedBySourceMention() {
        let policy = ContextPolicy.standard
        let grounded: [(String, String)] = [
            ("in-document search, English", "search this file for revenue"),
            ("in-document search, implicit", "search for revenue"),
            ("timeliness, implicit", "latest revenue figure"),
            ("in-document search, explicit object", "Search the document for the word zebra"),
            ("timeliness word inside a source question", "What is the latest figure in this report?"),
            ("news word inside a source question", "Show me the news mentioned in the file"),
            ("in-document search, Chinese", "搜一下这份文件里的收入"),
            ("in-document search, Chinese implicit", "搜一下收入"),
            ("in-source lookup", "what does the file say about zebra"),
            ("look at the attachment", "look for the revenue figure in the attached sheet"),
        ]
        for (label, question) in grounded {
            let decision = policy.resolve(ContextRequest(
                hasCurrentSource: true,
                currentSourceCount: 1,
                question: question
            ))
            #expect(decision.allowsExternalRetrieval == false, "\(label): \(question)")
            #expect(decision.execution == .currentSource, "\(label) changed the internal scope")
        }

        // A mention of earlier turns is an internal lookup, not an outside one.
        let history = policy.resolve(ContextRequest(
            hasCurrentSource: true,
            historyTurnCount: 3,
            historyHasSources: true,
            question: "search the earlier discussion"
        ))
        #expect(history.allowsExternalRetrieval == false)
        #expect(history.execution == .currentSourceAndHistory)
    }

    @Test("A named outside target still widens, and ordinary chat still allows tools")
    func explicitExternalStillWidens() {
        let policy = ContextPolicy.standard

        let web = policy.resolve(ContextRequest(hasCurrentSource: true, question: "search the web for revenue"))
        #expect(web.allowsExternalRetrieval)
        #expect(web.intent.matchedTerms.contains("web"))

        let target = policy.resolve(ContextRequest(hasCurrentSource: true, question: "check the vault for the old numbers"))
        #expect(target.allowsExternalRetrieval)

        let chinese = policy.resolve(ContextRequest(hasCurrentSource: true, question: "上网查一下最新消息"))
        #expect(chinese.allowsExternalRetrieval)

        // A bare cue never widens while a source is present…
        let bare = policy.resolve(ContextRequest(hasCurrentSource: true, question: "What is the latest?"))
        #expect(bare.allowsExternalRetrieval == false)
        // …but ordinary chat with no source already allows the app's tools.
        let ordinary = policy.resolve(ContextRequest(hasCurrentSource: false, question: "search for revenue"))
        #expect(ordinary.allowsExternalRetrieval)

        // Overrides keep working.
        #expect(policy.resolve(ContextRequest(
            hasCurrentSource: true,
            question: "what does the file say",
            override: .broader
        )).allowsExternalRetrieval)
        #expect(policy.resolve(ContextRequest(
            hasCurrentSource: true,
            question: "search the web",
            override: .sourceOnly
        )).allowsExternalRetrieval == false)
    }

    // MARK: P5 - concurrent directory creation

    @Test("Concurrent stores from several archives never report an unsafe path")
    func concurrentDirectoryCreation() async throws {
        let temp = try TempDirectory(prefix: "concurrent-mkdir")
        let root = temp.appending("archive")
        let archives = try (0..<4).map { _ in try AttachmentArchive(root: root) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, archive) in archives.enumerated() {
                group.addTask {
                    for item in 0..<25 {
                        let data = Data("artifact \(index)-\(item)".utf8)
                        let ref = try await archive.store(data, kind: .extractedText)
                        #expect(try await archive.read(ref) == data)
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(try await archives[0].list().count == 100)
        for ref in try await archives[1].list() {
            #expect(try await archives[2].verify(ref) == .verified)
        }
    }

    // MARK: P13 - an existing root is tightened, ancestors are not touched

    @Test("A pre-existing 0755 root is narrowed to 0700; its parent is left alone")
    func existingRootIsTightened() async throws {
        let temp = try TempDirectory(prefix: "tighten")
        let parent = temp.appending("parent")
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        let root = parent.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        #expect(AtomicFile.permissions(of: root) == 0o755)

        let archive = try AttachmentArchive(root: root)
        let ref = try await archive.store(Data("payload".utf8), kind: .original)
        #expect(AtomicFile.permissions(of: root) == 0o700, "root was left world-readable")
        // The ancestor is not ours to change.
        #expect(AtomicFile.permissions(of: parent) == 0o755)
        let file = AttachmentArchive.fileURL(root: root, kind: ref.kind, sha256: ref.sha256)
        #expect(AtomicFile.permissions(of: file) == 0o600)
    }

    // MARK: P7 / P10d - the budget counts what is actually sent

    @Test("Selection character counts include the separators that join chunks")
    func selectionCountsSeparators() {
        let context = DocumentContext.standard
        let doc = Fixtures.longDocument(count: 4, factInLastSection: "zebra")
        let set = context.chunkSet(for: doc, attachmentID: "a1")

        // "section" appears in every section, so several chunks are kept.
        let selection = context.select(query: "section", in: set)
        #expect(selection.chunks.count > 1)
        #expect(selection.text.count == selection.characterCount)
        #expect(selection.characterCount > selection.chunks.reduce(0) { $0 + $1.text.count })
        #expect(selection.characterCount == selection.chunks.reduce(0) { $0 + $1.text.count }
            + 2 * (selection.chunks.count - 1))
    }

    @Test("A plan's joined text never exceeds its budget")
    func planBudgetCountsSeparators() {
        let context = DocumentContext.standard
        let documents = (0..<3).map { index in
            AttachmentDocument(
                attachmentID: "a\(index)",
                document: ExtractedDocument.flat(
                    kind: .text,
                    kindLabel: "Text",
                    name: "a\(index).txt",
                    text: String(repeating: "abcdefghij", count: 200)
                )
            )
        }
        let plan = context.select(query: "anything", documents: documents, budget: 2_500)

        #expect(plan.text.count <= 2_500, "joined text was \(plan.text.count) characters")
        #expect(plan.text.count == plan.totalCharacters)
        #expect(plan.truncatedByBudget)
        for selection in plan.ordered {
            #expect(selection.text.count == selection.characterCount)
        }
    }

    @Test("Free text can be scrubbed of credential-shaped content before storage")
    func secretRedactor() throws {
        let url = "provider rejected https://api.example.com/v1/chat?api_key=sk-live-123"
        let scrubbed = SecretRedactor.redact(url)
        #expect(!scrubbed.contains("sk-live-123"))
        #expect(!scrubbed.contains("?api_key"))
        #expect(scrubbed.contains("https://api.example.com/v1/chat"))

        #expect(SecretRedactor.redact("token=abc123456") == "token=[redacted]")
        #expect(SecretRedactor.redact("no secrets here") == "no secrets here")

        let authorization = SecretRedactor.redact("Authorization: Bearer sk-live-abc123")
        #expect(!authorization.contains("sk-live-abc123"))
        #expect(authorization.contains("[redacted]"))

        let inline = SecretRedactor.redact("a ghp_abcdefghijklmn b")
        #expect(!inline.contains("ghp_abcdefghijklmn"))
        #expect(SecretRedactor.containsCredentialShapedText(url))
        #expect(SecretRedactor.containsCredentialShapedText("nothing here") == false)

        // The helper a consumer calls before writing a receipt.
        let key = "sk-live-SUPERSECRET-123"
        let endpoint = try #require(EndpointDescriptor(url: URL(string: "https://api.example.com/v1/chat")!))
        let receipt = RequestReceipt(
            status: .failed,
            toolRounds: [ToolRound(calls: [ToolCall(
                name: "fetch",
                arguments: #"{"url":"https://x/y?token=\#(key)"}"#,
                resultSummary: "Bearer \(key)"
            )])],
            endpoint: endpoint,
            error: "provider rejected https://api.example.com/v1/chat?api_key=\(key)"
        )
        let raw = String(decoding: try HouseChatCoding.makeEncoder().encode(receipt), as: UTF8.self)
        #expect(raw.contains(key), "the fixture must actually carry the key")

        let stored = String(
            decoding: try HouseChatCoding.makeEncoder().encode(receipt.sanitizedForStorage()),
            as: UTF8.self
        )
        #expect(!stored.contains(key))
        #expect(!stored.contains("?api_key"))
        #expect(stored.contains("[redacted]"))
        // The typed endpoint never carried it in the first place.
        #expect(!String(decoding: try HouseChatCoding.makeEncoder().encode(endpoint), as: UTF8.self).contains("?"))
    }

    @Test("A plan's text is exactly the contributing selections joined, and nothing else")
    func planTextIsExact() {
        let context = DocumentContext.standard
        let first = ExtractedDocument.flat(
            kind: .text, kindLabel: "Text", name: "a.txt", text: String(repeating: "alpha ", count: 500))
        let second = ExtractedDocument.flat(
            kind: .text, kindLabel: "Text", name: "b.txt", text: String(repeating: "beta ", count: 500))
        let plan = context.select(query: "alpha beta", documents: [
            AttachmentDocument(attachmentID: "a", document: first),
            AttachmentDocument(attachmentID: "b", document: second),
        ], budget: 2_500)

        // One attachment takes the whole budget; the other contributes nothing.
        #expect(plan.contributing.count < plan.ordered.count)
        #expect(plan.contributing.map(\.text).joined(separator: "\n\n").count == plan.totalCharacters)
        #expect(plan.text.count == plan.totalCharacters)
        #expect(plan.totalCharacters <= 2_500)
    }

    // MARK: P8 - empty identity fails closed

    @Test("An empty identity fails closed, and saveIfAbsent refuses it")
    func emptyIdentityFailsClosed() async throws {
        let decoder = HouseChatCoding.makeDecoder()
        let cases = [
            #"{"id":"","turns":[]}"#,
            #"{"id":"c","turns":[{"id":"","role":"user","text":"hi"}]}"#,
            #"{"id":"c","turns":[{"id":"t","role":"user","text":"hi","attachments":[{"id":"","kind":"pdf","name":"a.pdf"}]}]}"#,
            #"{"id":"c","turns":[{"id":"t","role":"user","text":"hi","attachments":[{"id":"a","kind":"pdf","name":""}]}]}"#,
        ]
        for json in cases {
            #expect(throws: DecodingError.self, "\(json)") {
                try decoder.decode(ConversationRecord.self, from: Data(json.utf8))
            }
        }

        let temp = try TempDirectory(prefix: "empty-id")
        let archive = try ConversationArchive(root: temp.appending("chat"))
        await #expect(throws: ConversationArchiveError.invalidID("")) {
            try await archive.saveIfAbsent(ConversationRecord(id: ""))
        }
    }
}
