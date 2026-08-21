import Foundation
import AppKit  // for NSEvent.ModifierFlags

struct QuickSettings: Codable, Sendable {
    // Increment when a one-time settings migration is required.
    var configurationVersion: Int = 8

    // Hotkey — stored as key code + modifier flags raw value
    var hotkeyKeyCode: UInt16 = 49       // Space bar
    var hotkeyModifiers: UInt = 524288   // Option key (NSEvent.ModifierFlags.option.rawValue)

    // Behaviour
    var autoCopy: Bool = true            // Auto-copy result to clipboard when streaming completes
    var launchAtLogin: Bool = true       // Start at login
    var showMenuBar: Bool = true         // Show status bar icon
    var caffeinateEnabled: Bool = true    // Keep this Mac awake while Quick Launch runs

    // Updates
    var checkForUpdatesOnLaunch: Bool = false

    // First run
    var hasSeenWelcome: Bool = false
    var launchAtLoginPromptShown: Bool = false

    // Saved prompts (aliases)
    var savedPromptPrefix: String = "/"
    var savedPrompts: [SavedPrompt] = SavedPrompt.defaults
    var launcherItemConfigurations: [LauncherItemConfiguration] = []

    // Clipboard history
    var clipboardHistoryEnabled: Bool = true
    var clipboardHistoryLimit: Int = 50
    var clipboardHistoryHotkey: ActionHotkey = ActionHotkey(
        keyCode: 9,
        modifiers: 1_048_576 | 131_072
    )

    // Appearance
    var appearance: AppearancePreference = .system

    // MCP servers (attached to apfel --serve at launch)
    var mcpServers: [MCPServerConfig] = []

    // Inference providers and the current model
    var providers: [InferenceProvider] = InferenceProvider.defaults
    var selectedProviderID: UUID = InferenceProvider.managedApfelID
    var systemPrompt: String = QuickSettings.defaultSystemPrompt

    // Lightweight follow-up history
    var historyEnabled: Bool = true
    var historyLimit: Int = 20
    var newConversationAfterMinutes: Int = 15
    var reopenRetentionSeconds: Int = 10

    // Persistence key
    static let defaultsKey = "QuickSettings"

    // Custom decoder so settings blobs written before a field was added
    // still load cleanly, falling back to each field's default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedConfigurationVersion = try c.decodeIfPresent(
            Int.self,
            forKey: .configurationVersion
        ) ?? 0
        configurationVersion = 8
        hotkeyKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .hotkeyKeyCode) ?? 49
        hotkeyModifiers = try c.decodeIfPresent(UInt.self, forKey: .hotkeyModifiers) ?? 524288
        autoCopy = try c.decodeIfPresent(Bool.self, forKey: .autoCopy) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        showMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? true
        caffeinateEnabled = try c.decodeIfPresent(Bool.self, forKey: .caffeinateEnabled) ?? true
        checkForUpdatesOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdatesOnLaunch) ?? false
        hasSeenWelcome = try c.decodeIfPresent(Bool.self, forKey: .hasSeenWelcome) ?? false
        launchAtLoginPromptShown = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginPromptShown) ?? false
        savedPromptPrefix = try c.decodeIfPresent(String.self, forKey: .savedPromptPrefix) ?? "/"
        savedPrompts = try c.decodeIfPresent([SavedPrompt].self, forKey: .savedPrompts) ?? SavedPrompt.defaults
        launcherItemConfigurations = try c.decodeIfPresent(
            [LauncherItemConfiguration].self,
            forKey: .launcherItemConfigurations
        ) ?? []
        clipboardHistoryEnabled = try c.decodeIfPresent(
            Bool.self,
            forKey: .clipboardHistoryEnabled
        ) ?? true
        clipboardHistoryLimit = try c.decodeIfPresent(
            Int.self,
            forKey: .clipboardHistoryLimit
        ) ?? 50
        clipboardHistoryHotkey = try c.decodeIfPresent(
            ActionHotkey.self,
            forKey: .clipboardHistoryHotkey
        ) ?? ActionHotkey(keyCode: 9, modifiers: 1_048_576 | 131_072)
        appearance = try c.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
        mcpServers = try c.decodeIfPresent([MCPServerConfig].self, forKey: .mcpServers) ?? []
        providers = try c.decodeIfPresent([InferenceProvider].self, forKey: .providers)
            ?? InferenceProvider.defaults
        selectedProviderID = try c.decodeIfPresent(UUID.self, forKey: .selectedProviderID)
            ?? InferenceProvider.managedApfelID
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? Self.defaultSystemPrompt
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 20
        newConversationAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .newConversationAfterMinutes) ?? 15
        reopenRetentionSeconds = try c.decodeIfPresent(
            Int.self,
            forKey: .reopenRetentionSeconds
        ) ?? 10
        if decodedConfigurationVersion < 1,
           !savedPrompts.contains(where: { $0.alias == "search" }),
           let search = SavedPrompt.defaults.first(where: { $0.alias == "search" }) {
            savedPrompts.append(search)
        }
        if decodedConfigurationVersion < 2 {
            if let index = savedPrompts.firstIndex(where: { $0.alias == "translate" }) {
                savedPrompts[index].outputBehavior = .replaceSelection
            }
            if let index = savedPrompts.firstIndex(where: { $0.alias == "grammar" }) {
                savedPrompts[index].outputBehavior = .replaceSelection
            }
            if let index = savedPrompts.firstIndex(where: { $0.alias == "tldr" }),
               savedPrompts[index].hotkey == nil {
                savedPrompts[index].hotkey = ActionHotkey(
                    keyCode: 1,
                    modifiers: 262_144 | 524_288
                )
            }
        }
        if decodedConfigurationVersion < 3 {
            let preferredNames = [
                "translate": (old: "Translate", new: "Translate to English"),
                "grammar": (old: "Grammar", new: "Clean Up"),
                "tldr": (old: "Tldr", new: "Summarize"),
                "email": (old: "Email", new: "Rewrite as Email"),
            ]
            for (alias, names) in preferredNames {
                if let index = savedPrompts.firstIndex(where: {
                    $0.alias == alias && $0.name == names.old
                }) {
                    savedPrompts[index].name = names.new
                }
            }
        }
        if decodedConfigurationVersion < 7,
           !providers.contains(where: { $0.id == InferenceProvider.mlxVisionID }),
           let vision = InferenceProvider.defaults.first(where: {
               $0.id == InferenceProvider.mlxVisionID
           }) {
            providers.append(vision)
        }
    }

    init() {}
}

extension QuickSettings {
    static let defaultSystemPrompt: String = """
    You are a fast, direct assistant in a Spotlight-style action overlay. \
    Return only the result the user asked for. No preamble, no postamble, \
    no apologies, no disclaimers, and no invitation to continue. Be concise.
    """

    var selectedProvider: InferenceProvider? {
        providers.first(where: { $0.id == selectedProviderID }) ?? providers.first
    }

    var selectedModel: String {
        selectedProvider?.selectedModel ?? ""
    }

    mutating func select(providerID: UUID, model: String? = nil) {
        guard let index = providers.firstIndex(where: { $0.id == providerID }) else { return }
        selectedProviderID = providerID
        if let model, !model.isEmpty {
            providers[index].selectedModel = model
            if !providers[index].models.contains(model) {
                providers[index].models.append(model)
                providers[index].models.sort()
            }
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> QuickSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(QuickSettings.self, from: data)
        else { return QuickSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: QuickSettings.defaultsKey)
        }
    }
}

// MARK: - Hotkey display and validation

extension QuickSettings {

    /// Human-readable hotkey label, e.g. "\u{2325}Space" for Option+Space.
    var hotkeyDisplayName: String {
        let flags = NSEvent.ModifierFlags(rawValue: hotkeyModifiers)
        var parts: [String] = []
        if flags.contains(.control) { parts.append("\u{2303}") }
        if flags.contains(.option)  { parts.append("\u{2325}") }
        if flags.contains(.shift)   { parts.append("\u{21E7}") }
        if flags.contains(.command) { parts.append("\u{2318}") }
        parts.append(Self.keyName(for: hotkeyKeyCode))
        return parts.joined()
    }

    /// Whether a hotkey combo is valid (must include Ctrl, Option, or Cmd).
    static func isValidHotkey(keyCode: UInt16, modifiers: UInt) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection(.deviceIndependentFlagsMask)
        return flags.contains(.control)
            || flags.contains(.option)
            || flags.contains(.command)
    }

    static func knownSystemHotkeyConflict(
        keyCode: UInt16,
        modifiers: UInt
    ) -> String? {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        if keyCode == 49, flags == [.command] {
            return "Command+Space is reserved by Spotlight. Choose another shortcut."
        }
        return nil
    }

    /// Map key codes to display names.
    static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "\u{21A9}"   // Return
        case 48: return "\u{21E5}"   // Tab
        case 51: return "\u{232B}"   // Delete
        case 53: return "\u{238B}"   // Escape
        default:
            let letterMap: [UInt16: String] = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
                8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
                16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
                23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
                30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
                37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
                43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
                50: "`",
            ]
            return letterMap[keyCode] ?? "Key\(keyCode)"
        }
    }

    func actionHotkeyConflict(for actionID: UUID) -> String? {
        guard let action = savedPrompts.first(where: { $0.id == actionID }),
              let hotkey = action.hotkey else { return nil }
        if hotkey.keyCode == hotkeyKeyCode,
           hotkey.modifiers == hotkeyModifiers {
            return "This conflicts with the main Quick Launch hotkey."
        }
        if let other = savedPrompts.first(where: {
            $0.id != actionID && $0.hotkey == hotkey
        }) {
            return "This conflicts with \(other.name)."
        }
        if launcherItemConfigurations.contains(where: { $0.hotkey == hotkey }) {
            return "This conflicts with a launcher item hotkey."
        }
        if hotkey == clipboardHistoryHotkey {
            return "This conflicts with the Clipboard History hotkey."
        }
        return nil
    }

    func launcherItemConfiguration(
        kind: LauncherItemKind,
        itemID: String
    ) -> LauncherItemConfiguration? {
        launcherItemConfigurations.first {
            $0.kind == kind && $0.itemID == itemID
        }
    }

    func launcherItemHotkeyConflict(for configurationID: String) -> String? {
        guard let configuration = launcherItemConfigurations.first(where: {
            $0.id == configurationID
        }), let hotkey = configuration.hotkey else { return nil }

        if hotkey.keyCode == hotkeyKeyCode, hotkey.modifiers == hotkeyModifiers {
            return "This conflicts with the main Quick Launch hotkey."
        }
        if let conflict = Self.knownSystemHotkeyConflict(
            keyCode: hotkey.keyCode,
            modifiers: hotkey.modifiers
        ) {
            return conflict
        }
        if savedPrompts.contains(where: { $0.hotkey == hotkey }) {
            return "This conflicts with a quick-action hotkey."
        }
        if launcherItemConfigurations.contains(where: {
            $0.id != configurationID && $0.hotkey == hotkey
        }) {
            return "This conflicts with another launcher item."
        }
        if hotkey == clipboardHistoryHotkey {
            return "This conflicts with the Clipboard History hotkey."
        }
        return nil
    }

    func clipboardHistoryHotkeyConflict() -> String? {
        let hotkey = clipboardHistoryHotkey
        if hotkey.keyCode == hotkeyKeyCode, hotkey.modifiers == hotkeyModifiers {
            return "This conflicts with the main Quick Launch hotkey."
        }
        if let conflict = Self.knownSystemHotkeyConflict(
            keyCode: hotkey.keyCode,
            modifiers: hotkey.modifiers
        ) {
            return conflict
        }
        if savedPrompts.contains(where: { $0.hotkey == hotkey }) {
            return "This conflicts with a quick-action hotkey."
        }
        if launcherItemConfigurations.contains(where: { $0.hotkey == hotkey }) {
            return "This conflicts with a launcher item hotkey."
        }
        return nil
    }
}
