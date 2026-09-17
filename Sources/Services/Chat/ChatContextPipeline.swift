import Foundation
import HouseChatCore

/// Turns the retrieval decision plus a request's attachments into the exact
/// context the model receives.
///
/// Two jobs, both deterministic and local:
/// 1. **Scope.** `ContextDecision.execution` is enforced on the message
///    list: `.currentSource` keeps only the newest question's attachments,
///    `.history` drops that turn's, `.none` drops every attachment block.
/// 2. **Passages.** A document-backed source goes through
///    `HouseChatCore.DocumentContext`, so the model gets selected chunks
///    with their page/slide/sheet citations, an honest "nothing matched"
///    line, or an explicit partial/coverage line, inside the 200,000
///    per-attachment, 400,000 per-request, and model-window budgets.
enum ChatContextPipeline {
    /// The message list with out-of-scope attachment references removed.
    /// The saved chat is untouched: this is the request copy only.
    static func scopedMessages(_ messages: [QuickMessage], execution: String?) -> [QuickMessage] {
        guard let execution, let scope = RetrievalScope(rawValue: execution) else { return messages }
        guard let currentIndex = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        var result = messages
        for index in result.indices where result[index].role == .user {
            let keep: Bool
            switch scope {
            case .none: keep = false
            case .currentSource: keep = index == currentIndex
            case .history: keep = index != currentIndex
            case .currentSourceAndHistory: keep = true
            }
            if !keep { result[index].attachments = nil }
        }
        return result
    }

    /// The passage plan for the document-backed sources, in the caller's
    /// order. Sources without a shared extraction contribute text through
    /// the ordinary attachment path instead.
    static func plan(
        contents: [AttachmentContent],
        question: String,
        budget: Int,
        context: DocumentContext = .standard,
        policy: ContextPolicy = .standard
    ) -> SelectionPlan {
        let documents = contents.compactMap { content -> AttachmentDocument? in
            guard let document = content.extractedDocument else { return nil }
            return AttachmentDocument(attachmentID: content.ref.id.uuidString, document: document)
        }
        return context.select(
            query: question,
            documents: documents,
            budget: budget,
            intent: policy.classify(question)
        )
    }

    /// `[attachment id: rendered block]` for every document-backed source.
    static func blocks(
        contents: [AttachmentContent],
        question: String,
        budget: Int,
        context: DocumentContext = .standard,
        policy: ContextPolicy = .standard
    ) -> [UUID: String] {
        let plan = plan(contents: contents, question: question, budget: budget, context: context, policy: policy)
        var result: [UUID: String] = [:]
        for content in contents where content.extractedDocument != nil {
            guard let selection = plan.selections[content.ref.id.uuidString] else { continue }
            result[content.ref.id] = block(for: selection, content: content)
        }
        return result
    }

    /// One source's block body: cited passages, or the honest line for a
    /// no-match, an empty document, or a budget cut.
    static func block(for selection: ChunkSelection, content: AttachmentContent) -> String {
        let name = content.ref.name
        guard !selection.chunks.isEmpty else {
            switch selection.reason {
            case .noMatch:
                return "[No passage in \(name) matched the question. The file was searched and nothing matched; do not invent its contents.]"
            case .emptyDocument:
                return "[\(name) has no readable text.]"
            case .budgetExhausted:
                return "[\(selection.note ?? "No room left in the request budget for \(name).")]"
            case .wholeDocument, .rankedMatches, .distributedCoverage:
                return "[\(selection.note ?? "No passage from \(name) was included.")]"
            }
        }
        var lines: [String] = []
        for chunk in selection.chunks {
            let label = chunk.label.map { "\(name) · \($0)" } ?? name
            lines.append("[\(label)]")
            lines.append(chunk.text)
        }
        if !selection.isComplete {
            let coverage = selection.labels.isEmpty
                ? "a selection of passages"
                : selection.labels.joined(separator: ", ")
            let cut = selection.truncatedByBudget ? " The budget stopped the selection." : ""
            lines.append("[Partial: included \(coverage) of \(name).\(cut) This is not the whole document; say so if it matters.]")
        }
        return lines.joined(separator: "\n")
    }

    /// The passage budget for one request: the hard 400,000 per-request
    /// ceiling, the 200,000 per-attachment ceiling, and the answering
    /// model's own share, whichever is smallest.
    static func documentBudget(modelShare: Int, attachmentCount: Int) -> Int {
        let perAttachmentCeiling = AttachmentLimits.charactersPerAttachment * max(1, attachmentCount)
        return min(min(AttachmentLimits.charactersPerMessage, perAttachmentCeiling), modelShare)
    }
}
