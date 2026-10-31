import Foundation
import AppKit  // for NSEvent.ModifierFlags

enum TypeToClickContinuation: String, Codable, CaseIterable, Sendable {
    case continuous
    case singleAction

    var displayName: String {
        switch self {
        case .continuous: "Stay open and rescan"
        case .singleAction: "Dismiss after one action"
        }
    }
}

/// What Return does on a finished Quick AI answer with the composer empty.
/// The answer is already on screen either way: this is delivery, not
/// generation, and it never touches how an answer is produced.
enum QuickAIPrimaryAction: String, Codable, CaseIterable, Sendable {
    case pasteToActiveApp
    case copyToClipboard

    var displayName: String {
        switch self {
        case .pasteToActiveApp: "Paste to active app"
        case .copyToClipboard: "Copy to clipboard"
        }
    }

    /// One line on what Return will do, for the settings row's detail. The
    /// AI Chat window has no app behind it, so there Return always copies.
    var detail: String {
        switch self {
        case .pasteToActiveApp:
            "In Quick AI, Return pastes the answer into the app behind. AI Chat always copies."
        case .copyToClipboard:
            "Return copies the answer, in Quick AI and in AI Chat."
        }
    }
}

/// When the current chat is replaced by a new one. Supersedes the raw minute
/// count that used to live in `newConversationAfterMinutes`.
///
/// The timed options are the old behaviour with a wider menu. `always` starts
/// a fresh chat for every question. `never` keeps the one thread until the
/// user starts a new chat by hand.
enum NewChatInterval: String, Codable, CaseIterable, Sendable, Identifiable {
    case fiveMinutes
    case tenMinutes
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case always
    case never

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fiveMinutes: "5 minutes"
        case .tenMinutes: "10 minutes"
        case .fifteenMinutes: "15 minutes"
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .always: "Always"
        case .never: "Never"
        }
    }

    /// The inactivity window in minutes. Nil for `always` and `never`, which
    /// are not windows.
    var minutes: Int? {
        switch self {
        case .fiveMinutes: 5
        case .tenMinutes: 10
        case .fifteenMinutes: 15
        case .thirtyMinutes: 30
        case .oneHour: 60
        case .always, .never: nil
        }
    }

    /// The nearest timed option to a legacy minute count. Ties go to the
    /// shorter window, so 7 minutes reads as 5 and 45 as 30.
    static func nearest(toMinutes minutes: Int) -> NewChatInterval {
        let options = allCases.filter { $0.minutes != nil }
        var best = options[0]
        for option in options {
            guard let candidate = option.minutes, let current = best.minutes else { continue }
            if abs(minutes - candidate) < abs(minutes - current) { best = option }
        }
        return best
    }
}

/// Identity of one entry in the Fallback Commands list.
///
/// An identifier, never a stored object: a command the user later deletes
/// leaves a stale id, which the runner reports instead of crashing.
enum FallbackCommandID {
    /// The Ask AI row: unmatched text streams to the model. The default.
    static let askAI = "askAI:ask"

    static func savedPrompt(_ id: UUID) -> String { "prompt:\(id.uuidString)" }
    static func command(_ itemID: String) -> String { "command:\(itemID)" }

    /// The saved AI command behind an identifier, or nil for another kind.
    static func savedPromptUUID(from identifier: String) -> UUID? {
        guard identifier.hasPrefix("prompt:") else { return nil }
        return UUID(uuidString: String(identifier.dropFirst("prompt:".count)))
    }

    /// The command catalog item id behind an identifier, or nil for another kind.
    static func commandItemID(from identifier: String) -> String? {
        guard identifier.hasPrefix("command:") else { return nil }
        let itemID = String(identifier.dropFirst("command:".count))
        return itemID.isEmpty ? nil : itemID
    }

    /// Command rows earlier builds offered and this one does not. Settings
    /// that name one (a Fallback Commands row, an alias, a hotkey) drop it on
    /// load, so the rest of the saved settings still decode and apply.
    static let retiredCommandItemIDs: Set<String> = ["speech.readAloud", "speech.stop"]

    static func isRetired(_ identifier: String) -> Bool {
        commandItemID(from: identifier).map(retiredCommandItemIDs.contains) ?? false
    }
}

struct QuickSettings: Codable, Sendable {
    // Increment when a one-time settings migration is required.
    var configurationVersion: Int = 28

    // Hotkey — stored as key code + modifier flags raw value
    var hotkeyKeyCode: UInt16 = 49       // Space bar
    var hotkeyModifiers: UInt = 524288   // Option key (NSEvent.ModifierFlags.option.rawValue)

    // Behaviour
    var autoCopy: Bool = true            // Auto-copy result to clipboard when streaming completes
    var launchAtLogin: Bool = true       // Start at login
    var showMenuBar: Bool = true         // Show status bar icon
    var caffeinateEnabled: Bool = true    // Keep this Mac awake while Quick Launch runs
    /// Manual timed session to restore after a relaunch.
    var caffeinateUntil: Date?
    var caffeinateAgentWatch: Bool = true
    /// On battery at or below this percent, sleep is allowed again. 0 disables.
    var caffeinateBatteryCutoff: Int = 20
    var caffeinateKeepDisplayAwake: Bool = false
    /// Double tap of the right ⌘ key sends the focused window to AI.
    var screenAwarenessDoubleTap: Bool = true
    /// Read text inside screenshots with on-device OCR for search.
    var screenshotTextSearch: Bool = true
    /// Opening the launcher attaches an image copied since the last open.
    /// Off by default (2026-10-30): a screenshot copied for somewhere else
    /// rode the next question uninvited. Paste and the capture keys attach
    /// on request either way.
    var attachClipboardImageOnOpen: Bool = false

    // Updates
    var checkForUpdatesOnLaunch: Bool = false

    // First run
    var launchAtLoginPromptShown: Bool = false

    // Saved prompts (aliases)
    var savedPromptPrefix: String = "/"
    var savedPrompts: [SavedPrompt] = SavedPrompt.defaults
    var launcherItemConfigurations: [LauncherItemConfiguration] = Self.defaultWindowConfigurations + Self.defaultFolderConfigurations
    /// Rank launcher results by what was chosen before (local only).
    var launcherLearningEnabled: Bool = true
    // Interaction journal: a local-only, bounded review log of launcher and
    // AI *outcomes* (choices, abandoned searches, retries, failures). It stores
    // no content, never leaves this Mac, and never feeds ranking.
    var interactionJournalEnabled: Bool = true
    var interactionJournalRetentionDays: Int = 30
    var interactionJournalEventCap: Int = 2000
    /// Bundle identifier of the browser that opens Quick Links; nil = system default.
    var quickLinkBrowserBundleID: String?
    /// Folders added in Settings › Items beside the built-in user folders.
    var customFolders: [FolderLocation] = []
    /// `.app` bundles outside the scanned Applications folders.
    var customApplicationPaths: [String] = []

    // Clipboard history
    var clipboardHistoryEnabled: Bool = true
    var clipboardHistoryLimit: Int = 50
    var clipboardHistoryHotkey: ActionHotkey = ActionHotkey(
        keyCode: 9,
        modifiers: 1_048_576 | 131_072
    )
    /// How long an *unpinned* clipboard entry lives. Opt-in: `forever` by
    /// default, so an existing history is never silently expired by an update.
    /// Pinned entries are always kept.
    var clipboardHistoryRetention: ClipboardRetention = .forever
    /// Bundle identifiers whose copies are never recorded. Ships empty; the
    /// concealed/transient markers are honoured whatever this says.
    var clipboardHistoryDisabledSourceBundleIDs: [String] = []
    /// Record Universal Clipboard copies that arrive from another device. Off
    /// by default; never bypasses a privacy marker.
    var clipboardHistoryCaptureRemote: Bool = false
    /// Recognize text from a copied image (on-device Vision) for search and
    /// the copy-text actions.
    var clipboardHistoryOCR: Bool = true
    /// Fast or accurate recognition for copied images.
    var clipboardHistoryOCRMode: ClipboardOCRMode = .accurate
    /// Attach a source-app tag to each entry for search and filtering.
    var clipboardHistorySourceTags: Bool = true

    // Screenshots browser
    /// Extra folders scanned beside the system screenshot folder. Empty means
    /// only the system folder. Paths are stored as strings (local data).
    var screenshotFolders: [String] = []
    /// Include every image and video in the scanned folders, not only files
    /// whose name looks like a screenshot.
    var screenshotIncludeAllMedia: Bool = false
    /// Fast or accurate recognition for saved screenshots.
    var screenshotOCRMode: ClipboardOCRMode = .accurate
    /// Grid columns for the screenshots browser.
    var screenshotColumns: Int = 3
    /// Show the screenshots browser as a grid instead of a list.
    var screenshotUseGrid: Bool = false

    /// 0 is the default yellow; 1...5 are the Fitzpatrick skin tone modifiers.
    var emojiSkinTone: Int = 0

    /// Keep the line breaks Vision found when copying text from the screen.
    var ocrKeepLineBreaks: Bool = true

    // Translator window (⇧⌘T by default)
    var translatorHotkey: ActionHotkey = ActionHotkey(keyCode: 17, modifiers: 1_048_576 | 131_072)
    var lastTranslationTarget: String = "zh-Hans"
    var lastTranslationSource: String = "en"
    /// "auto" detects the source per request; a language code fixes it.
    var translationSourceSelection: String = "auto"

    // Type to Click (⌃⌥C by default): show named targets, then fuzzy-filter controls and menus in the
    // app behind Quick Launch, then use Return to act. It stays open by
    // default, with an optional single-action dismissal. Disabling its direct
    // hotkey keeps the launcher command available.
    var typeToClickHotkey: ActionHotkey = ActionHotkey(keyCode: 8, modifiers: 262_144 | 524_288)
    var typeToClickHotkeyEnabled: Bool = true
    var typeToClickContinuation: TypeToClickContinuation = .continuous

    // The optional direct Quick AI hotkey, off by default: opens the Quick AI
    // composer on the app and selection behind, without sending anything.
    // Disabled until the user asks for it, so it never takes a combination
    // their own setup already uses. `⌥⌘Space` is free against every other
    // shipped key when they do enable it.
    var quickAIHotkey: ActionHotkey = ActionHotkey(keyCode: 49, modifiers: 1_048_576 | 524_288)
    var quickAIHotkeyEnabled: Bool = false

    // The user's in-app shortcut overrides, keyed by `ShortcutAction.rawValue`.
    // Empty on a fresh install and on every stored blob from before this
    // existed, so the built-in keys stay the built-in keys. One entry replaces
    // one action's key whole; the Keyboard Shortcuts pane writes them, and
    // `ShortcutBindings` is the only reader.
    var shortcutOverrides: [String: ActionHotkey] = [:]

    // Appearance
    var appearance: AppearancePreference = .dark

    // Inference providers and the current model
    var providers: [InferenceProvider] = InferenceProvider.defaults
    var selectedProviderID: UUID = InferenceProvider.deepSeekID
    /// Where attached screenshots go. DeepSeek's flash vision model by
    /// default; the local MLX server remains selectable for offline use.
    var visionProviderID: UUID = InferenceProvider.deepSeekID
    /// Model used with `visionProviderID`; empty means that provider's selected model.
    var visionModel: String = InferenceProvider.deepSeekVisionModel
    /// Quick AI's instruction: the direct overlay rule, and the one saved
    /// actions run under. AI Chat has its own field below.
    var systemPrompt: String = QuickSettings.defaultSystemPrompt
    /// AI Chat's instruction. It has its own default, so an edit on one
    /// surface never changes the other. A custom value is used as written;
    /// nothing is appended to it except the grounding sentence.
    var chatSystemPrompt: String = QuickSettings.defaultChatSystemPrompt

    // Chat history
    var historyEnabled: Bool = true
    /// Unpinned chats kept in history (Settings › History › Chats to keep).
    /// A new install starts at `QuickHistoryStore.defaultLimit`; a stored
    /// value, the old default 20 included, is kept.
    var historyLimit: Int = QuickHistoryStore.defaultLimit
    /// When a new chat replaces the last one. Replaces the old
    /// `newConversationAfterMinutes` count; the migration maps it.
    var newChatInterval: NewChatInterval = .fiveMinutes
    var reopenRetentionSeconds: Int = 10

    // Quick AI
    /// What Return does on a finished answer with the composer empty.
    /// Automatic copy (`autoCopy`) is untouched by this: it still governs
    /// what happens the moment a result arrives.
    var quickAIPrimaryAction: QuickAIPrimaryAction = .pasteToActiveApp
    /// Draw the ⇥ hint in root search. Tab asks Quick AI either way (math
    /// and conversions still answer in place).
    var tabShortcutHintVisible: Bool = true
    /// The provider and model the Quick AI surface answers with. Unset means
    /// the current selection, so the two can never disagree by accident.
    var quickAIProviderID: UUID?
    var quickAIModel: String = ""
    /// The commands unmatched root-search text runs on Return, in order. The
    /// first one runs. An empty list means Return runs nothing at all.
    var fallbackCommandIDs: [String] = [FallbackCommandID.askAI]
    /// Offer the model a `search_web` tool (backed by a search API) so it can
    /// look things up mid-answer instead of guessing from training data.
    var modelWebSearchEnabled: Bool = true
    /// Shared by explicit searches and model tool calls on every AI surface.
    var webSearchProvider: WebSearchProvider = .automatic
    /// The tools a new chat starts with (Settings › General › Chat). Web
    /// search is `modelWebSearchEnabled`, which the Translator reads too;
    /// `newChatTools` joins the four.
    var newChatMemoryEnabled: Bool = true
    var newChatTasksEnabled: Bool = true
    var newChatSkillsEnabled: Bool = true
    /// The size the user dragged the Quick AI surface to. The standard
    /// 750 × 475 until the first drag; never smaller than that. Root search
    /// is not user-sized and has no stored size.
    var quickAISize: QuickAISize = .standard

    // Persistence key
    static let defaultsKey = "QuickSettings"

    /// A key an earlier version wrote that this version reads once and maps.
    private enum LegacyCodingKeys: String, CodingKey {
        case newConversationAfterMinutes
    }

    // Custom decoder so settings blobs written before a field was added
    // still load cleanly, falling back to each field's default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedConfigurationVersion = try c.decodeIfPresent(
            Int.self,
            forKey: .configurationVersion
        ) ?? 0
        configurationVersion = 28
        // Read before the migration at the end: the old key is gone from this
        // version's keys, so it needs its own container.
        let legacyNewConversationAfterMinutes = try decoder.container(
            keyedBy: LegacyCodingKeys.self
        ).decodeIfPresent(Int.self, forKey: .newConversationAfterMinutes)
        hotkeyKeyCode = try c.decodeIfPresent(UInt16.self, forKey: .hotkeyKeyCode) ?? 49
        hotkeyModifiers = try c.decodeIfPresent(UInt.self, forKey: .hotkeyModifiers) ?? 524288
        autoCopy = try c.decodeIfPresent(Bool.self, forKey: .autoCopy) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        showMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showMenuBar) ?? true
        caffeinateEnabled = try c.decodeIfPresent(Bool.self, forKey: .caffeinateEnabled) ?? true
        checkForUpdatesOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdatesOnLaunch) ?? false
        launchAtLoginPromptShown = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginPromptShown) ?? false
        savedPromptPrefix = try c.decodeIfPresent(String.self, forKey: .savedPromptPrefix) ?? "/"
        savedPrompts = try c.decodeIfPresent([SavedPrompt].self, forKey: .savedPrompts) ?? SavedPrompt.defaults
        // Lossy: a record whose kind was retired (Screen History rows) is
        // dropped, instead of failing the whole blob and resetting every
        // setting to its default. A record for a retired command goes too.
        launcherItemConfigurations = (try c.decodeIfPresent(
            LossyDecodableArray<LauncherItemConfiguration>.self,
            forKey: .launcherItemConfigurations
        )?.elements ?? (Self.defaultWindowConfigurations + Self.defaultFolderConfigurations))
            .filter { !FallbackCommandID.isRetired($0.id) }
        launcherLearningEnabled = try c.decodeIfPresent(
            Bool.self,
            forKey: .launcherLearningEnabled
        ) ?? true
        interactionJournalEnabled = try c.decodeIfPresent(
            Bool.self,
            forKey: .interactionJournalEnabled
        ) ?? true
        interactionJournalRetentionDays = InteractionJournalStore.clampRetention(
            try c.decodeIfPresent(Int.self, forKey: .interactionJournalRetentionDays)
                ?? InteractionJournalStore.defaultRetentionDays
        )
        interactionJournalEventCap = InteractionJournalStore.clampEventCap(
            try c.decodeIfPresent(Int.self, forKey: .interactionJournalEventCap)
                ?? InteractionJournalStore.defaultEventCap
        )
        quickLinkBrowserBundleID = try c.decodeIfPresent(String.self, forKey: .quickLinkBrowserBundleID)
        customFolders = try c.decodeIfPresent([FolderLocation].self, forKey: .customFolders) ?? []
        customApplicationPaths = try c.decodeIfPresent([String].self, forKey: .customApplicationPaths) ?? []
        caffeinateUntil = try c.decodeIfPresent(Date.self, forKey: .caffeinateUntil)
        caffeinateAgentWatch = try c.decodeIfPresent(Bool.self, forKey: .caffeinateAgentWatch) ?? true
        caffeinateBatteryCutoff = try c.decodeIfPresent(Int.self, forKey: .caffeinateBatteryCutoff) ?? 20
        caffeinateKeepDisplayAwake = try c.decodeIfPresent(Bool.self, forKey: .caffeinateKeepDisplayAwake) ?? false
        screenAwarenessDoubleTap = try c.decodeIfPresent(Bool.self, forKey: .screenAwarenessDoubleTap) ?? true
        translatorHotkey = try c.decodeIfPresent(ActionHotkey.self, forKey: .translatorHotkey)
            ?? ActionHotkey(keyCode: 17, modifiers: 1_048_576 | 131_072)
        typeToClickHotkey = try c.decodeIfPresent(ActionHotkey.self, forKey: .typeToClickHotkey)
            ?? ActionHotkey(keyCode: 8, modifiers: 262_144 | 524_288)
        typeToClickHotkeyEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .typeToClickHotkeyEnabled
        ) ?? true
        typeToClickContinuation = try c.decodeIfPresent(
            TypeToClickContinuation.self, forKey: .typeToClickContinuation
        ) ?? .continuous
        quickAIHotkey = try c.decodeIfPresent(ActionHotkey.self, forKey: .quickAIHotkey)
            ?? ActionHotkey(keyCode: 49, modifiers: 1_048_576 | 524_288)
        quickAIHotkeyEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .quickAIHotkeyEnabled
        ) ?? false
        lastTranslationTarget = try c.decodeIfPresent(String.self, forKey: .lastTranslationTarget) ?? "zh-Hans"
        lastTranslationSource = try c.decodeIfPresent(String.self, forKey: .lastTranslationSource)
            ?? (lastTranslationTarget == "en" ? "zh-Hans" : "en")
        translationSourceSelection = try c.decodeIfPresent(String.self, forKey: .translationSourceSelection) ?? "auto"
        screenshotTextSearch = try c.decodeIfPresent(Bool.self, forKey: .screenshotTextSearch) ?? true
        attachClipboardImageOnOpen = try c.decodeIfPresent(Bool.self, forKey: .attachClipboardImageOnOpen) ?? false
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
        clipboardHistoryRetention = try c.decodeIfPresent(
            ClipboardRetention.self,
            forKey: .clipboardHistoryRetention
        ) ?? .forever
        clipboardHistoryDisabledSourceBundleIDs = try c.decodeIfPresent(
            [String].self,
            forKey: .clipboardHistoryDisabledSourceBundleIDs
        ) ?? []
        clipboardHistoryCaptureRemote = try c.decodeIfPresent(
            Bool.self,
            forKey: .clipboardHistoryCaptureRemote
        ) ?? false
        clipboardHistoryOCR = try c.decodeIfPresent(
            Bool.self,
            forKey: .clipboardHistoryOCR
        ) ?? true
        clipboardHistoryOCRMode = try c.decodeIfPresent(
            ClipboardOCRMode.self,
            forKey: .clipboardHistoryOCRMode
        ) ?? .accurate
        clipboardHistorySourceTags = try c.decodeIfPresent(
            Bool.self,
            forKey: .clipboardHistorySourceTags
        ) ?? true
        screenshotFolders = try c.decodeIfPresent(
            [String].self,
            forKey: .screenshotFolders
        ) ?? []
        screenshotIncludeAllMedia = try c.decodeIfPresent(
            Bool.self,
            forKey: .screenshotIncludeAllMedia
        ) ?? false
        screenshotOCRMode = try c.decodeIfPresent(
            ClipboardOCRMode.self,
            forKey: .screenshotOCRMode
        ) ?? .accurate
        screenshotColumns = min(max(try c.decodeIfPresent(
            Int.self,
            forKey: .screenshotColumns
        ) ?? 3, 2), 6)
        screenshotUseGrid = try c.decodeIfPresent(
            Bool.self,
            forKey: .screenshotUseGrid
        ) ?? false
        // An id this build does not know, a value that is not a usable
        // shortcut, or the default it would not have changed is dropped here
        // rather than carried around: the entry falls back to the built-in
        // key instead of shadowing it with nonsense.
        let storedShortcuts = try c.decodeIfPresent(
            [String: ActionHotkey].self,
            forKey: .shortcutOverrides
        ) ?? [:]
        shortcutOverrides = storedShortcuts.reduce(into: [:]) { result, entry in
            guard let action = ShortcutAction(rawValue: entry.key) else { return }
            let hotkey = entry.value.normalized
            guard hotkey.isValidShortcut, hotkey != action.defaultHotkey else { return }
            result[entry.key] = hotkey
        }
        emojiSkinTone = try c.decodeIfPresent(Int.self, forKey: .emojiSkinTone) ?? 0
        ocrKeepLineBreaks = try c.decodeIfPresent(Bool.self, forKey: .ocrKeepLineBreaks) ?? true
        appearance = try c.decodeIfPresent(AppearancePreference.self, forKey: .appearance) ?? .system
        visionProviderID = try c.decodeIfPresent(UUID.self, forKey: .visionProviderID)
            ?? InferenceProvider.deepSeekID
        visionModel = try c.decodeIfPresent(String.self, forKey: .visionModel)
            ?? InferenceProvider.deepSeekVisionModel
        providers = try c.decodeIfPresent(
            LossyDecodableArray<InferenceProvider>.self,
            forKey: .providers
        )?.elements ?? InferenceProvider.defaults
        selectedProviderID = try c.decodeIfPresent(UUID.self, forKey: .selectedProviderID)
            ?? InferenceProvider.deepSeekID
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
            ?? Self.defaultSystemPrompt
        // Absent in every blob written before 2026-10-21, when AI Chat
        // shared the quick-action instruction. The migration below decides
        // what an absent value means; a present one, empty included, is the
        // user's own choice and is kept.
        let storedChatSystemPrompt = try c.decodeIfPresent(
            String.self,
            forKey: .chatSystemPrompt
        )
        chatSystemPrompt = storedChatSystemPrompt ?? Self.defaultChatSystemPrompt
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit)
            ?? QuickHistoryStore.defaultLimit
        newChatInterval = try c.decodeIfPresent(NewChatInterval.self, forKey: .newChatInterval)
            ?? .fiveMinutes
        quickAIPrimaryAction = try c.decodeIfPresent(
            QuickAIPrimaryAction.self,
            forKey: .quickAIPrimaryAction
        ) ?? .pasteToActiveApp
        tabShortcutHintVisible = try c.decodeIfPresent(
            Bool.self,
            forKey: .tabShortcutHintVisible
        ) ?? true
        quickAIProviderID = try c.decodeIfPresent(UUID.self, forKey: .quickAIProviderID)
        quickAIModel = try c.decodeIfPresent(String.self, forKey: .quickAIModel) ?? ""
        fallbackCommandIDs = (try c.decodeIfPresent(
            [String].self,
            forKey: .fallbackCommandIDs
        ) ?? [FallbackCommandID.askAI]).filter { !FallbackCommandID.isRetired($0) }
        reopenRetentionSeconds = try c.decodeIfPresent(
            Int.self,
            forKey: .reopenRetentionSeconds
        ) ?? 10
        modelWebSearchEnabled = try c.decodeIfPresent(
            Bool.self,
            forKey: .modelWebSearchEnabled
        ) ?? true
        webSearchProvider = (try? c.decodeIfPresent(WebSearchProvider.self, forKey: .webSearchProvider)) ?? .automatic
        newChatMemoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .newChatMemoryEnabled) ?? true
        newChatTasksEnabled = try c.decodeIfPresent(Bool.self, forKey: .newChatTasksEnabled)
            ?? (decodedConfigurationVersion < 26 ? newChatMemoryEnabled : true)
        newChatSkillsEnabled = try c.decodeIfPresent(Bool.self, forKey: .newChatSkillsEnabled) ?? true
        // A blob from before the surface was resizable has no size: the
        // standard one. A malformed size is dropped on its own rather than
        // failing the whole decode, which would reset every other setting.
        quickAISize = ((try? c.decodeIfPresent(QuickAISize.self, forKey: .quickAISize)) ?? nil)?
            .atLeastStandard ?? .standard
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
        if decodedConfigurationVersion < 9 {
            for configuration in Self.defaultWindowConfigurations where
                !launcherItemConfigurations.contains(where: { $0.id == configuration.id }) {
                launcherItemConfigurations.append(configuration)
            }
        }
        if decodedConfigurationVersion < 15 {
            for configuration in Self.defaultFolderConfigurations where
                !launcherItemConfigurations.contains(where: { $0.id == configuration.id }) {
                launcherItemConfigurations.append(configuration)
            }
        }
        if decodedConfigurationVersion < 11,
           let index = providers.firstIndex(where: { $0.id == InferenceProvider.deepSeekID }),
           !providers[index].models.contains(InferenceProvider.deepSeekVisionModel) {
            providers[index].models.append(InferenceProvider.deepSeekVisionModel)
        }
        if decodedConfigurationVersion < 13 {
            // DeepSeek's flash vision model became the default for text and
            // images on 2026-08-22. Move settings that still sit on the old
            // defaults; explicit choices of another model stay.
            if let index = providers.firstIndex(where: { $0.id == InferenceProvider.deepSeekID }) {
                if !providers[index].models.contains(InferenceProvider.deepSeekVisionModel) {
                    providers[index].models.append(InferenceProvider.deepSeekVisionModel)
                }
                if providers[index].selectedModel == "deepseek-v4-flash" {
                    providers[index].selectedModel = InferenceProvider.deepSeekVisionModel
                }
            }
            if visionProviderID == InferenceProvider.mlxVisionID, visionModel.isEmpty {
                visionProviderID = InferenceProvider.deepSeekID
                visionModel = InferenceProvider.deepSeekVisionModel
            }
        }
        if decodedConfigurationVersion < 14,
           !savedPrompts.contains(where: { $0.alias == "zh" }),
           let chinese = SavedPrompt.defaults.first(where: { $0.alias == "zh" }) {
            savedPrompts.append(chinese)
        }
        if decodedConfigurationVersion < 18,
           let index = providers.firstIndex(where: { $0.id == InferenceProvider.mlxVisionID }),
           providers[index].baseURL == InferenceProvider.legacyMLXVisionBaseURL,
           let fresh = InferenceProvider.defaults.first(where: { $0.id == InferenceProvider.mlxVisionID }) {
            // 2026-09-02: the local provider goes through the local-models
            // daemon instead of the raw mlx-vlm port. A custom base URL is
            // an explicit choice and stays.
            providers[index].name = fresh.name
            providers[index].baseURL = fresh.baseURL
            providers[index].models = fresh.models
            providers[index].selectedModel = fresh.selectedModel
            if visionProviderID == InferenceProvider.mlxVisionID,
               visionModel.hasPrefix("mlx-community/") {
                visionModel = ""
            }
        }
        if providers.isEmpty { providers = InferenceProvider.defaults }
        // A removed provider (the Apple on-device route, 2026-08-22) must not
        // leave a dangling selection.
        if !providers.contains(where: { $0.id == selectedProviderID }) {
            selectedProviderID = providers.first(where: { $0.id == InferenceProvider.deepSeekID })?.id
                ?? providers[0].id
        }
        if !providers.contains(where: { $0.id == visionProviderID }) {
            visionProviderID = providers.first(where: { $0.id == InferenceProvider.mlxVisionID })?.id
                ?? providers.first(where: { $0.kind == .openAICompatible })?.id
                ?? providers[0].id
        }
        if decodedConfigurationVersion < 19, appearance == .system {
            // The overlay moved to a dark, monochrome look. Settings that never
            // chose an appearance follow it; an explicit light choice stays.
            appearance = .dark
        }
        if decodedConfigurationVersion < 20,
           !savedPrompts.contains(where: { $0.alias == "improve" }),
           let improve = SavedPrompt.defaults.first(where: { $0.alias == "improve" }) {
            // Add the Raycast-style Improve Writing action without disturbing
            // any action the user already customized.
            savedPrompts.append(improve)
        }
        if decodedConfigurationVersion < 22,
           let legacyNewConversationAfterMinutes {
            // "Start a new thread after" was a raw minute count behind a
            // 5/15/30/60 menu. Move the stored number onto its nearest option
            // so every existing window keeps roughly its meaning. A blob with
            // no count at all keeps the new 5 minute default.
            newChatInterval = NewChatInterval.nearest(
                toMinutes: legacyNewConversationAfterMinutes
            )
        }
        if decodedConfigurationVersion < 23 {
            // 2026-09-11: `deepseek-v4-flash-vision-exp` is sunset for text.
            // A DeepSeek selection still sitting on it moves to the flash
            // text model; any other explicit choice stays. The vision route
            // is untouched, and the id itself ships turned off in Manage
            // Models (`ModelProfile.curatedTable`) so it leaves the pickers.
            if let index = providers.firstIndex(where: { $0.id == InferenceProvider.deepSeekID }),
               providers[index].selectedModel == InferenceProvider.deepSeekVisionModel {
                providers[index].selectedModel = InferenceProvider.deepSeekDefaultModel
                if !providers[index].models.contains(InferenceProvider.deepSeekDefaultModel) {
                    providers[index].models.insert(InferenceProvider.deepSeekDefaultModel, at: 0)
                }
            }
            if quickAIProviderID == InferenceProvider.deepSeekID,
               quickAIModel == InferenceProvider.deepSeekVisionModel {
                quickAIModel = InferenceProvider.deepSeekDefaultModel
            }
        }
        if decodedConfigurationVersion < 24 {
            // 2026-09-11: DeepSeek serves one flash model, `deepseek-flash`
            // (V4.1 Flash, text and images). `deepseek-v4-flash` and
            // `deepseek-v4-flash-vision-exp` are aliases of it; every
            // setting on either moves to the real id, and they leave the
            // provider's list. Other explicit choices stay.
            let legacy = InferenceProvider.legacyDeepSeekFlashModels
            let flash = InferenceProvider.deepSeekDefaultModel
            if let index = providers.firstIndex(where: { $0.id == InferenceProvider.deepSeekID }) {
                var models = providers[index].models.filter { !legacy.contains($0) }
                if !models.contains(flash) { models.insert(flash, at: 0) }
                providers[index].models = models
                if legacy.contains(providers[index].selectedModel) {
                    providers[index].selectedModel = flash
                }
            }
            if quickAIProviderID == InferenceProvider.deepSeekID, legacy.contains(quickAIModel) {
                quickAIModel = flash
            }
            if visionProviderID == InferenceProvider.deepSeekID, legacy.contains(visionModel) {
                visionModel = flash
            }
            for index in savedPrompts.indices
            where savedPrompts[index].providerID == InferenceProvider.deepSeekID
                && legacy.contains(savedPrompts[index].model ?? "") {
                savedPrompts[index].model = flash
            }
        }
        if let quickAIProviderID,
           !providers.contains(where: { $0.id == quickAIProviderID }) {
            // A remembered Quick AI default that is no longer installed falls
            // back to the current selection rather than pinning a dead provider.
            self.quickAIProviderID = nil
            quickAIModel = ""
        }
        if decodedConfigurationVersion < 21 {
            // The built-in rewrite-the-selection actions preview first: the
            // result stays on screen, then the user picks Replace Selection or
            // Copy. Flip the *untouched stock defaults* to Show in Quick Launch
            // only; a prompted action the user customised keeps its own setting.
            // Prompt match is the provenance check (a renamed alias alone does
            // not make an action a rewrite, and sharing an alias with a
            // customized prompt is left as the user configured it).
            let legacyRewriteStocks: [(alias: String, prompt: String)] = [
                ("translate", "Translate the following text to English. Return only the translation, no preamble.\n\n{selection}"),
                ("zh", "Translate the following text to Simplified Chinese. Keep names, numbers, and formatting. Return only the translation, no preamble.\n\n{selection}"),
                ("grammar", "Fix grammar and spelling. Return only the corrected text, no explanations.\n\n{selection}"),
                ("improve", "Improve the writing of the following text. Fix any spelling and grammar mistakes and improve the clarity and concision. Return only the improved text, no explanations.\n\n{selection}"),
            ]
            for stock in legacyRewriteStocks {
                if let index = savedPrompts.firstIndex(where: {
                    $0.alias == stock.alias && $0.prompt == stock.prompt
                }) {
                    savedPrompts[index].outputBehavior = .showInOverlay
                }
            }
            // Add the two new rewrite defaults without disturbing any action
            // the user already customized or deleted.
            for alias in ["shorter", "bullets"] where
                !savedPrompts.contains(where: { $0.alias == alias }) {
                if let seed = SavedPrompt.defaults.first(where: { $0.alias == alias }) {
                    savedPrompts.append(seed)
                }
            }
        }
        if decodedConfigurationVersion < 25 {
            // 2026-09-11: the two default assistants join an existing
            // install once. An alias already in use (the user's own `/vault`)
            // keeps its action, and a deleted assistant stays deleted after
            // this version.
            for seed in SavedPrompt.assistantDefaults
            where !savedPrompts.contains(where: { $0.alias == seed.alias }) {
                savedPrompts.append(seed)
            }
        }
        if decodedConfigurationVersion < 27 {
            // 2026-10-20: vault search is retired, so the stock Vault
            // researcher goes. One the user rewrote keeps its alias.
            savedPrompts.removeAll {
                $0.alias == "vault"
                    && $0.systemPrompt?.hasPrefix("You research the user's own notes.") == true
            }
        }
        if decodedConfigurationVersion < 28, storedChatSystemPrompt == nil {
            // 2026-10-21: AI Chat gets its own instruction. The old blob has
            // one prompt for both surfaces, so an instruction the user
            // actually changed carries into chat rather than being silently
            // replaced by the new conversational default. The untouched
            // stock prompt is not a customization: chat takes its own
            // default, and Quick AI keeps the stock prompt it already had.
            if !Self.isStockQuickAIPrompt(systemPrompt) {
                chatSystemPrompt = systemPrompt
            }
        }
    }

    init() {}
}
