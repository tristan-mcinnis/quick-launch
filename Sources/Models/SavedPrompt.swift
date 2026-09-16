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

    init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// A stored hotkey with only the device-independent modifier bits, so a
    /// comparison never fails on the fn, keypad, or caps-lock noise a key
    /// event carries. Every stored and compared value goes through this.
    var normalized: ActionHotkey {
        ActionHotkey(
            keyCode: keyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: modifiers).overlayRelevant.rawValue
        )
    }

    /// Whether this is a usable shortcut: at least one of Ctrl, Option, Cmd.
    var isValidShortcut: Bool {
        QuickSettings.isValidHotkey(keyCode: keyCode, modifiers: modifiers)
    }

    /// Whether a key event is this hotkey.
    func matches(keyCode: UInt16, modifiers flags: NSEvent.ModifierFlags) -> Bool {
        let hotkey = normalized
        return hotkey.keyCode == keyCode && hotkey.modifiers == flags.overlayRelevant.rawValue
    }

    /// The recorded form of a built-in shortcut. Every built-in key has an
    /// ANSI code, and `ShortcutRegistryTests` asserts the round trip through
    /// `QuickSettings.keyName(for:)` for all of them.
    init(defaulting shortcut: KeyShortcut) {
        self.init(
            keyCode: shortcut.virtualKeyCode ?? 0,
            modifiers: NSEvent.ModifierFlags(rawValue: shortcut.modifiers).overlayRelevant.rawValue
        )
    }

    /// Decoding normalizes, so a hand-edited or older `modifiers` value with
    /// extra bits compares equal to the key it names.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stored = ActionHotkey(
            keyCode: try c.decode(UInt16.self, forKey: .keyCode),
            modifiers: try c.decode(UInt.self, forKey: .modifiers)
        )
        self = stored.normalized
    }

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
///
/// A saved prompt with `systemPrompt` set and no command is an **assistant**
/// (`isAssistant`): `<prefix><alias>` alone, ⌘K › Change Assistant, or its
/// hotkey starts or switches the Quick AI chat to it. Its instructions and
/// its `contextRefs` skills become the chat's system message, its tools the
/// chat's tool set, and its provider and model the chat's. With text after
/// the alias it still runs `prompt` as a one-shot transform.
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
    /// The instructions an assistant's chat starts with. Set, with no
    /// command, this saved prompt is an assistant.
    var systemPrompt: String?
    /// The tools an assistant's chat lets the model call, written to the
    /// chat's `QuickConversation.enabledTools`. Nil uses the chat defaults;
    /// an empty set offers no tools.
    var enabledTools: Set<ChatToolKind>?
    /// Skill names (folders of `~/.claude/skills`) an assistant's chat loads
    /// once, through `SkillLibrary`, into its system message. A name the
    /// library does not list is skipped.
    var contextRefs: [String]

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
        commandArguments: [String]? = nil,
        systemPrompt: String? = nil,
        enabledTools: Set<ChatToolKind>? = nil,
        contextRefs: [String] = []
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
        self.systemPrompt = systemPrompt
        self.enabledTools = enabledTools
        self.contextRefs = contextRefs
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
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        enabledTools = try c.decodeIfPresent(Set<ChatToolKind>.self, forKey: .enabledTools)
        contextRefs = try c.decodeIfPresent([String].self, forKey: .contextRefs) ?? []
    }

    /// True for an assistant: instructions set, and no command to run.
    var isAssistant: Bool {
        guard let systemPrompt,
              !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return commandExecutable?.isEmpty ?? true
    }
}

// MARK: - Assistant edits (the Settings editor's fields)

extension SavedPrompt {
    /// The Instructions field. Blank text clears it, and with it the
    /// assistant: the saved prompt is a plain transform again.
    mutating func setInstructions(_ text: String) {
        systemPrompt = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Tools › Chat defaults (`nil`) or Choose, which starts from every tool
    /// on so a choice only ever takes tools away.
    mutating func setToolsUseDefaults(_ useDefaults: Bool) {
        if useDefaults {
            enabledTools = nil
        } else if enabledTools == nil {
            enabledTools = Set(ChatToolKind.allCases)
        }
    }

    /// One tool toggle. Turning one on or off leaves Chat defaults.
    mutating func setTool(_ tool: ChatToolKind, enabled: Bool) {
        var tools = enabledTools ?? Set(ChatToolKind.allCases)
        if enabled { tools.insert(tool) } else { tools.remove(tool) }
        enabledTools = tools
    }

    /// Adds a context skill once, at the end; a blank name is ignored.
    mutating func addContextRef(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !contextRefs.contains(name) else { return }
        contextRefs.append(name)
    }

    mutating func removeContextRef(_ name: String) {
        contextRefs.removeAll { $0 == name }
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
    ] + assistantDefaults

    /// The assistants a fresh install has, and the ones configuration
    /// version 25 adds to an existing install when their alias is free.
    static let assistantDefaults: [SavedPrompt] = [
        SavedPrompt(
            name: "Vault researcher",
            alias: "vault",
            prompt: "Find what my vault and memory say about the following. Cite the source of every fact.\n\n{selection}",
            systemPrompt: """
            You research the user's own notes. Before you answer, search the vault and memory for what they say about the question. \
            Cite the source of every fact you use: the note path or the memory entry it came from. \
            If the vault and memory have nothing on it, say so. Do not fill the gap with a guess.
            """,
            enabledTools: [.vault, .memory]
        ),
        SavedPrompt(
            name: "STE editor",
            alias: "ste",
            prompt: "Rewrite the following text in ASD-STE100 Simplified Technical English. Return only the rewritten text.\n\n{selection}",
            systemPrompt: """
            You edit text into ASD-STE100 Simplified Technical English. Rewrite the text you get so it obeys these rules:
            - Use approved words with their approved meaning only: one word, one meaning. Keep technical names and technical verbs.
            - Keep sentences short: 20 words or fewer in procedures, 25 or fewer in descriptions.
            - Write one instruction or one idea in each sentence.
            - Use the active voice. Write instructions in the imperative.
            - Use only the present, the simple past, and the simple future tense.
            - Do not use the -ing form of a verb as a verb or an adjective.
            - Use articles (the, a) and demonstratives (this, these) where you can.
            - Keep every fact, number, and name. Do not add content.
            Return only the rewritten text, unless the user asks a question about STE.
            """,
            enabledTools: []
        ),
    ]
}
