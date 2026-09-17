import Foundation
@testable import HouseChatCore

/// A temporary directory that cleans itself up when the test ends.
final class TempDirectory {
    let url: URL

    init(prefix: String = "house-chat-core") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func appending(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: false)
    }
}

enum Fixtures {
    static let english = "The quarterly report shows revenue growth in the coastal region."
    static let chinese = "季度报告显示沿海地区的收入增长。"

    static func conversation(id: String = "conversation-1") -> ConversationRecord {
        let original = ArtifactRef(kind: .original, sha256: String(repeating: "a", count: 64), byteCount: 12, fileExtension: "pdf")
        let text = ArtifactRef(kind: .extractedText, sha256: String(repeating: "b", count: 64), byteCount: 40, fileExtension: "txt")
        let attachment = AttachmentRecord(
            id: "attachment-1",
            kind: .pdf,
            name: "report.pdf",
            byteCount: 12,
            pageCount: 3,
            characterCount: 40,
            truncation: TextTruncation(keptCharacters: 40, totalCharacters: 40, unit: .page, keptUnits: 3, totalUnits: 3),
            contentHash: String(repeating: "a", count: 64),
            extractorVersion: 1,
            path: "/tmp/report.pdf",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            artifacts: AttachmentArtifacts(original: original, extractedText: text)
        )
        let toolRound = ToolRound(
            id: "round-1",
            index: 0,
            calls: [ToolCall(id: "call-1", name: "search_vault", arguments: #"{"query":"revenue"}"#, resultSummary: "2 notes", status: .succeeded, durationSeconds: 0.4)],
            status: .succeeded,
            startedAt: Date(timeIntervalSince1970: 1_700_000_001),
            durationSeconds: 0.4
        )
        let receipt = RequestReceipt(
            id: "request-1",
            selection: ModelSelection(
                chosen: ModelChoice(provider: "deepseek", model: "deepseek-chat", thinking: "medium"),
                effective: ModelChoice(provider: "deepseek", model: "deepseek-reasoner", thinking: "high")
            ),
            status: .completed,
            context: ContextReceipt(
                scope: .currentSource,
                sourceFirst: true,
                historyIncluded: false,
                budgetCharacters: 400_000,
                sourceCharacters: 40,
                coverageLabels: ["Page 1"],
                matched: true,
                complete: true,
                rationale: "source-first"
            ),
            attachmentRefs: [AttachmentSnapshotRef(
                attachmentID: "attachment-1",
                contentHash: String(repeating: "a", count: 64),
                snapshotHash: String(repeating: "b", count: 64),
                kind: "extractedText",
                byteCount: 12,
                characterCount: 40
            )],
            toolRounds: [toolRound],
            timings: RequestTimings(totalSeconds: 3.2, firstTokenSeconds: 0.6, toolSeconds: 0.4, retries: 0),
            usage: TokenUsage(inputTokens: 1_200, outputTokens: 340, totalTokens: 1_540),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_003)
        )
        let userTurn = TurnRecord(
            id: "turn-1",
            role: .user,
            text: "What does the report say?",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            attachments: [attachment],
            model: receipt.selection,
            request: receipt,
            timings: TurnTimings(extractionSeconds: 0.2, totalSeconds: 3.4)
        )
        let assistantTurn = TurnRecord(
            id: "turn-2",
            role: .assistant,
            text: "It reports revenue growth.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_003),
            model: ModelSelection(ModelChoice(provider: "deepseek", model: "deepseek-reasoner", thinking: "high")),
            toolRounds: [toolRound],
            timings: TurnTimings(firstTokenSeconds: 0.6, totalSeconds: 3.2)
        )
        return ConversationRecord(
            id: id,
            surface: .quickLaunch,
            title: "Revenue",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_003),
            sessionLinks: [SessionLink(kind: "ql-window", id: "window-1", label: "Quick AI")],
            turns: [userTurn, assistantTurn],
            appVersion: "1.2.3"
        )
    }

    /// A document with `count` sections of `sectionCharacters` characters,
    /// each with a unique marker, so chunking and ranking are observable.
    static func longDocument(
        name: String = "report.pdf",
        count: Int = 30,
        sectionCharacters: Int = 1_500,
        factInLastSection: String = "zebra"
    ) -> ExtractedDocument {
        var sections: [DocumentSection] = []
        for index in 1...count {
            var body = "Section \(index) discusses the regional market and its movements in detail. "
            body += String(repeating: "filler words about the market and the region. ", count: 20)
            if body.count < sectionCharacters {
                body += String(repeating: "x", count: sectionCharacters - body.count)
            }
            if index == count {
                body += " The unique tail fact is \(factInLastSection)."
            }
            sections.append(DocumentSection(
                label: "Page \(index)",
                unit: .page,
                index: index,
                range: DocumentRange(start: index, end: index),
                text: body
            ))
        }
        let total = sections.reduce(0) { $0 + $1.text.count }
        return ExtractedDocument(
            kind: .pdf,
            kindLabel: "PDF",
            name: name,
            sections: sections,
            sectionUnit: .page,
            unitCount: count,
            contentHash: String(repeating: "c", count: 64),
            byteCount: 1_000,
            characterCount: total,
            text: String(sections.map(\.text).joined(separator: "\n\n").prefix(200_000))
        )
    }
}
