import Foundation
import HouseChatCore

/// What the context policy decided for one request, in Quick-Launch-native
/// terms so the view model never needs to import the package.
///
/// `execution` and `offeredScopes` are `RetrievalScope` raw values, carried
/// as strings for receipts and for a future Attached-sources control.
struct ChatContextEvaluation: Sendable, Equatable {
    /// Whether the request may reach outside the conversation: web search,
    /// the vault, memory, tasks, skills. False means every broad tool is
    /// withheld for this turn, follow-ups included.
    var allowsExternalRetrieval: Bool
    /// The corpus retrieval may read: `none`, `currentSource`, `history`,
    /// or `currentSourceAndHistory`.
    var execution: String
    var sourceFirst: Bool
    var includesHistory: Bool
    /// Scopes the UI may offer on top (`history`, `currentSourceAndHistory`).
    var offeredScopes: [String]
    var rationale: String
    /// The enabled tools this request may actually offer and run.
    var gatedTools: Set<ChatToolKind>

    /// True when the user may widen this request to the history the policy
    /// withheld.
    var offersWidening: Bool { !offeredScopes.isEmpty }

    /// True when "Broader search" would change anything: the request is
    /// grounded (a source or a sourced history) so external retrieval is
    /// currently withheld. The composer shows the control only then.
    var broaderSearchEnabled: Bool { !allowsExternalRetrieval }

    /// The effective route in words, for the composer's context label:
    /// what is read, and whether the broad tools are allowed.
    var effectiveRouteLabel: String {
        let scope: String
        switch execution {
        case "currentSource": scope = sourceFirst ? "attached source" : "current source"
        case "history": scope = "earlier turns"
        case "currentSourceAndHistory": scope = "attached source and earlier turns"
        default: scope = "no attachment"
        }
        return allowsExternalRetrieval
            ? "Reading \(scope) · tools allowed"
            : "Reading \(scope) · tools withheld"
    }
}

/// The one place Quick Launch asks what a request may retrieve and which
/// tools it may run. It wraps `HouseChatCore.ContextPolicy` so the policy is
/// resolved identically for Quick AI and AI Chat, and so the tool gate is
/// never re-derived by hand.
///
/// Execution is about the conversation's own sources (the attachment text in
/// this turn and earlier turns). External permission is a separate axis: a
/// current source or a history that carried sources withholds the broad
/// tools until the user asks for outside evidence or chooses Broader search.
struct ChatContextGate: Sendable {
    static let standard = ChatContextGate()

    let policy: ContextPolicy

    init(policy: ContextPolicy = .standard) {
        self.policy = policy
    }

    func evaluate(
        enabledTools: Set<ChatToolKind>,
        hasCurrentSource: Bool,
        currentSourceCount: Int,
        historyTurnCount: Int,
        historyHasSources: Bool,
        question: String,
        override: ContextOverride? = nil
    ) -> ChatContextEvaluation {
        let decision = policy.resolve(ContextRequest(
            hasCurrentSource: hasCurrentSource,
            currentSourceCount: currentSourceCount,
            historyTurnCount: historyTurnCount,
            historyHasSources: historyHasSources,
            question: question,
            override: override
        ))
        return ChatContextEvaluation(
            allowsExternalRetrieval: decision.allowsExternalRetrieval,
            execution: decision.execution.rawValue,
            sourceFirst: decision.sourceFirst,
            includesHistory: decision.includesHistory,
            offeredScopes: decision.offered.map(\.rawValue),
            rationale: decision.rationale,
            gatedTools: Self.gatedTools(enabledTools, decision: decision)
        )
    }

    /// Every Quick Launch chat tool reaches outside the conversation, so the
    /// gate is all-or-nothing today. It is expressed per tool so a future
    /// within-conversation tool is not silently withheld with the rest.
    static func gatedTools(_ enabled: Set<ChatToolKind>, decision: ContextDecision) -> Set<ChatToolKind> {
        guard decision.allowsExternalRetrieval else { return [] }
        return enabled
    }

    /// The sanitized receipt persisted with the turn.
    func receipt(for evaluation: ChatContextEvaluation, budgetCharacters: Int) -> ContextReceipt {
        ContextReceipt(
            scope: RetrievalScope(rawValue: evaluation.execution),
            sourceFirst: evaluation.sourceFirst,
            historyIncluded: evaluation.includesHistory,
            budgetCharacters: budgetCharacters,
            coverageLabels: nil,
            matched: nil,
            complete: nil,
            rationale: evaluation.rationale
        )
    }

    /// Whether an explicit web-search enrichment may run for this request.
    /// The policy already treats explicit "search the web" wording as
    /// external intent, so a grounded request still passes when the user
    /// asked for it.
    static func allowsWebSearch(_ evaluation: ChatContextEvaluation?) -> Bool {
        evaluation?.allowsExternalRetrieval ?? true
    }
}
