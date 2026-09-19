import Foundation

/// Where one request ended.
public enum RequestStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case streaming
    case completed
    case cancelled
    case failed
    /// A local decision refused the request before any model call, for
    /// example an unknown slash command.
    case refused
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RequestStatus(rawValue: raw) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The full telemetry of one model request: what was chosen, what was
/// effective, what context was allowed, what was sent by hash, which tool
/// rounds ran, what it cost, and how long it took.
public struct RequestReceipt: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Chosen vs effective provider, model, and thinking level.
    public var selection: ModelSelection?
    public var status: RequestStatus
    /// The retrieval decision the consumer enforced.
    public var context: ContextReceipt?
    /// The exact source bytes this request pointed at.
    public var attachmentRefs: [AttachmentSnapshotRef]
    public var toolRounds: [ToolRound]
    public var timings: RequestTimings
    public var usage: TokenUsage?
    /// Where the request went, sanitized: no userinfo, no query string.
    /// Credentials are never part of this type, so they cannot be encoded.
    public var endpoint: EndpointDescriptor?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var error: String?
    public var extra: ExtraFields

    public init(
        id: String = UUID().uuidString,
        selection: ModelSelection? = nil,
        status: RequestStatus = .unknown,
        context: ContextReceipt? = nil,
        attachmentRefs: [AttachmentSnapshotRef] = [],
        toolRounds: [ToolRound] = [],
        timings: RequestTimings = RequestTimings(),
        usage: TokenUsage? = nil,
        endpoint: EndpointDescriptor? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        error: String? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.id = id
        self.selection = selection
        self.status = status
        self.context = context
        self.attachmentRefs = attachmentRefs
        self.toolRounds = toolRounds
        self.timings = timings
        self.usage = usage
        self.endpoint = endpoint
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "id", "selection", "status", "context", "attachmentRefs", "toolRounds",
        "timings", "usage", "endpoint", "startedAt", "finishedAt", "error",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        self.id = try c.decodeNonEmptyString(forKey: AnyCodingKey("id"))
        self.selection = try c.decodeIfPresent(ModelSelection.self, forKey: AnyCodingKey("selection"))
        self.status = try c.decodeIfPresent(RequestStatus.self, forKey: AnyCodingKey("status")) ?? .unknown
        self.context = try c.decodeIfPresent(ContextReceipt.self, forKey: AnyCodingKey("context"))
        // Content-bearing arrays: an absent key or an explicit null is a
        // damaged receipt, never a silently thinned one. An empty array is legal.
        self.attachmentRefs = try c.decode([AttachmentSnapshotRef].self, forKey: AnyCodingKey("attachmentRefs"))
        self.toolRounds = try c.decode([ToolRound].self, forKey: AnyCodingKey("toolRounds"))
        self.timings = try c.decodeIfPresent(RequestTimings.self, forKey: AnyCodingKey("timings")) ?? RequestTimings()
        self.usage = try c.decodeIfPresent(TokenUsage.self, forKey: AnyCodingKey("usage"))
        self.endpoint = try c.decodeIfPresent(EndpointDescriptor.self, forKey: AnyCodingKey("endpoint"))
        self.startedAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("startedAt"))
        self.finishedAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("finishedAt"))
        self.error = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("error"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(id, forKey: AnyCodingKey("id"))
        try c.encodeIfPresent(selection, forKey: AnyCodingKey("selection"))
        try c.encode(status, forKey: AnyCodingKey("status"))
        try c.encodeIfPresent(context, forKey: AnyCodingKey("context"))
        try c.encode(attachmentRefs, forKey: AnyCodingKey("attachmentRefs"))
        try c.encode(toolRounds, forKey: AnyCodingKey("toolRounds"))
        try c.encode(timings, forKey: AnyCodingKey("timings"))
        try c.encodeIfPresent(usage, forKey: AnyCodingKey("usage"))
        try c.encodeIfPresent(endpoint, forKey: AnyCodingKey("endpoint"))
        try c.encodeIfPresent(startedAt, forKey: AnyCodingKey("startedAt"))
        try c.encodeIfPresent(finishedAt, forKey: AnyCodingKey("finishedAt"))
        try c.encodeIfPresent(error, forKey: AnyCodingKey("error"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }

    /// The same receipt with free text scrubbed of credential-shaped content.
    ///
    /// The typed `endpoint` is already sanitized when it is built. What no type
    /// can protect is free text: a provider error that echoes the URL it
    /// called, a tool argument, a result summary. The package never rewrites
    /// what it is given, so a consumer that may hold such text calls this
    /// before writing. It touches only `error` and the tool call text.
    public func sanitizedForStorage() -> RequestReceipt {
        var copy = self
        if let error { copy.error = SecretRedactor.redact(error) }
        copy.toolRounds = toolRounds.map { round in
            var round = round
            round.calls = round.calls.map { call in
                var call = call
                if let arguments = call.arguments { call.arguments = SecretRedactor.redact(arguments) }
                if let summary = call.resultSummary { call.resultSummary = SecretRedactor.redact(summary) }
                if let error = call.error { call.error = SecretRedactor.redact(error) }
                return call
            }
            return round
        }
        return copy
    }
}
