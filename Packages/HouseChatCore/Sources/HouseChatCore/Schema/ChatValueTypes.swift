import Foundation

// MARK: - Model selection

/// One (provider, model, thinking) triple. Every field is optional so a
/// record written before that concept existed still decodes.
public struct ModelChoice: Codable, Sendable, Equatable, Hashable {
    /// "local", "deepseek", "openai", "anthropic", "cli".
    public var provider: String?
    /// The model identifier the provider was asked for.
    public var model: String?
    /// "off", "low", "medium", "high", or a provider-specific level.
    public var thinking: String?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        provider: String? = nil,
        model: String? = nil,
        thinking: String? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.provider = provider
        self.model = model
        self.thinking = thinking
        self.extra = extra
    }

    public var isEmpty: Bool { provider == nil && model == nil && thinking == nil }

    private static let knownKeys: Set<String> = ["provider", "model", "thinking"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.provider = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("provider"))
        self.model = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("model"))
        self.thinking = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("thinking"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(provider, forKey: AnyCodingKey("provider"))
        try c.encodeIfPresent(model, forKey: AnyCodingKey("model"))
        try c.encodeIfPresent(thinking, forKey: AnyCodingKey("thinking"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

/// What was chosen for a turn and what was actually used. The two differ when
/// a fallback, a downgrade, or a local substitution happened; the receipt
/// keeps both so a later audit can see the swap.
public struct ModelSelection: Codable, Sendable, Equatable, Hashable {
    public var chosen: ModelChoice?
    public var effective: ModelChoice?
    public var extra: ExtraFields

    public init(chosen: ModelChoice? = nil, effective: ModelChoice? = nil, extra: ExtraFields = ExtraFields()) {
        self.chosen = chosen
        self.effective = effective
        self.extra = extra
    }

    /// A selection with the same value on both sides.
    public init(_ choice: ModelChoice) {
        self.init(chosen: choice, effective: choice)
    }

    private static let knownKeys: Set<String> = ["chosen", "effective"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        chosen = try c.decodeIfPresent(ModelChoice.self, forKey: AnyCodingKey("chosen"))
        effective = try c.decodeIfPresent(ModelChoice.self, forKey: AnyCodingKey("effective"))
        extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(chosen, forKey: AnyCodingKey("chosen"))
        try c.encodeIfPresent(effective, forKey: AnyCodingKey("effective"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }

    public var isEmpty: Bool {
        (chosen?.isEmpty ?? true) && (effective?.isEmpty ?? true) && extra.isEmpty
    }
}

// MARK: - Session links

/// A link from a conversation to the thing it belongs to (an RTI meeting
/// session, a transcript, a vault note, a QL window).
public struct SessionLink: Codable, Sendable, Equatable, Hashable {
    /// "rti-session", "transcript", "vault-note", "ql-window".
    public var kind: String?
    public var id: String?
    public var label: String?
    public var url: URL?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        kind: String? = nil,
        id: String? = nil,
        label: String? = nil,
        url: URL? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.kind = kind
        self.id = id
        self.label = label
        self.url = url
        self.extra = extra
    }

    private static let knownKeys: Set<String> = ["kind", "id", "label", "url"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.kind = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("kind"))
        self.id = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("id"))
        self.label = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("label"))
        self.url = try c.decodeIfPresent(URL.self, forKey: AnyCodingKey("url"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(kind, forKey: AnyCodingKey("kind"))
        try c.encodeIfPresent(id, forKey: AnyCodingKey("id"))
        try c.encodeIfPresent(label, forKey: AnyCodingKey("label"))
        try c.encodeIfPresent(url, forKey: AnyCodingKey("url"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

// MARK: - Timings and usage

/// Per-turn timings, in seconds. Kept as `Double` so a record can be written
/// by a build that measured only some of them.
public struct TurnTimings: Codable, Sendable, Equatable, Hashable {
    public var extractionSeconds: Double?
    public var queuedSeconds: Double?
    public var firstTokenSeconds: Double?
    public var totalSeconds: Double?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        extractionSeconds: Double? = nil,
        queuedSeconds: Double? = nil,
        firstTokenSeconds: Double? = nil,
        totalSeconds: Double? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.extractionSeconds = extractionSeconds
        self.queuedSeconds = queuedSeconds
        self.firstTokenSeconds = firstTokenSeconds
        self.totalSeconds = totalSeconds
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "extractionSeconds", "queuedSeconds", "firstTokenSeconds", "totalSeconds",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.extractionSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("extractionSeconds"))
        self.queuedSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("queuedSeconds"))
        self.firstTokenSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("firstTokenSeconds"))
        self.totalSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("totalSeconds"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(extractionSeconds, forKey: AnyCodingKey("extractionSeconds"))
        try c.encodeIfPresent(queuedSeconds, forKey: AnyCodingKey("queuedSeconds"))
        try c.encodeIfPresent(firstTokenSeconds, forKey: AnyCodingKey("firstTokenSeconds"))
        try c.encodeIfPresent(totalSeconds, forKey: AnyCodingKey("totalSeconds"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

/// Timings for one request, including the tool and retrieval time that the
/// turn's own numbers fold in.
public struct RequestTimings: Codable, Sendable, Equatable, Hashable {
    public var totalSeconds: Double?
    public var firstTokenSeconds: Double?
    public var toolSeconds: Double?
    public var retrievalSeconds: Double?
    public var extractionSeconds: Double?
    public var retries: Int?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        totalSeconds: Double? = nil,
        firstTokenSeconds: Double? = nil,
        toolSeconds: Double? = nil,
        retrievalSeconds: Double? = nil,
        extractionSeconds: Double? = nil,
        retries: Int? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.totalSeconds = totalSeconds
        self.firstTokenSeconds = firstTokenSeconds
        self.toolSeconds = toolSeconds
        self.retrievalSeconds = retrievalSeconds
        self.extractionSeconds = extractionSeconds
        self.retries = retries
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "totalSeconds", "firstTokenSeconds", "toolSeconds", "retrievalSeconds",
        "extractionSeconds", "retries",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.totalSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("totalSeconds"))
        self.firstTokenSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("firstTokenSeconds"))
        self.toolSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("toolSeconds"))
        self.retrievalSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("retrievalSeconds"))
        self.extractionSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("extractionSeconds"))
        self.retries = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("retries"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(totalSeconds, forKey: AnyCodingKey("totalSeconds"))
        try c.encodeIfPresent(firstTokenSeconds, forKey: AnyCodingKey("firstTokenSeconds"))
        try c.encodeIfPresent(toolSeconds, forKey: AnyCodingKey("toolSeconds"))
        try c.encodeIfPresent(retrievalSeconds, forKey: AnyCodingKey("retrievalSeconds"))
        try c.encodeIfPresent(extractionSeconds, forKey: AnyCodingKey("extractionSeconds"))
        try c.encodeIfPresent(retries, forKey: AnyCodingKey("retries"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

/// Tokens a provider reported for one request.
public struct TokenUsage: Codable, Sendable, Equatable, Hashable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var totalTokens: Int?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        totalTokens: Int? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.totalTokens = totalTokens
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "inputTokens", "outputTokens", "cachedInputTokens", "totalTokens",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.inputTokens = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("inputTokens"))
        self.outputTokens = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("outputTokens"))
        self.cachedInputTokens = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("cachedInputTokens"))
        self.totalTokens = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("totalTokens"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(inputTokens, forKey: AnyCodingKey("inputTokens"))
        try c.encodeIfPresent(outputTokens, forKey: AnyCodingKey("outputTokens"))
        try c.encodeIfPresent(cachedInputTokens, forKey: AnyCodingKey("cachedInputTokens"))
        try c.encodeIfPresent(totalTokens, forKey: AnyCodingKey("totalTokens"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

// MARK: - Tools

/// Where one tool round ended.
public enum ToolRoundStatus: String, Codable, Sendable, CaseIterable {
    case running
    case succeeded
    case failed
    case cancelled
    case refused
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ToolRoundStatus(rawValue: raw) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One tool call inside a round. `arguments` is the JSON text as sent, kept
/// verbatim so a later audit reads exactly what the model asked for.
public struct ToolCall: Codable, Sendable, Equatable, Hashable {
    public var id: String?
    public var name: String?
    public var arguments: String?
    /// A short human-readable result; never the full tool output.
    public var resultSummary: String?
    public var status: ToolRoundStatus?
    public var durationSeconds: Double?
    public var error: String?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        id: String? = nil,
        name: String? = nil,
        arguments: String? = nil,
        resultSummary: String? = nil,
        status: ToolRoundStatus? = nil,
        durationSeconds: Double? = nil,
        error: String? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.resultSummary = resultSummary
        self.status = status
        self.durationSeconds = durationSeconds
        self.error = error
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "id", "name", "arguments", "resultSummary", "status", "durationSeconds", "error",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("id"))
        self.name = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("name"))
        self.arguments = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("arguments"))
        self.resultSummary = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("resultSummary"))
        self.status = try c.decodeIfPresent(ToolRoundStatus.self, forKey: AnyCodingKey("status"))
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("durationSeconds"))
        self.error = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("error"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(id, forKey: AnyCodingKey("id"))
        try c.encodeIfPresent(name, forKey: AnyCodingKey("name"))
        try c.encodeIfPresent(arguments, forKey: AnyCodingKey("arguments"))
        try c.encodeIfPresent(resultSummary, forKey: AnyCodingKey("resultSummary"))
        try c.encodeIfPresent(status, forKey: AnyCodingKey("status"))
        try c.encodeIfPresent(durationSeconds, forKey: AnyCodingKey("durationSeconds"))
        try c.encodeIfPresent(error, forKey: AnyCodingKey("error"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

/// One model-to-tools-to-model round.
public struct ToolRound: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var index: Int?
    public var calls: [ToolCall]
    public var status: ToolRoundStatus?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var durationSeconds: Double?
    public var extra: ExtraFields

    public init(
        id: String = UUID().uuidString,
        index: Int? = nil,
        calls: [ToolCall] = [],
        status: ToolRoundStatus? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        durationSeconds: Double? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.id = id
        self.index = index
        self.calls = calls
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationSeconds = durationSeconds
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "id", "index", "calls", "status", "startedAt", "finishedAt", "durationSeconds",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = try c.decodeNonEmptyString(forKey: AnyCodingKey("id"))
        self.index = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("index"))
        self.calls = try c.decodeIfPresent([ToolCall].self, forKey: AnyCodingKey("calls")) ?? []
        self.status = try c.decodeIfPresent(ToolRoundStatus.self, forKey: AnyCodingKey("status"))
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("startedAt"))
        self.finishedAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("finishedAt"))
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: AnyCodingKey("durationSeconds"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(id, forKey: AnyCodingKey("id"))
        try c.encodeIfPresent(index, forKey: AnyCodingKey("index"))
        try c.encode(calls, forKey: AnyCodingKey("calls"))
        try c.encodeIfPresent(status, forKey: AnyCodingKey("status"))
        try c.encodeIfPresent(startedAt, forKey: AnyCodingKey("startedAt"))
        try c.encodeIfPresent(finishedAt, forKey: AnyCodingKey("finishedAt"))
        try c.encodeIfPresent(durationSeconds, forKey: AnyCodingKey("durationSeconds"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}

// MARK: - Retrieval receipt

/// Which corpus a request was allowed to read: only this message's sources,
/// only earlier turns, both, or neither.
public enum RetrievalScope: String, Codable, Sendable, CaseIterable {
    case none
    /// Attachments and text in the request being answered.
    case currentSource
    /// Text and attachment snapshots from earlier turns.
    case history
    case currentSourceAndHistory

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RetrievalScope(rawValue: raw) ?? .none
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What retrieval the request was allowed to do, and what it did.
public struct ContextReceipt: Codable, Sendable, Equatable, Hashable {
    public var scope: RetrievalScope?
    /// The literal scope string when the stored value is not one this build
    /// knows. `scope` is nil then, so a consumer reads the receipt as "not
    /// stated" instead of the meaningful `.none`, and re-encoding writes the
    /// original string back rather than `"none"`.
    public var scopeRaw: String?
    public var sourceFirst: Bool?
    public var historyIncluded: Bool?
    public var budgetCharacters: Int?
    public var sourceCharacters: Int?
    public var historyCharacters: Int?
    /// The labels of the passages that were selected, for coverage.
    public var coverageLabels: [String]?
    public var matched: Bool?
    public var complete: Bool?
    public var rationale: String?
    /// Keys this build does not model, preserved verbatim.
    public var extra: ExtraFields

    public init(
        scope: RetrievalScope? = nil,
        scopeRaw: String? = nil,
        sourceFirst: Bool? = nil,
        historyIncluded: Bool? = nil,
        budgetCharacters: Int? = nil,
        sourceCharacters: Int? = nil,
        historyCharacters: Int? = nil,
        coverageLabels: [String]? = nil,
        matched: Bool? = nil,
        complete: Bool? = nil,
        rationale: String? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.scope = scope
        self.scopeRaw = scopeRaw
        self.sourceFirst = sourceFirst
        self.historyIncluded = historyIncluded
        self.budgetCharacters = budgetCharacters
        self.sourceCharacters = sourceCharacters
        self.historyCharacters = historyCharacters
        self.coverageLabels = coverageLabels
        self.matched = matched
        self.complete = complete
        self.rationale = rationale
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "scope", "sourceFirst", "historyIncluded", "budgetCharacters", "sourceCharacters",
        "historyCharacters", "coverageLabels", "matched", "complete", "rationale",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        // An unrecognized scope is "not stated", not `.none`: the raw string
        // is kept so a newer build's receipt survives a round trip.
        if let raw = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("scope")) {
            if let known = RetrievalScope(rawValue: raw) {
                self.scope = known
                self.scopeRaw = nil
            } else {
                self.scope = nil
                self.scopeRaw = raw
            }
        } else {
            self.scope = nil
            self.scopeRaw = nil
        }
        self.sourceFirst = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("sourceFirst"))
        self.historyIncluded = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("historyIncluded"))
        self.budgetCharacters = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("budgetCharacters"))
        self.sourceCharacters = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("sourceCharacters"))
        self.historyCharacters = try c.decodeIfPresent(Int.self, forKey: AnyCodingKey("historyCharacters"))
        self.coverageLabels = try c.decodeIfPresent([String].self, forKey: AnyCodingKey("coverageLabels"))
        self.matched = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("matched"))
        self.complete = try c.decodeIfPresent(Bool.self, forKey: AnyCodingKey("complete"))
        self.rationale = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("rationale"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encodeIfPresent(scope?.rawValue ?? scopeRaw, forKey: AnyCodingKey("scope"))
        try c.encodeIfPresent(sourceFirst, forKey: AnyCodingKey("sourceFirst"))
        try c.encodeIfPresent(historyIncluded, forKey: AnyCodingKey("historyIncluded"))
        try c.encodeIfPresent(budgetCharacters, forKey: AnyCodingKey("budgetCharacters"))
        try c.encodeIfPresent(sourceCharacters, forKey: AnyCodingKey("sourceCharacters"))
        try c.encodeIfPresent(historyCharacters, forKey: AnyCodingKey("historyCharacters"))
        try c.encodeIfPresent(coverageLabels, forKey: AnyCodingKey("coverageLabels"))
        try c.encodeIfPresent(matched, forKey: AnyCodingKey("matched"))
        try c.encodeIfPresent(complete, forKey: AnyCodingKey("complete"))
        try c.encodeIfPresent(rationale, forKey: AnyCodingKey("rationale"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}
