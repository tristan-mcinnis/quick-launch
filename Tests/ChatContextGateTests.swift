import Testing
import Foundation
import HouseChatCore
@testable import QuickLaunch

/// The source-first gate: a source-grounded request withholds every broad
/// tool, follow-ups included, until the user asks for outside evidence or
/// chooses Broader search.
@Suite("Chat context gate")
struct ChatContextGateTests {
    private let gate = ChatContextGate.standard
    private let everyTool = Set(ChatToolKind.allCases)

    @Test func aCurrentSourceWithholdsEveryBroadTool() {
        let evaluation = gate.evaluate(
            enabledTools: everyTool,
            hasCurrentSource: true,
            currentSourceCount: 1,
            historyTurnCount: 0,
            historyHasSources: false,
            question: "What does this file say about revenue?"
        )
        #expect(!evaluation.allowsExternalRetrieval)
        #expect(evaluation.gatedTools.isEmpty)
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

    @Test func aFollowUpOnAGroundedHistoryStaysWithheld() {
        let evaluation = gate.evaluate(
            enabledTools: everyTool,
            hasCurrentSource: false,
            currentSourceCount: 0,
            historyTurnCount: 4,
            historyHasSources: true,
            question: "and what does the second table show?"
        )
        #expect(!evaluation.allowsExternalRetrieval)
        #expect(evaluation.gatedTools.isEmpty)
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

    @Test func sourceOnlyRefusesExternalEvenWithWording() {
        let evaluation = gate.evaluate(
            enabledTools: [.web],
            hasCurrentSource: true,
            currentSourceCount: 1,
            historyTurnCount: 2,
            historyHasSources: true,
            question: "search the web",
            override: .sourceOnly
        )
        #expect(!evaluation.allowsExternalRetrieval)
        #expect(evaluation.gatedTools.isEmpty)
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
        #expect(evaluation.gatedTools.isEmpty)
        #expect(evaluation.execution == "currentSourceAndHistory")
    }

    @Test func webSearchGateFollowsTheDecision() {
        let grounded = gate.evaluate(
            enabledTools: [.web],
            hasCurrentSource: true,
            currentSourceCount: 1,
            historyTurnCount: 0,
            historyHasSources: false,
            question: "summarize this file"
        )
        #expect(!ChatContextGate.allowsWebSearch(grounded))
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
