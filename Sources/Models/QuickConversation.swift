import Foundation

struct QuickConversation: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var providerID: UUID
    var model: String
    var messages: [QuickMessage]
    /// Set by Rename Chat; nil uses the first question.
    var customTitle: String?
    /// The first question as the user typed it: a saved-prompt alias
    /// included, but no expanded template and no Add Context preamble,
    /// both of which the first message's `content` carries for the model.
    /// The title is made from this. Nil in chats saved before v1.5.0.
    var titleSource: String?
    /// Pinned chats sort first and are never pruned by the history limit.
    var isPinned: Bool
    /// The tools this chat lets the model call. Nil uses the defaults; an
    /// assistant writes its own set here.
    var enabledTools: Set<ChatToolKind>?
    /// The assistant (a `SavedPrompt` with instructions) this chat runs as.
    /// Its instructions and context skills are the chat's system message;
    /// nil is a plain chat. A deleted assistant leaves a plain chat.
    var assistantID: UUID?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        providerID: UUID,
        model: String,
        messages: [QuickMessage] = [],
        customTitle: String? = nil,
        titleSource: String? = nil,
        isPinned: Bool = false,
        enabledTools: Set<ChatToolKind>? = nil,
        assistantID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.providerID = providerID
        self.model = model
        self.messages = messages
        self.customTitle = customTitle
        self.titleSource = titleSource
        self.isPinned = isPinned
        self.enabledTools = enabledTools
        self.assistantID = assistantID
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, updatedAt, providerID, model, messages, customTitle, titleSource, isPinned, enabledTools, assistantID
        case tasksEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        providerID = try c.decode(UUID.self, forKey: .providerID)
        model = try c.decode(String.self, forKey: .model)
        messages = try c.decode([QuickMessage].self, forKey: .messages)
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        titleSource = try c.decodeIfPresent(String.self, forKey: .titleSource)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        enabledTools = try c.decodeIfPresent(Set<ChatToolKind>.self, forKey: .enabledTools)
        if try c.decodeIfPresent(Bool.self, forKey: .tasksEnabled) == true {
            enabledTools?.insert(.tasks)
        }
        assistantID = try c.decodeIfPresent(UUID.self, forKey: .assistantID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(customTitle, forKey: .customTitle)
        try c.encodeIfPresent(titleSource, forKey: .titleSource)
        try c.encode(isPinned, forKey: .isPinned)
        if var tools = enabledTools {
            let tasksEnabled = tools.remove(.tasks) != nil
            try c.encode(tools, forKey: .enabledTools)
            try c.encode(tasksEnabled, forKey: .tasksEnabled)
        }
        try c.encodeIfPresent(assistantID, forKey: .assistantID)
    }

    /// The chat's name without the saved-prompt list, so no leading
    /// `/token` is taken for an alias. The view model passes the configured
    /// prefix and aliases to `title(aliasPrefix:aliases:)`.
    var title: String { title(aliasPrefix: "/", aliases: []) }

    /// Rename Chat's name when set, else the first question, as typed,
    /// cleaned up into a title (`cleanTitle(from:aliasPrefix:aliases:)`).
    /// When the typed text leaves nothing (a bare `/alias` run on a
    /// selection), or the chat predates `titleSource`, the first message
    /// the model got is used instead.
    func title(aliasPrefix: String, aliases: Set<String>) -> String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let titleSource,
           let title = Self.cleanTitle(from: titleSource, aliasPrefix: aliasPrefix, aliases: aliases) {
            return title
        }
        return messages.first(where: { $0.role == .user })
            .flatMap { Self.cleanTitle(from: $0.content, aliasPrefix: aliasPrefix, aliases: aliases) }
            ?? "New quick action"
    }

    /// Titles stay under this many characters.
    static let titleCharacterLimit = 60

    /// A question mark or full stop ends a question, not a title; a comma,
    /// colon, or semicolon is what a cut at a word boundary can leave.
    private static let titleTrailingPunctuation: Set<Character> = ["?", ".", ",", ":", ";"]

    /// A question made into a title: its first line without a leading
    /// saved-prompt `/alias` or a "search web" style command, trimmed, the
    /// first letter capitalised, cut at a word boundary under
    /// `titleCharacterLimit`, and without trailing punctuation ("?", ".",
    /// or what a cut leaves). Nil when nothing is left.
    ///
    /// A leading `/token` goes only when `token` is one of `aliases` (the
    /// configured saved prompts, matched exactly as the resolver matches
    /// them), so a question that starts with a path, like `/etc/hosts`,
    /// keeps it.
    static func cleanTitle(from question: String, aliasPrefix: String, aliases: Set<String>) -> String? {
        guard var text = question
            .split(whereSeparator: \.isNewline)
            .lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }

        if !aliasPrefix.isEmpty, text.hasPrefix(aliasPrefix) {
            let alias = text.dropFirst(aliasPrefix.count).prefix { !$0.isWhitespace }
            if !alias.isEmpty, aliases.contains(String(alias)) {
                text = String(text.dropFirst(aliasPrefix.count + alias.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        if let command = WebSearchIntentDetector.commandPrefixes.first(where: { prefix in
            guard text.prefix(prefix.count).lowercased() == prefix else { return false }
            let next = text.dropFirst(prefix.count).first
            return next == nil || next?.isWhitespace == true || next == ":"
        }) {
            text = String(text.dropFirst(command.count))
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
        }

        if text.count >= titleCharacterLimit {
            let head = text.prefix(titleCharacterLimit)
            if let lastSpace = head.lastIndex(where: \.isWhitespace) {
                text = String(head[head.startIndex..<lastSpace])
            } else {
                text = String(head.prefix(titleCharacterLimit - 1))
            }
        }
        text = text.trimmingCharacters(in: .whitespaces)
        while let last = text.last, Self.titleTrailingPunctuation.contains(last) {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        guard let first = text.first else { return nil }
        return first.uppercased() + text.dropFirst()
    }

    var lastAnswer: String? {
        messages.last(where: { $0.role == .assistant })?.content
    }

    /// The whole chat as plain text, each turn labelled with who said it:
    /// "You:" for the user and the model's display name for the answers.
    /// What Copy Chat puts on the clipboard.
    var labelledTranscript: String {
        let modelName = ModelProfile.displayName(forModelID: model)
        let answerLabel = modelName.isEmpty ? "Assistant" : modelName
        return messages
            .map { message in
                let label = message.role == .user ? "You" : answerLabel
                return "\(label): \(message.content.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            .joined(separator: "\n\n")
    }
}
