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

    init(
        id: UUID = UUID(),
        name: String? = nil,
        alias: String,
        prompt: String,
        providerID: UUID? = nil,
        model: String? = nil,
        outputBehavior: ActionOutputBehavior = .showInOverlay,
        hotkey: ActionHotkey? = nil
    ) {
        self.id = id
        self.name = name ?? alias.replacingOccurrences(of: "-", with: " ").capitalized
        self.alias = alias
        self.prompt = prompt
        self.providerID = providerID
        self.model = model
        self.outputBehavior = outputBehavior
        self.hotkey = hotkey
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
    }
}

extension SavedPrompt {
    /// Useful starter set seeded on first launch. Users can edit or remove.
    static let defaults: [SavedPrompt] = [
        SavedPrompt(
            name: "Translate to English",
            alias: "translate",
            prompt: "Translate the following text to English. Return only the translation, no preamble.\n\n{selection}",
            outputBehavior: .replaceSelection
        ),
        SavedPrompt(
            name: "Translate to Chinese",
            alias: "zh",
            prompt: "Translate the following text to Simplified Chinese. Keep names, numbers, and formatting. Return only the translation, no preamble.\n\n{selection}",
            outputBehavior: .replaceSelection
        ),
        SavedPrompt(
            name: "Clean Up",
            alias: "grammar",
            prompt: "Fix grammar and spelling. Return only the corrected text, no explanations.\n\n{selection}",
            outputBehavior: .replaceSelection
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
