import Testing
import Foundation
import HouseChatCore
@testable import QuickLaunch

/// The request pipeline: execution scope enforcement and DocumentContext
/// passage selection with citations, no-match, and partial coverage.
@Suite("Chat context pipeline")
struct ChatContextPipelineTests {
    private func ref(name: String = "report.txt", characters: Int = 100) -> ChatAttachmentRef {
        ChatAttachmentRef(
            kind: .text,
            name: name,
            byteCount: 100,
            characterCount: characters,
            contentHash: SHA256Digest.hex(name)
        )
    }

    private func message(_ text: String, refs: [ChatAttachmentRef]) -> QuickMessage {
        QuickMessage(role: .user, content: text, attachments: refs.isEmpty ? nil : refs)
    }

    private func document(_ text: String, name: String = "report.txt", unit: DocumentUnit? = nil) -> ExtractedDocument {
        ExtractedDocument(
            kind: .text,
            kindLabel: "Text file",
            name: name,
            sections: [DocumentSection(label: unit == nil ? nil : "Page 1", unit: unit, text: text)],
            characterCount: text.count,
            text: text
        )
    }

    // MARK: - Scope enforcement

    @Test func currentSourceDropsEarlierTurnsAttachments() {
        let early = ref(name: "early.txt")
        let current = ref(name: "current.txt")
        let messages = [
            message("first", refs: [early]),
            QuickMessage(role: .assistant, content: "ok"),
            message("second", refs: [current]),
        ]
        let scoped = ChatContextPipeline.scopedMessages(messages, execution: "currentSource")
        #expect(scoped[0].attachmentRefs.isEmpty, "an earlier turn's file is out of scope")
        #expect(scoped[2].attachmentRefs.map(\.name) == ["current.txt"])
    }

    @Test func historyDropsTheCurrentTurnsAttachments() {
        let early = ref(name: "early.txt")
        let current = ref(name: "current.txt")
        let messages = [message("first", refs: [early]), message("second", refs: [current])]
        let scoped = ChatContextPipeline.scopedMessages(messages, execution: "history")
        #expect(scoped[0].attachmentRefs.map(\.name) == ["early.txt"])
        #expect(scoped[1].attachmentRefs.isEmpty, "history-only excludes the current source")
    }

    @Test func noneDropsEveryAttachmentBlock() {
        let messages = [message("first", refs: [ref()]), message("second", refs: [ref(name: "b.txt")])]
        let scoped = ChatContextPipeline.scopedMessages(messages, execution: "none")
        #expect(scoped.allSatisfy { $0.attachmentRefs.isEmpty })
    }

    @Test func bothCorporaKeepEveryAttachment() {
        let messages = [message("first", refs: [ref()]), message("second", refs: [ref(name: "b.txt")])]
        let scoped = ChatContextPipeline.scopedMessages(messages, execution: "currentSourceAndHistory")
        #expect(scoped[0].attachmentRefs.map(\.name) == ["report.txt"])
        #expect(scoped[1].attachmentRefs.map(\.name) == ["b.txt"])
    }

    @Test func anAbsentExecutionLeavesTheMessagesAlone() {
        let messages = [message("first", refs: [ref()])]
        #expect(ChatContextPipeline.scopedMessages(messages, execution: nil)[0].attachmentRefs.count == 1)
    }

    // MARK: - Budget

    @Test func theRequestBudgetIsCappedByFileAndRequestCeilings() {
        // One attachment can contribute at most its own 200k ceiling; two or
        // more reach the 400k request ceiling; the model share always wins.
        #expect(ChatContextPipeline.documentBudget(modelShare: 5_000_000, attachmentCount: 1) == 200_000)
        #expect(ChatContextPipeline.documentBudget(modelShare: 5_000_000, attachmentCount: 2) == 400_000)
        #expect(ChatContextPipeline.documentBudget(modelShare: 5_000_000, attachmentCount: 5) == 400_000)
        #expect(ChatContextPipeline.documentBudget(modelShare: 10_000, attachmentCount: 2) == 10_000)
        #expect(ChatContextPipeline.documentBudget(modelShare: .max, attachmentCount: 3) == 400_000)
    }

    // MARK: - Passage selection

    @Test func aTailFactIsSelectedAndCited() {
        // Far longer than one chunk, with a distinctive fact at the tail.
        let body = String(repeating: "The quarterly revenue grew across every region in the period. ", count: 200)
            + " UNIQUE_TAIL_FACT the warranty reserve doubled. "
        let content = AttachmentContent(
            ref: ref(name: "report.txt", characters: body.count),
            text: body,
            extractedDocument: document(body)
        )
        let blocks = ChatContextPipeline.blocks(
            contents: [content],
            question: "What happened to the warranty reserve?",
            budget: 400_000
        )
        let block = blocks[content.ref.id]
        #expect(block != nil, "a document-backed source contributes a passage block")
        #expect(block?.contains("UNIQUE_TAIL_FACT") == true, "the tail fact is selected, not just the head")
        #expect(block?.contains("[report.txt") == true, "every passage carries its citation")
    }

    @Test func aQuestionWithNoMatchIsHonest() {
        // Long enough to be chunked, so a real lexical search runs and fails.
        let body = String(repeating: "bananas oranges apples pears ", count: 150)
        let content = AttachmentContent(
            ref: ref(name: "report.txt", characters: body.count),
            text: body,
            extractedDocument: document(body)
        )
        let blocks = ChatContextPipeline.blocks(
            contents: [content],
            question: "quantum telemetry calibration",
            budget: 400_000
        )
        let block = blocks[content.ref.id]
        #expect(block?.contains("No passage") == true)
        #expect(block?.contains("do not invent") == true)
    }

    @Test func aPartialSelectionSaysSo() {
        let selection = ChunkSelection(
            attachmentID: "a1",
            name: "deck.pdf",
            chunks: [DocumentChunk(id: "a1#0", attachmentID: "a1", index: 0, text: "page one", label: "Page 1")],
            labels: ["Page 1"],
            isComplete: false,
            matched: true,
            reason: .budgetExhausted,
            truncatedByBudget: true
        )
        let content = AttachmentContent(ref: ref(name: "deck.pdf"), text: nil)
        let block = ChatContextPipeline.block(for: selection, content: content)
        #expect(block.contains("page one"))
        #expect(block.contains("Partial"))
        #expect(block.contains("not the whole document"))
    }

    @Test func aShortDocumentIsKeptWholeAndComplete() {
        let content = AttachmentContent(
            ref: ref(name: "note.txt", characters: 40),
            text: "the answer is forty two",
            extractedDocument: document("the answer is forty two", name: "note.txt")
        )
        let blocks = ChatContextPipeline.blocks(contents: [content], question: "what is the answer?", budget: 400_000)
        let block = blocks[content.ref.id]
        #expect(block?.contains("the answer is forty two") == true)
        #expect(block?.contains("Partial") == false, "a whole short document is not partial")
    }
}
