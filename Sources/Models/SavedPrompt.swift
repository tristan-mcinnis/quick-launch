import Foundation
import AppKit

enum ActionOutputBehavior: String, Codable, Sendable, CaseIterable, Hashable {
    case showInOverlay
    case replaceSelection

    var displayName: String {
        switch self {
        case .showInOverlay: "Show in Quick Launch"
        case .replaceSelection: "Replace selected text"
        }
    }
}

struct ActionHotkey: Codable, Sendable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt

    /// Modifier symbols and the key, one entry per key cap: `["⌥", "⌘", "←"]`.
    var keyCaps: [String] {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var caps: [String] = []
        if flags.contains(.control) { caps.append("\u{2303}") }
        if flags.contains(.option)  { caps.append("\u{2325}") }
        if flags.contains(.shift)   { caps.append("\u{21E7}") }
        if flags.contains(.command) { caps.append("\u{2318}") }
        caps.append(QuickSettings.keyName(for: keyCode))
        return caps
    }

    /// Compact form for labels and accessibility: `⌥⌘←`.
    var displayName: String { keyCaps.joined() }
}

/// A saved prompt users can invoke with `<prefix><alias>`, e.g. `/translate`.
/// The `prompt` field is the full expansion sent to the selected provider.
struct SavedPrompt: Codable, Sendable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var alias: String
    var prompt: String
    /// Nil inherits the active provider and model.
    var providerID: UUID?
    var model: String?
    var outputBehavior: ActionOutputBehavior
    var hotkey: ActionHotkey?
    /// When set, the action runs this executable directly (never through a
    /// shell) instead of sending the prompt to a model provider.
    var commandExecutable: String?
    /// Argv for `commandExecutable`. `{input}` is replaced within each
    /// element, so user text stays a single argument.
    var commandArguments: [String]?

    init(
        id: UUID = UUID(),
        name: String? = nil,
        alias: String,
        prompt: String,
        providerID: UUID? = nil,
        model: String? = nil,
        outputBehavior: ActionOutputBehavior = .showInOverlay,
        hotkey: ActionHotkey? = nil,
        commandExecutable: String? = nil,
        commandArguments: [String]? = nil
    ) {
        self.id = id
        self.name = name ?? alias.replacingOccurrences(of: "-", with: " ").capitalized
        self.alias = alias
        self.prompt = prompt
        self.providerID = providerID
        self.model = model
        self.outputBehavior = outputBehavior
        self.hotkey = hotkey
        self.commandExecutable = commandExecutable
        self.commandArguments = commandArguments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        alias = try c.decode(String.self, forKey: .alias)
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? alias.replacingOccurrences(of: "-", with: " ").capitalized
        prompt = try c.decode(String.self, forKey: .prompt)
        providerID = try c.decodeIfPresent(UUID.self, forKey: .providerID)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        outputBehavior = try c.decodeIfPresent(
            ActionOutputBehavior.self,
            forKey: .outputBehavior
        ) ?? .showInOverlay
        hotkey = try c.decodeIfPresent(ActionHotkey.self, forKey: .hotkey)
        commandExecutable = try c.decodeIfPresent(String.self, forKey: .commandExecutable)
        commandArguments = try c.decodeIfPresent([String].self, forKey: .commandArguments)
    }
}

extension SavedPrompt {
    /// Useful starter set seeded on first launch. Users can edit or remove.
    static let defaults: [SavedPrompt] = [
        SavedPrompt(
            name: "Translate to English",
            alias: "translate",
            prompt: "Translate the following text to English. Return only the translation, no preamble.\n\n{selection}",
            outputBehavior: .showInOverlay
        ),
        SavedPrompt(
            name: "Translate to Chinese",
            alias: "zh",
            prompt: "Translate the following text to Simplified Chinese. Keep names, numbers, and formatting. Return only the translation, no preamble.\n\n{selection}",
            outputBehavior: .showInOverlay
        ),
        SavedPrompt(
            name: "Clean Up",
            alias: "grammar",
            prompt: "Fix grammar and spelling. Return only the corrected text, no explanations.\n\n{selection}",
            outputBehavior: .showInOverlay
        ),
        SavedPrompt(
            name: "Improve Writing",
            alias: "improve",
            prompt: "Improve the writing of the following text: fix grammar, spelling, and punctuation, and make it clearer. Do not change the meaning, the tone, or the language it is in. Return only the improved text, no commentary. If the text is already correct, return it unchanged.\n\n{selection}",
            outputBehavior: .showInOverlay
        ),
        SavedPrompt(
            name: "Make Shorter",
            alias: "shorter",
            prompt: "Make the following text shorter while keeping everything that matters: the meaning, the style, the tone, the language it is in, and any key facts, names, numbers, and URLs. Cut redundancy and filler only. Return only the shorter text, no commentary.\n\n{selection}",
            outputBehavior: .showInOverlay
        ),
        SavedPrompt(
            name: "Turn into Bullets",
            alias: "bullets",
            prompt: "Restructure the following text into a bulleted list that keeps every substantive detail, fact, name, and number. Do not drop content or add anything new; preserve the tone and the language. Return only the bullets, no commentary.\n\n{selection}",
            outputBehavior: .showInOverlay
        ),
        SavedPrompt(
            name: "Summarize",
            alias: "tldr",
            prompt: "Summarize the following clearly and concisely. Preserve important facts and numbers.\n\n{selection}",
            hotkey: ActionHotkey(
                keyCode: 1,
                modifiers: 262_144 | 524_288
            )
        ),
        SavedPrompt(
            name: "Explain",
            alias: "explain",
            prompt: "Explain the following clearly and concisely. Assume the reader is a smart non-expert.\n\n{selection}"
        ),
        SavedPrompt(
            name: "Rewrite as Email",
            alias: "email",
            prompt: "Rewrite the following as a polite, professional email. Keep it short.\n\n{selection}"
        ),
        SavedPrompt(
            name: "Search",
            alias: "search",
            prompt: "Search for current, reliable information about the following. Give a concise answer and include source links.\n\n{selection}",
            providerID: InferenceProvider.piID
        ),
    ]
}
