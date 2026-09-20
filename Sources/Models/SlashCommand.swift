import Foundation

/// One row of the composer's `/` palette.
///
/// The palette does not invent commands. It shows what the composer already
/// answers to, which until now nothing named anywhere: the two built-ins,
/// every saved-prompt alias on the `/` prefix, and the skills in
/// `~/.claude/skills`. The placeholder has promised "/ for commands" since
/// v1.4 while typing `/` opened nothing.
struct SlashCommand: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `/new` and `/clear`, handled before any alias.
        case builtIn
        /// A saved prompt, expanded by `SavedPromptResolver` on send.
        case savedPrompt
        /// A folder in `~/.claude/skills`, whose `SKILL.md` is prepended to
        /// the question on send.
        case skill
    }

    /// The name without the prefix, as typed: `new`, `tldr`, `house-design`.
    let name: String
    let title: String
    let detail: String
    let kind: Kind

    var id: String { "\(kindOrder)-\(name)" }

    /// What the composer holds once the row is taken.
    func completion(prefix: String) -> String { prefix + name }

    /// Built-ins first, then the user's own prompts, then the skills, which
    /// are the longest list and the least often wanted.
    var kindOrder: Int {
        switch kind {
        case .builtIn: 0
        case .savedPrompt: 1
        case .skill: 2
        }
    }

    var systemImage: String {
        switch kind {
        case .builtIn: "command"
        case .savedPrompt: "text.bubble"
        case .skill: "book.closed"
        }
    }

    /// The section label drawn beside the row.
    var kindLabel: String {
        switch kind {
        case .builtIn: "Command"
        case .savedPrompt: "Prompt"
        case .skill: "Skill"
        }
    }

    static let newChat = SlashCommand(
        name: "new",
        title: "New Chat",
        detail: "Start a fresh chat, keeping the saved one",
        kind: .builtIn
    )

    static let clearChat = SlashCommand(
        name: "clear",
        title: "Clear Chat",
        detail: "Clear this chat's turns and pending context",
        kind: .builtIn
    )

    static let builtIns: [SlashCommand] = [.newChat, .clearChat]
}
