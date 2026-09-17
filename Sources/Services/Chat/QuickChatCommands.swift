import Foundation
import HouseChatCore

/// What one line of composer input is, in Quick-Launch-native terms.
enum QuickChatCommandOutcome: Equatable, Sendable {
    /// `/new`: start a fresh chat, keeping the old saved thread.
    case newChat
    /// `/clear`: clear this chat's turns and pending context, keep history.
    case clearChat
    /// An app command this build knows (`/meeting` and the like; none today).
    case appCommand(name: String, arguments: [String])
    /// A slash command this build does not know. Shown locally, never sent.
    case unknownCommand(rawName: String, message: String)
    /// Ordinary prompt text.
    case notACommand
}

/// Reserves Quick Launch's built-in slash commands before any prompt alias
/// is consulted, so a saved prompt can never shadow `/new` or `/clear`.
///
/// RTI passes its own command names; Quick Launch has none today, so the
/// router only routes the two built-ins and reports every other slash line
/// locally instead of forwarding it to a model as prompt text.
struct QuickChatCommandRouter: Sendable {
    static let standard = QuickChatCommandRouter()

    let parser: ChatCommandParser

    init(knownCommands: Set<String> = [], aliases: [String: String] = [:]) {
        self.parser = ChatCommandParser(knownCommands: knownCommands, aliases: aliases)
    }

    func route(_ input: String) -> QuickChatCommandOutcome {
        switch parser.parse(input) {
        case .command(let command):
            switch command.name {
            case .new: return .newChat
            case .clear: return .clearChat
            case .known(let name): return .appCommand(name: name, arguments: command.arguments)
            }
        case .unknown(let rawName, let message):
            return .unknownCommand(rawName: rawName, message: message)
        case .notACommand, .empty:
            return .notACommand
        }
    }
}
