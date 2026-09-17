import Foundation

/// A slash command the app handles itself, before any model call.
public struct ChatCommand: Codable, Sendable, Equatable, Hashable {
    public enum Name: Codable, Sendable, Equatable, Hashable {
        /// Start a new conversation.
        case new
        /// Clear this conversation's turns.
        case clear
        /// An app-defined command, preserved verbatim (RTI's `/meeting`,
        /// `/notes`, and the rest).
        case known(String)

        public var rawValue: String {
            switch self {
            case .new: "/new"
            case .clear: "/clear"
            case .known(let name): name
            }
        }

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "/new", "new": self = .new
            case "/clear", "clear": self = .clear
            default: self = .known(raw)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public var name: Name
    /// What the user typed, including the slash.
    public var rawName: String
    public var arguments: [String]
    /// The whole line as typed.
    public var rawText: String

    public init(name: Name, rawName: String, arguments: [String] = [], rawText: String = "") {
        self.name = name
        self.rawName = rawName
        self.arguments = arguments
        self.rawText = rawText.isEmpty ? rawName : rawText
    }

    public var isBuiltin: Bool {
        switch name {
        case .new, .clear: true
        case .known: false
        }
    }
}

/// What one line of input is.
public enum ChatCommandParseResult: Sendable, Equatable {
    case command(ChatCommand)
    /// Ordinary prompt text; send it to the model.
    case notACommand
    /// A slash command this parser does not know. The caller shows
    /// `message` locally and never calls a model.
    case unknown(rawName: String, message: String)
    /// Whitespace only.
    case empty
}

/// Parses `/new`, `/clear`, any aliases the app configures, and the app's own
/// commands, so RTI's existing slash commands keep working unchanged.
///
/// An unrecognized slash command always produces `.unknown` with a local
/// message; it is never forwarded to a model as prompt text.
public struct ChatCommandParser: Sendable {
    /// The two commands every consumer of this package must handle.
    public static let builtinNames: Set<String> = ["/new", "/clear"]

    /// Extra command names this app recognizes, for example RTI's
    /// `["/meeting", "/notes", "/export"]`.
    public let knownCommands: Set<String>
    /// Alias to canonical name, for example `["/reset": "/clear"]`.
    public let aliases: [String: String]

    public init(knownCommands: Set<String> = [], aliases: [String: String] = [:]) {
        self.knownCommands = Set(knownCommands.map(Self.normalize))
        self.aliases = Dictionary(
            uniqueKeysWithValues: aliases.map { (Self.normalize($0.key), Self.normalize($0.value)) }
        )
    }

    public func parse(_ text: String) -> ChatCommandParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard trimmed.hasPrefix("/") else { return .notACommand }

        let pieces = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = pieces.first else { return .empty }
        let rawName = first
        let normalized = Self.normalize(rawName)
        let arguments = Array(pieces.dropFirst())

        let canonical = aliases[normalized] ?? normalized
        // A builtin is never shadowed by an alias.
        if let name = Self.builtin(for: normalized) {
            return .command(ChatCommand(name: name, rawName: rawName, arguments: arguments, rawText: trimmed))
        }
        if let name = Self.builtin(for: canonical) {
            return .command(ChatCommand(name: name, rawName: rawName, arguments: arguments, rawText: trimmed))
        }
        if knownCommands.contains(canonical) {
            return .command(ChatCommand(name: .known(canonical), rawName: rawName, arguments: arguments, rawText: trimmed))
        }
        return .unknown(
            rawName: rawName,
            message: "Unknown command \(rawName). This app handles /new and /clear itself."
        )
    }

    static func normalize(_ name: String) -> String {
        let lowered = name.lowercased()
        return lowered.hasPrefix("/") ? lowered : "/" + lowered
    }

    static func builtin(for name: String) -> ChatCommand.Name? {
        switch name {
        case "/new": .new
        case "/clear": .clear
        default: nil
        }
    }
}
