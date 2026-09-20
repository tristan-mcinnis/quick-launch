import Testing
import Foundation
import HouseChatCore
@testable import QuickLaunch

/// The context gate. Since 2026-09-20 it withholds nothing: every enabled
/// tool is offered whatever the sources, so the model makes the call. What
/// the policy still decides is `allowsExternalRetrieval`, which names the
/// scope on the persisted receipt, and `grounded`, which adds the grounding
/// sentence to the system prompt. Attachment scoping, not the tool set, is
/// what keeps "summarise this file" on the file.
@Suite("Chat context gate")
struct ChatContextGateTests {
    private let gate = ChatContextGate.standard
    private let everyTool = Set(ChatToolKind.allCases)

    @Test func aCurrentSourceStillOffersEveryTool() {
        let evaluation = gate.evaluate(
            enabledTools: everyTool,
            hasCurrentSource: true,
            currentSourceCount: 1,
            historyTurnCount: 0,
            historyHasSources: false,
            question: "What does this file say about revenue?"
        )
        // The decision still records that the request is grounded ...
        #expect(!evaluation.allowsExternalRetrieval)
        #expect(evaluation.grounded)
        // ... but nothing is taken away from the model.
        #expect(evaluation.gatedTools == everyTool)
        #expect(evaluation.execution == "currentSource")
    }

    @Test func explicitWebWordingLiftsTheHold() {
        let evaluation = gate.evaluate(
            enabledTools: [.web, .vault],
            hasCurrentSource: true,
            currentSourceCount: 1,
            historyTurnCount: 0,
            historyHasSources: false,
            question: "search the web for the latest filing"
        )
        #expect(evaluation.allowsExternalRetrieval)
        #expect(evaluation.gatedTools == [.web, .vault])
    }

    @Test func aFollowUpOnAGroundedHistoryKeepsItsTools() {
        let evaluation = gate.evaluate(
            enabledTools: everyTool,
            hasCurrentSource: false,
            currentSourceCount: 0,
            historyTurnCount: 4,
            historyHasSources: true,
            question: "and what does the second table show?"
        )
        #expect(!evaluation.allowsExternalRetrieval)
        #expect(evaluation.grounded)
        #expect(evaluation.gatedTools == everyTool)
        #expect(evaluation.execution == "history")
    }

    @Test func ordinaryChatAllowsEveryTool() {
        let evaluation = gate.evaluate(
            enabledTools: everyTool,
            hasCurrentSource: false,
            currentSourceCount: 0,
            historyTurnCount: 0,
            historyHasSources: false,
            question: "who won the game"
        )
        #expect(evaluation.allowsExternalRetrieval)
        #expect(evaluation.gatedTools == everyTool)
        #expect(evaluation.execution == "none")
    }

    @Test func broaderOverrideLiftsTheHold() {
        let evaluation = gate.evaluate(
            enabledTools: [.web],
            hasCurrentSource: true,
            currentSourceCount: 1,
            historyTurnCount: 0,
            historyHasSources: false,
            question: "summarize this",
            override: .broader
        )
        #expect(evaluation.allowsExternalRetrieval)
        #expect(evaluation.gatedTools == [.web])
    }

    @Test func sourceOnlyStillRecordsTheNarrowScope() {
        let evaluation = gate.evaluate(
            enabledTools: [.web],
            hasCurrentSource: true,
            currentSourceCount: 1,
            historyTurnCount: 2,
            historyHasSources: true,
            question: "search the web",
            override: .sourceOnly
        )
        // The override still narrows what is read and what the receipt
        // says; it no longer takes the tools away.
        #expect(!evaluation.allowsExternalRetrieval)
        #expect(evaluation.gatedTools == [.web])
        #expect(evaluation.execution == "currentSource")
    }

    @Test func aBroadSummaryDoesNotWidenExternalOnItsOwn() {
        let evaluation = gate.evaluate(
            enabledTools: everyTool,
            hasCurrentSource: true,
            currentSourceCount: 2,
            historyTurnCount: 3,
            historyHasSources: true,
            question: "summarize everything"
        )
        #expect(!evaluation.allowsExternalRetrieval)
        #expect(evaluation.gatedTools == everyTool)
        #expect(evaluation.execution == "currentSourceAndHistory")
    }

    /// The enrichment gate is open. The caller has already decided the
    /// wording asks for a search; this used to refuse it a second time
    /// whenever a source was attached.
    @Test func webSearchIsAllowedEvenWhenGrounded() {
        let grounded = gate.evaluate(
            enabledTools: [.web],
            hasCurrentSource: true,
            currentSourceCount: 1,
            historyTurnCount: 0,
            historyHasSources: false,
            question: "summarize this file"
        )
        #expect(grounded.grounded)
        #expect(ChatContextGate.allowsWebSearch(grounded))
        #expect(ChatContextGate.allowsWebSearch(nil))
    }

    @Test func receiptCarriesTheScopeAndBudget() {
        let evaluation = gate.evaluate(
            enabledTools: everyTool,
            hasCurrentSource: true,
            currentSourceCount: 1,
            historyTurnCount: 0,
            historyHasSources: false,
            question: "what is the total"
        )
        let receipt = gate.receipt(for: evaluation, budgetCharacters: 4_000)
        #expect(receipt.scope == .currentSource)
        #expect(receipt.sourceFirst == true)
        #expect(receipt.budgetCharacters == 4_000)
        #expect(receipt.rationale?.isEmpty == false)
    }
}
