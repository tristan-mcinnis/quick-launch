import Foundation
import Testing
@testable import HouseChatCore

@Suite("Document context")
struct DocumentContextTests {
    private let context = DocumentContext.standard

    private func document(
        _ name: String,
        sections: [DocumentSection],
        unit: DocumentUnit = .page
    ) -> ExtractedDocument {
        let text = sections.map(\.text).joined(separator: "\n\n")
        return ExtractedDocument(
            kind: .pdf,
            kindLabel: "PDF",
            name: name,
            sections: sections,
            sectionUnit: unit,
            unitCount: sections.count,
            characterCount: text.count,
            text: String(text.prefix(200_000))
        )
    }

    private func longSection(_ label: String, characters: Int, marker: String? = nil) -> DocumentSection {
        var text = "The regional market moved again this quarter. "
        text += String(repeating: "filler words about the market and the region. ", count: 20)
        if text.count < characters {
            text += String(repeating: "x", count: characters - text.count)
        }
        if let marker { text += " \(marker)." }
        return DocumentSection(label: label, unit: .page, text: text)
    }

    @Test("A short document is kept whole and marked complete")
    func shortDocumentWhole() {
        let doc = ExtractedDocument.flat(kind: .text, kindLabel: "Text", name: "notes.txt", text: "Revenue rose in the coastal region.")
        let set = context.chunkSet(for: doc, attachmentID: "a1")
        #expect(set.isWholeDocument)
        #expect(set.chunks.count == 1)

        let selection = context.select(query: "revenue", in: set)
        #expect(selection.isComplete)
        #expect(selection.matched)
        #expect(selection.reason == .wholeDocument)
        #expect(selection.characterCount == doc.text?.count)
        #expect(selection.text.contains("Revenue rose"))
    }

    @Test("A fact at the very end of a long document is found")
    func tailFactIsFound() {
        let doc = Fixtures.longDocument(count: 30, factInLastSection: "zebra")
        let set = context.chunkSet(for: doc, attachmentID: "a1")
        #expect(!set.isWholeDocument)
        #expect(set.chunks.count == 30)

        let selection = context.select(query: "zebra", in: set)
        #expect(selection.matched)
        #expect(selection.reason == .rankedMatches)
        #expect(selection.chunks.count == 1)
        #expect(selection.chunks[0].label == "Page 30")
        #expect(selection.text.contains("unique tail fact is zebra"))
    }

    @Test("A question with no lexical match returns nothing and says so")
    func noMatchIsHonest() {
        let doc = Fixtures.longDocument(count: 10)
        let selection = context.select(query: "hippopotamus", in: context.chunkSet(for: doc, attachmentID: "a1"))

        #expect(selection.matched == false)
        #expect(selection.reason == .noMatch)
        #expect(selection.chunks.isEmpty)
        #expect(selection.characterCount == 0)
        #expect(selection.note?.contains("No passage") == true)
    }

    @Test("A broad question spreads labelled coverage across the whole document")
    func broadSummaryDistributes() {
        let doc = Fixtures.longDocument(count: 30)
        let set = context.chunkSet(for: doc, attachmentID: "a1")
        let selection = context.select(
            query: "summarize the document",
            in: set,
            intent: QuestionIntent(asksForBroadSummary: true)
        )

        #expect(selection.matched)
        #expect(selection.reason == .distributedCoverage)
        #expect(selection.chunks.count == DocumentContext.Configuration.default.maximumChunksPerAttachment)
        #expect(selection.labels.first == "Page 1")
        #expect(selection.labels.last == "Page 30")
        // Distributed, so the middle of the document is represented.
        #expect(selection.chunks.map(\.index) == selection.chunks.map(\.index).sorted())
    }

    @Test("At most twelve chunks come from one attachment")
    func capsChunksPerAttachment() {
        let doc = Fixtures.longDocument(count: 40, factInLastSection: "zebra")
        let set = context.chunkSet(for: doc, attachmentID: "a1")
        let ranked = context.select(query: "section", in: set)
        #expect(ranked.chunks.count <= 12)

        let broad = context.select(query: "x", in: set, intent: QuestionIntent(asksForBroadSummary: true))
        #expect(broad.chunks.count == 12)
    }

    @Test("Chunks overlap, so a fact on a boundary lands in one of them")
    func overlapCatchesBoundaryFact() {
        let text = String(repeating: "a", count: 1_950) + " zebra " + String(repeating: "b", count: 2_000)
        let doc = document("long.pdf", sections: [DocumentSection(label: "Page 1", unit: .page, text: text)])
        let set = context.chunkSet(for: doc, attachmentID: "a1")
        #expect(set.chunks.count >= 2)
        #expect(set.chunks[0].endCharacter - set.chunks[1].startCharacter == 200)

        let selection = context.select(query: "zebra", in: set)
        #expect(selection.chunks.count == 2)
        #expect(selection.chunks.allSatisfy { $0.text.contains("zebra") })
    }

    @Test("Two attachments share one request budget, and the cut is reported")
    func totalBudgetAcrossAttachments() {
        let first = ExtractedDocument.flat(kind: .text, kindLabel: "Text", name: "a.txt", text: String(repeating: "a", count: 1_500))
        let second = ExtractedDocument.flat(kind: .text, kindLabel: "Text", name: "b.txt", text: String(repeating: "b", count: 1_500))

        let plan = context.select(
            query: "anything",
            documents: [
                AttachmentDocument(attachmentID: "a", document: first),
                AttachmentDocument(attachmentID: "b", document: second),
            ],
            budget: 2_000
        )

        #expect(plan.order == ["a", "b"])
        #expect(plan.selections["a"]?.characterCount == 1_500)
        #expect(plan.selections["a"]?.truncatedByBudget == false)
        #expect(plan.selections["b"]?.truncatedByBudget == true)
        #expect(plan.totalCharacters <= 2_000)
        #expect(plan.truncatedByBudget)
    }

    @Test("A zero budget returns nothing rather than overshooting")
    func zeroBudget() {
        let doc = Fixtures.longDocument(count: 5)
        let set = context.chunkSet(for: doc, attachmentID: "a1")
        let selection = context.select(query: "zebra", in: set, budget: 0)
        #expect(selection.chunks.isEmpty)
        #expect(selection.reason == .budgetExhausted)
        #expect(selection.truncatedByBudget)
    }

    @Test("CJK matching works on bigrams")
    func cjkBigrams() {
        var sections: [DocumentSection] = []
        for index in 1...4 {
            var text = "本季度区域市场表现良好。"
            text += String(repeating: "区域市场数据分析报告内容。", count: 60)
            if index == 4 { text += " 季度报告显示收入增长。" }
            sections.append(DocumentSection(label: "页 \(index)", unit: .page, text: text))
        }
        let doc = document("报表.pdf", sections: sections)
        let set = context.chunkSet(for: doc, attachmentID: "a1")
        #expect(!set.isWholeDocument)

        let hit = context.select(query: "收入增长", in: set)
        #expect(hit.matched)
        #expect(hit.text.contains("收入增长"))

        let miss = context.select(query: "利润下滑", in: set)
        #expect(miss.matched == false)
        #expect(miss.reason == .noMatch)
    }

    @Test("Tokens are lowercased words and CJK bigrams")
    func tokenization() {
        #expect(DocumentContext.tokens(of: "Revenue Growth in Q3") == ["revenue", "growth", "in", "q3"])
        #expect(DocumentContext.tokens(of: "a i") == [])
        #expect(DocumentContext.tokens(of: "收入增长") == ["收入", "入增", "增长"])
        #expect(DocumentContext.tokens(of: "中文") == ["中文"])
        #expect(DocumentContext.tokens(of: "季度报告显示") == ["季度", "度报", "报告", "告显", "显示"])
    }

    @Test("Chunk labels and IDs come from the document's own sections")
    func labelsAndIDs() {
        let doc = Fixtures.longDocument(count: 3, sectionCharacters: 1_500)
        let set = context.chunkSet(for: doc, attachmentID: "report")
        #expect(set.chunks.map(\.label) == ["Page 1", "Page 2", "Page 3"])
        #expect(set.chunks.map(\.id) == ["report#0", "report#1", "report#2"])
        #expect(set.chunks.allSatisfy { $0.attachmentID == "report" })
    }

    @Test("A section longer than the chunk size is split into labelled parts")
    func splitSectionParts() {
        let text = String(repeating: "words ", count: 1_000)
        let doc = document("long.pdf", sections: [DocumentSection(label: "Page 1", unit: .page, text: text)])
        let set = context.chunkSet(for: doc, attachmentID: "a1")
        #expect(set.chunks.count > 1)
        #expect(set.chunks[0].label == "Page 1 · part 1 of \(set.chunks.count)")
        #expect(set.chunks[1].label == "Page 1 · part 2 of \(set.chunks.count)")
    }

    @Test("A document with no readable text selects nothing")
    func emptyDocument() {
        let doc = ExtractedDocument(kind: .text, kindLabel: "Text", name: "empty.txt")
        let set = context.chunkSet(for: doc, attachmentID: "a1")
        #expect(set.chunks.isEmpty)

        let selection = context.select(query: "anything", in: set)
        #expect(selection.reason == .emptyDocument)
        #expect(selection.matched == false)
        #expect(selection.note?.contains("No readable text") == true)
    }

    @Test("Chunking one document twice gives identical chunks")
    func deterministic() {
        let doc = Fixtures.longDocument(count: 12)
        let first = context.chunkSet(for: doc, attachmentID: "a1")
        let second = context.chunkSet(for: doc, attachmentID: "a1")
        #expect(first.chunks == second.chunks)

        let query = "market movements"
        #expect(context.select(query: query, in: first).chunks == context.select(query: query, in: second).chunks)
    }
}
