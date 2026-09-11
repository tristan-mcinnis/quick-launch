import CryptoKit
import Foundation
import Testing
@testable import QuickLaunch

/// The attachment seam in the chat history: a question keeps references to
/// what was attached, never the extracted text, and history written before
/// attachments still loads.
@Suite("Quick message coding")
struct QuickMessageCodingTests {
    private func freshFile() -> (folder: URL, file: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "quick-launch-message-coding-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, folder.appending(path: QuickHistoryStore.fileName))
    }

    private static let addedAt = Date(timeIntervalSinceReferenceDate: 779_000_000)

    private static func sampleRefs() -> [ChatAttachmentRef] {
        [
            ChatAttachmentRef(
                kind: .pdf,
                name: "Q3 report.pdf",
                byteCount: 1_258_291,
                pageCount: 42,
                characterCount: 612_000,
                truncation: AttachmentTruncation(
                    keptCharacters: 200_000,
                    totalCharacters: 612_000,
                    unit: .page,
                    keptUnits: 120,
                    totalUnits: 300
                ),
                contentHash: String(repeating: "ab", count: 32),
                extractorVersion: 1,
                path: "/tmp/example/Documents/Q3 report.pdf",
                addedAt: addedAt
            ),
            ChatAttachmentRef(
                kind: .link,
                name: "Pricing | Example",
                byteCount: 48_213,
                characterCount: 9_120,
                contentHash: String(repeating: "cd", count: 32),
                extractorVersion: 1,
                url: URL(string: "https://example.com/pricing"),
                addedAt: addedAt
            ),
            ChatAttachmentRef(
                kind: .screenshot,
                name: "Screenshot",
                pixelWidth: 1_944,
                pixelHeight: 1_464,
                addedAt: addedAt
            ),
        ]
    }

    // MARK: History written before attachments

    /// A chat-history.json as v1.4 wrote it: the schema envelope, a question
    /// and an answer, no `attachments` and no `toolRecords` keys.
    private static let historyBeforeAttachments = """
    {
      "schemaVersion": 1,
      "payload": [
        {
          "id": "6F2C1D0E-2B9A-4C11-9E7B-1C5D2A3B4C5D",
          "createdAt": 779000000,
          "updatedAt": 779000060,
          "providerID": "A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF",
          "model": "deepseek-v4-flash",
          "isPinned": false,
          "messages": [
            {
              "id": "11111111-2222-4333-8444-555555555555",
              "role": "user",
              "content": "What is in the Q3 report?"
            },
            {
              "id": "66666666-7777-4888-8999-AAAAAAAAAAAA",
              "role": "assistant",
              "content": "Revenue grew 12 percent."
            }
          ]
        }
      ]
    }
    """

    @Test func historyWithoutAttachmentsLoads() throws {
        let (folder, file) = freshFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(Self.historyBeforeAttachments.utf8).write(to: file)

        let loaded = QuickHistoryStore.load(from: file, migratingFrom: nil)

        let conversation = try #require(loaded.first)
        #expect(loaded.count == 1)
        #expect(conversation.messages.map(\.content) == ["What is in the Q3 report?", "Revenue grew 12 percent."])
        #expect(conversation.messages.allSatisfy { $0.attachments == nil })
        #expect(conversation.messages.allSatisfy { $0.attachmentRefs.isEmpty })
    }

    @Test func bareMessageWithoutAttachmentsDecodes() throws {
        let json = #"{"id":"11111111-2222-4333-8444-555555555555","role":"user","content":"Hello"}"#
        let message = try JSONDecoder().decode(QuickMessage.self, from: Data(json.utf8))

        #expect(message.content == "Hello")
        #expect(message.attachments == nil)
        #expect(message.attachmentRefs.isEmpty)
    }

    @Test func messageWithoutAttachmentsWritesNoKey() throws {
        let message = QuickMessage(role: .user, content: "Hello")
        let json = try #require(String(data: JSONEncoder().encode(message), encoding: .utf8))

        #expect(!json.contains("attachments"))
    }

    // MARK: Round trip

    @Test func messageWithAttachmentsRoundTrips() throws {
        let message = QuickMessage(role: .user, content: "Compare these", attachments: Self.sampleRefs())

        let decoded = try JSONDecoder().decode(QuickMessage.self, from: JSONEncoder().encode(message))

        #expect(decoded == message)
        #expect(decoded.attachmentRefs.map(\.kind) == [.pdf, .link, .screenshot])
        #expect(decoded.attachmentRefs[0].truncation?.keptUnits == 120)
        #expect(decoded.attachmentRefs[1].url?.absoluteString == "https://example.com/pricing")
        #expect(decoded.attachmentRefs[1].host == "example.com")
        #expect(decoded.attachmentRefs[2].pixelWidth == 1_944)
    }

    @Test func chatWithAttachmentsRoundTripsThroughTheHistoryFile() throws {
        let (folder, file) = freshFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = QuickConversation(
            createdAt: Self.addedAt,
            updatedAt: Self.addedAt,
            providerID: InferenceProvider.deepSeekID,
            model: "deepseek-v4-flash",
            messages: [
                QuickMessage(role: .user, content: "Compare these", attachments: Self.sampleRefs()),
                QuickMessage(role: .assistant, content: "The report is longer."),
            ]
        )

        QuickHistoryStore.save([conversation], limit: 20, to: file)
        QuickHistoryStore.waitForPendingWrites()
        let loaded = QuickHistoryStore.load(from: file, migratingFrom: nil)

        #expect(loaded == [conversation])
        #expect(loaded.first?.messages.last?.attachments == nil)
    }

    // MARK: No extracted text in history

    @Test func extractedTextNeverReachesTheHistoryFile() throws {
        let (folder, file) = freshFile()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sentinel = "SENTINEL-7Q3-the-margin-fell-in-August"
        let body = String(repeating: "Quarterly revenue and cost detail. ", count: 1_500)
        let text = String((sentinel + " " + body).prefix(50_000))
        #expect(text.count == 50_000)
        let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let ref = ChatAttachmentRef(
            kind: .pdf,
            name: "Q3 report.pdf",
            byteCount: 1_258_291,
            pageCount: 42,
            characterCount: text.count,
            contentHash: hash,
            extractorVersion: 1,
            path: "/tmp/example/Documents/Q3 report.pdf",
            addedAt: Self.addedAt
        )
        let conversation = QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "deepseek-v4-flash",
            messages: [
                QuickMessage(role: .user, content: "Summarise the report", attachments: [ref]),
                QuickMessage(role: .assistant, content: "Revenue grew."),
            ]
        )

        QuickHistoryStore.save([conversation], limit: 20, to: file)
        QuickHistoryStore.waitForPendingWrites()
        let data = try Data(contentsOf: file)
        let stored = try #require(String(data: data, encoding: .utf8))

        #expect(data.count < 2_048)
        #expect(!stored.contains(sentinel))
        #expect(!stored.contains("Quarterly revenue"))
        #expect(stored.contains("Q3 report.pdf"))
        #expect(stored.contains(hash))
    }

    // MARK: Images keep no source

    @Test func imageReferenceDropsEverySourceField() {
        for kind in [ChatAttachmentKind.image, .screenshot] {
            let ref = ChatAttachmentRef(
                kind: kind,
                name: "Screenshot",
                contentHash: String(repeating: "ef", count: 32),
                extractorVersion: 1,
                path: "/tmp/example/Desktop/Screenshot.png",
                url: URL(string: "https://example.com/shot.png"),
                pixelWidth: 1_944,
                pixelHeight: 1_464
            )

            #expect(ref.contentHash == nil)
            #expect(ref.extractorVersion == nil)
            #expect(ref.path == nil)
            #expect(ref.url == nil)
            #expect(ref.pixelWidth == 1_944)
            #expect(ref.pixelHeight == 1_464)
        }
    }

    @Test func storedImageReferenceLoadsWithoutItsPath() throws {
        let json = """
        {"id":"11111111-2222-4333-8444-555555555555","kind":"image","name":"Photo",
         "path":"/tmp/example/Desktop/photo.png","contentHash":"abc","extractorVersion":1,
         "url":"https://example.com/photo.png","pixelWidth":800,"pixelHeight":600,"addedAt":779000000}
        """
        let ref = try JSONDecoder().decode(ChatAttachmentRef.self, from: Data(json.utf8))
        let reencoded = try #require(String(data: JSONEncoder().encode(ref), encoding: .utf8))

        #expect(ref.path == nil)
        #expect(ref.contentHash == nil)
        #expect(ref.url == nil)
        #expect(ref.pixelWidth == 800)
        #expect(!reencoded.contains("photo.png"))
    }

    @Test func documentReferenceKeepsItsSource() {
        let ref = ChatAttachmentRef(
            kind: .word,
            name: "Brief.docx",
            contentHash: "abc",
            extractorVersion: 1,
            path: "/tmp/example/Brief.docx"
        )

        #expect(ref.contentHash == "abc")
        #expect(ref.extractorVersion == 1)
        #expect(ref.path == "/tmp/example/Brief.docx")
        #expect(ref.host == nil)
    }

    @Test func onlyImagesAndScreenshotsAreImages() {
        let images = ChatAttachmentKind.allCases.filter(\.isImage)
        #expect(images == [.image, .screenshot])
    }

    // MARK: Truncation lines

    @Test(arguments: [
        (
            AttachmentTruncation(keptCharacters: 200_000, totalCharacters: 612_000, unit: .page, keptUnits: 120, totalUnits: 300),
            "first 200,000 of 612,000 characters, pages 1-120 of 300"
        ),
        (AttachmentTruncation(keptCharacters: 200_000, totalCharacters: 612_000), "first 200,000 of 612,000 characters"),
        (AttachmentTruncation(keptCharacters: 100_000), "first 100,000 characters"),
        (AttachmentTruncation(unit: .slide, keptUnits: 300, totalUnits: 412), "slides 1-300 of 412"),
        (AttachmentTruncation(unit: .row, keptUnits: 5_000, totalUnits: 12_345), "rows 1-5,000 of 12,345"),
        (AttachmentTruncation(unit: .sheet, keptUnits: 10), "sheets 1-10"),
    ])
    func truncationSummary(truncation: AttachmentTruncation, expected: String) {
        #expect(truncation.summary == expected)
    }

    @Test func truncationModelNote() {
        let cut = AttachmentTruncation(keptCharacters: 200_000, totalCharacters: 612_000, unit: .page, keptUnits: 120, totalUnits: 300)

        #expect(cut.modelNote == "[Truncated: the first 200,000 of 612,000 characters, pages 1-120 of 300.]")
        #expect(AttachmentTruncation().modelNote == "[Truncated.]")
    }

    // MARK: Limits

    @Test func limitsMatchTheSpec() {
        #expect(AttachmentLimits.attachmentsPerMessage == 10)
        #expect(AttachmentLimits.imagesPerMessage == 6)
        #expect(AttachmentLimits.finderSelectionFiles == 20)
        #expect(AttachmentLimits.documentBytes == 50 * 1_024 * 1_024)
        #expect(AttachmentLimits.imageBytes == ClipboardImageReader.maximumBytes)
        #expect(AttachmentLimits.textFileBytes == 5 * 1_024 * 1_024)
        #expect(AttachmentLimits.charactersPerAttachment == 200_000)
        #expect(AttachmentLimits.charactersPerMessage == 400_000)
        #expect(AttachmentLimits.pdfPages == 300)
        #expect(AttachmentLimits.ocrPages == 10)
        #expect(AttachmentLimits.slides == 300)
        #expect(AttachmentLimits.sheets == 10)
        #expect(AttachmentLimits.rowsPerSheet == 5_000)
        #expect(AttachmentLimits.columnsPerSheet == 100)
        #expect(AttachmentLimits.zipEntries == 5_000)
        #expect(AttachmentLimits.zipEntryOutputBytes == 16 * 1_024 * 1_024)
        #expect(AttachmentLimits.zipArchiveOutputBytes == 64 * 1_024 * 1_024)
        #expect(AttachmentLimits.zipDeclaredRatio == 200)
        #expect(AttachmentLimits.extractionTimeout == .seconds(20))
        #expect(AttachmentLimits.linkBodyBytes == 5 * 1_024 * 1_024)
        #expect(AttachmentLimits.linkTotalTimeout == .seconds(15))
        #expect(AttachmentLimits.charactersPerLink == 100_000)
        #expect(AttachmentLimits.contextShare == 0.6)
        #expect(AttachmentLimits.headExcerptCharacters == 4_000)
        #expect(AttachmentLimits.cacheLifetime == .seconds(7 * 24 * 3_600))
        #expect(AttachmentLimits.cacheBytes == 100 * 1_024 * 1_024)
    }
}
