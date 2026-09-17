import Foundation

/// What a question is asking for, read from its wording alone. Used to decide
/// whether retrieval may look beyond the sources in front of it.
public struct QuestionIntent: Sendable, Equatable {
    /// "this file", "这个", "上面".
    public var asksAboutCurrentSource: Bool
    /// "earlier", "last time", "之前", "上次".
    public var asksAboutHistory: Bool
    /// "compare", "vs", "对比", "区别".
    public var asksForComparison: Bool
    /// "summarize", "overall", "总结", "全部".
    public var asksForBroadSummary: Bool
    /// "search the web", "look it up", "搜一下". Explicit evidence that the
    /// user wants retrieval outside the chat.
    public var asksForExternalSearch: Bool
    /// The terms that matched, for a receipt or a log line.
    public var matchedTerms: [String]

    public init(
        asksAboutCurrentSource: Bool = false,
        asksAboutHistory: Bool = false,
        asksForComparison: Bool = false,
        asksForBroadSummary: Bool = false,
        asksForExternalSearch: Bool = false,
        matchedTerms: [String] = []
    ) {
        self.asksAboutCurrentSource = asksAboutCurrentSource
        self.asksAboutHistory = asksAboutHistory
        self.asksForComparison = asksForComparison
        self.asksForBroadSummary = asksForBroadSummary
        self.asksForExternalSearch = asksForExternalSearch
        self.matchedTerms = matchedTerms
    }
}

/// A deliberate widening or narrowing of retrieval, e.g. from a chip the user
/// taps. An override always wins over the wording.
public enum ContextOverride: Sendable, Equatable, CaseIterable {
    /// Only the sources in this message, whatever the question says.
    case sourceOnly
    /// Only earlier history.
    case history
    /// Current source and history, compared.
    case compareHistory
    /// Look as widely as the app allows.
    case broader
}

/// Everything `ContextPolicy` needs, all of it already known to the caller.
public struct ContextRequest: Sendable, Equatable {
    /// True when this message carries attachment text or a current page read.
    public var hasCurrentSource: Bool
    public var currentSourceCount: Int
    /// Earlier turns in this conversation.
    public var historyTurnCount: Int
    /// True when earlier turns had attachments or read pages.
    public var historyHasSources: Bool
    public var question: String
    public var override: ContextOverride?

    public init(
        hasCurrentSource: Bool,
        currentSourceCount: Int = 0,
        historyTurnCount: Int = 0,
        historyHasSources: Bool = false,
        question: String,
        override: ContextOverride? = nil
    ) {
        self.hasCurrentSource = hasCurrentSource
        self.currentSourceCount = currentSourceCount
        self.historyTurnCount = historyTurnCount
        self.historyHasSources = historyHasSources
        self.question = question
        self.override = override
    }
}

/// The retrieval decision: what the consumer must enforce, and what it may
/// offer on top.
public struct ContextDecision: Sendable, Equatable {
    /// The scope the retriever is allowed to read from for this request.
    public var execution: RetrievalScope
    /// When both corpora are allowed, read the current source first and fall
    /// back to history only if it is thin.
    public var sourceFirst: Bool
    public var includesHistory: Bool
    /// Scopes the UI may offer to the user. Never more than `execution`
    /// already allows plus the one deliberate widening.
    public var offered: [RetrievalScope]
    /// Whether the app may use retrieval outside the conversation: web
    /// search, a page fetch, the vault, and the rest of its existing tools.
    ///
    /// This is a second axis, not a `RetrievalScope`: external retrieval is
    /// not a corpus of this conversation. Ordinary chat with no grounding
    /// allows it; a current source or a history that carried sources withholds
    /// it until the user shows external intent or overrides.
    public var allowsExternalRetrieval: Bool
    public var intent: QuestionIntent
    public var override: ContextOverride?
    public var rationale: String

    public init(
        execution: RetrievalScope,
        sourceFirst: Bool,
        includesHistory: Bool,
        offered: [RetrievalScope],
        allowsExternalRetrieval: Bool = false,
        intent: QuestionIntent,
        override: ContextOverride? = nil,
        rationale: String
    ) {
        self.execution = execution
        self.sourceFirst = sourceFirst
        self.includesHistory = includesHistory
        self.offered = offered
        self.allowsExternalRetrieval = allowsExternalRetrieval
        self.intent = intent
        self.override = override
        self.rationale = rationale
    }
}

/// The one place that decides what a request may retrieve.
///
/// Two decisions at once:
///
/// **Inside the conversation** (a `RetrievalScope`):
/// 1. An explicit override wins outright. `sourceOnly` never reads history.
/// 2. With no current source, history is the only corpus.
/// 3. With a current source, execution is source-first: the current source
///    alone, deterministically, unless the question asks for history, a
///    comparison, or a broad summary.
/// 4. With both corpora and a source-first execution, the decision records
///    the history scopes the UI may *offer*, but the consumer executes only
///    `execution` until the user takes the offer.
///
/// **Outside it** (`allowsExternalRetrieval`): web search, page fetches, the
/// vault, and the app's other tools.
/// - Ordinary chat with no attachments anywhere allows them.
/// - A current source, or a history that carried sources, withholds them,
///   follow-up questions included.
/// - Only an explicit outside target ("search the web", "check the vault",
///   "other projects", "上网") or an explicit `broader`/`history` override
///   lifts that. A bare cue such as "search", "latest", "news", or "搜一下"
///   never does: a source in front of the user is grounding, and an ordinary
///   chat with no source already allows the tools.
/// - A broad summary, a comparison of attached documents, and a mention of
///   earlier turns all remain inside the conversation.
///
/// All matching is lexical and deterministic: no model, no network, no clock.
public struct ContextPolicy: Sendable {
    public struct Configuration: Sendable {
        /// Terms that ask about the material in this message.
        public var currentSourceTerms: Set<String>
        /// Terms that ask about earlier turns.
        public var historyTerms: Set<String>
        /// Terms that ask for a comparison.
        public var comparisonTerms: Set<String>
        /// Terms that ask for a summary or an overview.
        public var broadSummaryTerms: Set<String>
        /// Terms that name somewhere outside the conversation: "the web",
        /// "online", "the vault", "memory", "other projects", "上网". An
        /// explicit target is the only wording that widens external retrieval;
        /// a bare cue such as "search" or "latest" never does, because a
        /// source in front of the user is already grounding and ordinary
        /// no-source chat already allows the app's tools.
        public var externalTargetTerms: Set<String>

        public init(
            currentSourceTerms: Set<String> = ContextPolicy.defaultCurrentSourceTerms,
            historyTerms: Set<String> = ContextPolicy.defaultHistoryTerms,
            comparisonTerms: Set<String> = ContextPolicy.defaultComparisonTerms,
            broadSummaryTerms: Set<String> = ContextPolicy.defaultBroadSummaryTerms,
            externalTargetTerms: Set<String> = ContextPolicy.defaultExternalTargetTerms
        ) {
            self.currentSourceTerms = currentSourceTerms
            self.historyTerms = historyTerms
            self.comparisonTerms = comparisonTerms
            self.broadSummaryTerms = broadSummaryTerms
            self.externalTargetTerms = externalTargetTerms
        }

        public static let `default` = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    public static let standard = ContextPolicy()

    // MARK: Resolve

    public func resolve(_ request: ContextRequest) -> ContextDecision {
        let intent = classify(request.question)
        let hasHistory = request.historyTurnCount > 0 || request.historyHasSources
        let hasSource = request.hasCurrentSource
        let grounded = hasSource || request.historyHasSources
        let external = allowsExternalRetrieval(
            grounded: grounded,
            intent: intent,
            override: request.override
        )
        let note = external
            ? "external retrieval allowed"
            : "grounded: external retrieval withheld"

        if let override = request.override {
            return resolveOverride(
                override,
                hasSource: hasSource,
                hasHistory: hasHistory,
                external: external,
                note: note,
                intent: intent
            )
        }

        if hasSource && !hasHistory {
            return ContextDecision(
                execution: .currentSource,
                sourceFirst: true,
                includesHistory: false,
                offered: [],
                allowsExternalRetrieval: external,
                intent: intent,
                rationale: "current source only; there is no earlier history. \(note)"
            )
        }
        if !hasSource && hasHistory {
            return ContextDecision(
                execution: .history,
                sourceFirst: false,
                includesHistory: true,
                offered: [],
                allowsExternalRetrieval: external,
                intent: intent,
                rationale: "no source in this message; earlier history only. \(note)"
            )
        }
        if !hasSource && !hasHistory {
            return ContextDecision(
                execution: .none,
                sourceFirst: false,
                includesHistory: false,
                offered: [],
                allowsExternalRetrieval: external,
                intent: intent,
                rationale: "no source and no history; ordinary chat. \(note)"
            )
        }

        // Both corpora are available.
        let wantsHistory = intent.asksAboutHistory || intent.asksForComparison
        if wantsHistory {
            return ContextDecision(
                execution: .currentSourceAndHistory,
                sourceFirst: true,
                includesHistory: true,
                offered: [],
                allowsExternalRetrieval: external,
                intent: intent,
                rationale: (intent.asksForComparison
                    ? "the question asks for a comparison; current source and history are allowed. \(note)"
                    : "the question asks about earlier turns; current source and history are allowed. \(note)")
            )
        }
        if intent.asksForBroadSummary {
            return ContextDecision(
                execution: .currentSourceAndHistory,
                sourceFirst: true,
                includesHistory: true,
                offered: [],
                allowsExternalRetrieval: external,
                intent: intent,
                rationale: "the question asks for a broad summary; current source and history are allowed, external retrieval is not implied. \(note)"
            )
        }
        return ContextDecision(
            execution: .currentSource,
            sourceFirst: true,
            includesHistory: false,
            offered: [.history, .currentSourceAndHistory],
            allowsExternalRetrieval: external,
            intent: intent,
            rationale: "source-first: the current source alone, with earlier history offered. \(note)"
        )
    }

    /// External retrieval is allowed unless the conversation is grounded, and
    /// only explicit external intent or an explicit override lifts that.
    private func allowsExternalRetrieval(
        grounded: Bool,
        intent: QuestionIntent,
        override: ContextOverride?
    ) -> Bool {
        var allowed = !grounded
        if intent.asksForExternalSearch { allowed = true }
        switch override {
        case .sourceOnly: allowed = false
        case .history, .broader: allowed = true
        case .compareHistory, .none: break
        }
        return allowed
    }

    private func resolveOverride(
        _ override: ContextOverride,
        hasSource: Bool,
        hasHistory: Bool,
        external: Bool,
        note: String,
        intent: QuestionIntent
    ) -> ContextDecision {
        let both = hasSource && hasHistory
        switch override {
        case .sourceOnly:
            return ContextDecision(
                execution: hasSource ? .currentSource : .none,
                sourceFirst: true,
                includesHistory: false,
                offered: [],
                allowsExternalRetrieval: external,
                intent: intent,
                override: override,
                rationale: "explicit source-only override. \(note)"
            )
        case .history:
            return ContextDecision(
                execution: hasHistory ? .history : (hasSource ? .currentSource : .none),
                sourceFirst: false,
                includesHistory: hasHistory,
                offered: both ? [.currentSourceAndHistory] : [],
                allowsExternalRetrieval: external,
                intent: intent,
                override: override,
                rationale: "explicit history override. \(note)"
            )
        case .compareHistory:
            return ContextDecision(
                execution: both ? .currentSourceAndHistory : (hasSource ? .currentSource : (hasHistory ? .history : .none)),
                sourceFirst: true,
                includesHistory: hasHistory,
                offered: [],
                allowsExternalRetrieval: external,
                intent: intent,
                override: override,
                rationale: "explicit compare-with-history override. \(note)"
            )
        case .broader:
            return ContextDecision(
                execution: both ? .currentSourceAndHistory : (hasSource ? .currentSource : (hasHistory ? .history : .none)),
                sourceFirst: false,
                includesHistory: hasHistory,
                offered: [],
                allowsExternalRetrieval: external,
                intent: intent,
                override: override,
                rationale: "explicit broader override. \(note)"
            )
        }
    }

    // MARK: Classify

    public func classify(_ question: String) -> QuestionIntent {
        let lowered = question.lowercased()
        let words = Self.words(in: lowered)
        var matched: [String] = []

        func hit(_ terms: Set<String>) -> Bool {
            var found = false
            for term in terms.sorted() {
                let matchedTerm: Bool
                if Self.isCJK(term) || term.contains(" ") {
                    matchedTerm = lowered.contains(term)
                } else {
                    matchedTerm = words.contains(term)
                }
                if matchedTerm {
                    found = true
                    matched.append(term)
                }
            }
            return found
        }

        let currentSource = hit(configuration.currentSourceTerms)
        let history = hit(configuration.historyTerms)
        let comparison = hit(configuration.comparisonTerms)
        let broad = hit(configuration.broadSummaryTerms)

        // Only a named outside target widens external retrieval. A bare cue
        // ("search", "latest", "news", "搜一下") never does: with a source in
        // front of the user the question is grounded, and an ordinary chat with
        // no source at all already allows the app's tools.
        let external = hit(configuration.externalTargetTerms)

        return QuestionIntent(
            asksAboutCurrentSource: currentSource,
            asksAboutHistory: history,
            asksForComparison: comparison,
            asksForBroadSummary: broad,
            asksForExternalSearch: external,
            matchedTerms: matched.sorted()
        )
    }

    // MARK: Terms

    public static let defaultCurrentSourceTerms: Set<String> = [
        "this", "these", "here", "above", "file", "document", "attachment", "attached",
        "pdf", "deck", "slide", "sheet", "source", "它", "这个", "这份", "这张", "上面",
        "上述", "本文", "该文件", "附件里", "当前",
    ]

    public static let defaultHistoryTerms: Set<String> = [
        "earlier", "previous", "previously", "before", "history", "prior", "last", "other",
        "之前", "上次", "上一条", "前面", "此前", "历史", "早先", "最早", "前文", "刚才",
        "那条", "前面提到", "之前提到",
    ]

    public static let defaultComparisonTerms: Set<String> = [
        "compare", "compares", "compared", "comparison", "versus", "vs", "differ",
        "difference", "differences", "contrast", "对比", "比较", "相比", "区别", "差异", "对照",
    ]

    public static let defaultBroadSummaryTerms: Set<String> = [
        "summarize", "summarise", "summary", "overview", "overall", "everything", "all",
        "whole", "entire", "aggregate", "synthesize", "总结", "概括", "总体", "整体", "全部",
        "所有", "汇总", "归纳", "综述",
    ]

    /// Anywhere outside the conversation, named explicitly. This is the only
    /// wording that widens external retrieval.
    public static let defaultExternalTargetTerms: Set<String> = [
        "web", "website", "websites", "online", "internet", "browse", "browser",
        "google", "bing", "wikipedia", "reddit", "vault", "memory", "outside",
        "external", "other project", "other projects", "other chat", "other conversation",
        "上网", "网上", "网页", "外网", "互联网", "百度", "谷歌", "浏览器",
        "知识库", "记忆", "外部", "其他项目", "别的项目", "其他对话",
    ]

    /// Lowercased word tokens, letters and digits only.
    static func words(in text: String) -> Set<String> {
        var words: Set<String> = []
        var current = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { words.insert(current) }
        return words
    }

    static func isCJK(_ term: String) -> Bool {
        term.unicodeScalars.contains(where: UnicodeScript.isCJK)
    }
}
