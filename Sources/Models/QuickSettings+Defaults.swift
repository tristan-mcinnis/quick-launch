import Foundation
import AppKit  // for NSEvent.ModifierFlags

extension QuickSettings {
    /// `dl` opens Downloads and `dk` the Desktop, from the first run.
    static let defaultFolderConfigurations: [LauncherItemConfiguration] = [
        LauncherItemConfiguration(kind: .folder, itemID: "downloads", alias: "dl"),
        LauncherItemConfiguration(kind: .folder, itemID: "desktop", alias: "dk"),
    ]

    static let defaultWindowConfigurations: [LauncherItemConfiguration] = [
        LauncherItemConfiguration(
            kind: .command,
            itemID: "window.leftHalf",
            alias: "left",
            hotkey: ActionHotkey(keyCode: 123, modifiers: 1_572_864)
        ),
        LauncherItemConfiguration(
            kind: .command,
            itemID: "window.rightHalf",
            alias: "right",
            hotkey: ActionHotkey(keyCode: 124, modifiers: 1_572_864)
        ),
        LauncherItemConfiguration(
            kind: .command,
            itemID: "window.bottomHalf",
            alias: "bottom",
            hotkey: ActionHotkey(keyCode: 125, modifiers: 1_572_864)
        ),
        LauncherItemConfiguration(
            kind: .command,
            itemID: "window.topHalf",
            alias: "top",
            hotkey: ActionHotkey(keyCode: 126, modifiers: 1_572_864)
        ),
    ]

    /// Quick AI's default: one direct result, no conversation.
    static let defaultSystemPrompt: String = """
    You are a fast, direct assistant in a Spotlight-style action overlay. \
    Return only the result the user asked for. No preamble, no postamble, \
    no apologies, no disclaimers, and no invitation to continue. Be concise.
    """

    /// AI Chat's default: a conversation can explain, so the answer takes
    /// the length the question needs. This is a separate default, never a
    /// layer on top of a custom instruction.
    static let defaultChatSystemPrompt: String = """
    You are a thoughtful assistant in a chat window. Answer the question in \
    front of you at the length it needs: a simple request gets a short answer, \
    and an explanation with its reasoning or steps when the user asks for one. \
    Write plain sentences, stay on the user's material, and say when you are \
    unsure. No preamble, no apology, and no invitation to continue.
    """

    /// Whether `prompt` is the stock quick-action instruction, written as
    /// shipped or with different surrounding space. Used only to tell an
    /// untouched default from a user's own words.
    static func isStockQuickAIPrompt(_ prompt: String) -> Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            == defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The instruction a request on one surface carries: Quick AI's direct
    /// rule, or AI Chat's conversational one. Saved assistants still prepend
    /// their own instructions in the wire transcript, unchanged.
    func surfaceSystemPrompt(forChat: Bool) -> String {
        forChat ? chatSystemPrompt : systemPrompt
    }

    var selectedProvider: InferenceProvider? {
        providers.first(where: { $0.id == selectedProviderID }) ?? providers.first
    }

    var selectedModel: String {
        selectedProvider?.selectedModel ?? ""
    }

    /// The provider Quick AI answers with: the explicit default when it is
    /// still installed, otherwise the current selection.
    var quickAIProvider: InferenceProvider? {
        guard let quickAIProviderID,
              let provider = providers.first(where: { $0.id == quickAIProviderID })
        else { return selectedProvider }
        return provider
    }

    /// The model override for Quick AI on `providerID`, or nil when that
    /// provider's own selected model stands (which is what "unset" means).
    func quickAIModelOverride(for providerID: UUID) -> String? {
        guard quickAIProviderID == providerID, !quickAIModel.isEmpty else { return nil }
        return quickAIModel
    }

    /// The command unmatched root-search text runs on Return. Nil when the
    /// user has removed every fallback: Return then runs nothing.
    var firstFallbackCommandID: String? { fallbackCommandIDs.first }

    /// The capture policy the Clipboard History store applies, built from the
    /// flat settings fields so the two can never disagree.
    var clipboardCapturePolicy: ClipboardCapturePolicy {
        ClipboardCapturePolicy(
            disabledSourceBundleIDs: Set(
                clipboardHistoryDisabledSourceBundleIDs
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            ),
            retention: clipboardHistoryRetention,
            ocrEnabled: clipboardHistoryOCR,
            ocrMode: clipboardHistoryOCRMode,
            captureRemote: clipboardHistoryCaptureRemote,
            sourceTagsEnabled: clipboardHistorySourceTags
        )
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
