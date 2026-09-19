import Foundation

/// One message in a conversation, with the attachments it carried and the
/// receipt for the request it caused.
public struct TurnRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var role: TurnRole
    /// The prompt for a user turn, the answer for an assistant turn.
    public var text: String
    public var createdAt: Date?
    public var attachments: [AttachmentRecord]
    /// The concise model selection for this turn. The receipt holds the same
    /// choice plus the effective values and the timings.
    public var model: ModelSelection?
    public var request: RequestReceipt?
    public var toolRounds: [ToolRound]
    public var timings: TurnTimings
    /// The RTI session or QL window this turn belongs to, when it is not the
    /// conversation's own.
    public var sessionLinks: [SessionLink]
    public var error: String?
    /// Fields only this app models (QL's assistantID and the rest), kept
    /// namespaced so the shared schema stays the only owner of shared keys.
    public var appPayload: AppPayload?
    public var extra: ExtraFields

    public init(
        id: String = UUID().uuidString,
        role: TurnRole,
        text: String,
        createdAt: Date? = nil,
        attachments: [AttachmentRecord] = [],
        model: ModelSelection? = nil,
        request: RequestReceipt? = nil,
        toolRounds: [ToolRound] = [],
        timings: TurnTimings = TurnTimings(),
        sessionLinks: [SessionLink] = [],
        error: String? = nil,
        appPayload: AppPayload? = nil,
        extra: ExtraFields = ExtraFields()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
        self.model = model
        self.request = request
        self.toolRounds = toolRounds
        self.timings = timings
        self.sessionLinks = sessionLinks
        self.error = error
        self.appPayload = appPayload
        self.extra = extra
    }

    private static let knownKeys: Set<String> = [
        "id", "role", "text", "createdAt", "attachments", "model", "request",
        "toolRounds", "timings", "sessionLinks", "error", "appPayload",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        // Identity and content are required; only metadata is optional.
        self.id = try c.decodeNonEmptyString(forKey: AnyCodingKey("id"))
        self.role = try c.decode(TurnRole.self, forKey: AnyCodingKey("role"))
        self.text = try c.decode(String.self, forKey: AnyCodingKey("text"))
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("createdAt"))
        // Content-bearing arrays: an absent key or an explicit null is a
        // damaged record, never a silently thinned one. An empty array is legal.
        self.attachments = try c.decode([AttachmentRecord].self, forKey: AnyCodingKey("attachments"))
        self.model = try c.decodeIfPresent(ModelSelection.self, forKey: AnyCodingKey("model"))
        self.request = try c.decodeIfPresent(RequestReceipt.self, forKey: AnyCodingKey("request"))
        self.toolRounds = try c.decode([ToolRound].self, forKey: AnyCodingKey("toolRounds"))
        self.timings = try c.decodeIfPresent(TurnTimings.self, forKey: AnyCodingKey("timings")) ?? TurnTimings()
        self.sessionLinks = try c.decode([SessionLink].self, forKey: AnyCodingKey("sessionLinks"))
        self.error = try c.decodeIfPresent(String.self, forKey: AnyCodingKey("error"))
        self.appPayload = try c.decodeIfPresent(AppPayload.self, forKey: AnyCodingKey("appPayload"))
        self.extra = c.extras(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(id, forKey: AnyCodingKey("id"))
        try c.encode(role, forKey: AnyCodingKey("role"))
        try c.encode(text, forKey: AnyCodingKey("text"))
        try c.encodeIfPresent(createdAt, forKey: AnyCodingKey("createdAt"))
        try c.encode(attachments, forKey: AnyCodingKey("attachments"))
        try c.encodeIfPresent(model, forKey: AnyCodingKey("model"))
        try c.encodeIfPresent(request, forKey: AnyCodingKey("request"))
        try c.encode(toolRounds, forKey: AnyCodingKey("toolRounds"))
        try c.encode(timings, forKey: AnyCodingKey("timings"))
        try c.encode(sessionLinks, forKey: AnyCodingKey("sessionLinks"))
        try c.encodeIfPresent(error, forKey: AnyCodingKey("error"))
        try c.encodeIfPresent(appPayload, forKey: AnyCodingKey("appPayload"))
        try c.encodeExtras(extra, excluding: Self.knownKeys)
    }
}
