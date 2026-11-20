import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    // MARK: - Fallback Commands

    /// Return on unmatched root-search text. `nil` is the empty fallback list:
    /// nothing runs and the typed text stays a search.
    func runRootFallback(_ identifier: String?) async {
        guard let identifier else {
            requestInputFocus()
            return
        }
        await runFallbackCommand(identifier, text: input)
    }

    /// Runs one configured Fallback Command with the text the user typed.
    /// Tab is never part of this: `handleTab()` always opens Quick AI.
    func runFallbackCommand(_ identifier: String, text: String) async {
        if identifier == FallbackCommandID.askAI {
            // The Ask AI row itself, so the learned ranking and the journal
            // see exactly what they saw when the row was the only path.
            await performLauncherResult(.item(askAIItem(query: text)))
            return
        }
        if let promptID = FallbackCommandID.savedPromptUUID(from: identifier) {
            guard let prompt = settings.savedPrompts.first(where: { $0.id == promptID }) else {
                errorMessage = "That fallback command is no longer available."
                requestInputFocus()
                return
            }
            // The same shape `/alias text` has, so the command lane, the model
            // lane, and `{selection}` behave exactly as they do when the alias
            // is typed by hand.
            input = settings.savedPromptPrefix + prompt.alias + " " + text
            inputMode = nil
            await submit()
            return
        }
        if let itemID = FallbackCommandID.commandItemID(from: identifier),
           let item = fallbackCommandItems.first(where: { $0.itemID == itemID }) {
            // AI Chat takes what was typed as the new chat's draft; run as a
            // root row, the text is only the search that found the command.
            if item.value == Self.aiChatCommandID {
                inputMode = nil
                openAIChatWindow(draft: text)
                return
            }
            input = text
            inputMode = nil
            await performLauncherItem(item)
            // A command that takes text opens its own input step, which
            // clears the field: put the typed text back as that step's draft.
            if inputMode == .houseCommandArgument, input.isEmpty {
                input = text
            }
            return
        }
        errorMessage = "That fallback command is no longer available."
        requestInputFocus()
    }

    /// The `value` prefix of a root row that runs one Fallback Command.
    static let fallbackRowPrefix = "fallback:"

    /// The most extra Fallback Command rows root search shows. Each one
    /// takes a slot from the weakest match, so a long list must not push
    /// real results out.
    static let maximumAdditionalFallbackRows = 3

    /// Whether the command an identifier names still exists.
    func isFallbackCommandAvailable(_ identifier: String) -> Bool {
        if identifier == FallbackCommandID.askAI { return true }
        if let promptID = FallbackCommandID.savedPromptUUID(from: identifier) {
            return settings.savedPrompts.contains { $0.id == promptID }
        }
        if let itemID = FallbackCommandID.commandItemID(from: identifier) {
            return fallbackCommandItems.contains { $0.itemID == itemID }
        }
        return false
    }

    /// Rows for the Fallback Commands after the first, shown under unmatched
    /// root-search text. The first command is the row Return already runs
    /// (`askAIItem`), so it is not repeated here.
    func additionalFallbackRows(text: String) -> [LauncherCatalogItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return settings.fallbackCommandIDs.dropFirst()
            .filter(isFallbackCommandAvailable)
            .prefix(Self.maximumAdditionalFallbackRows)
            .map { identifier in
                let entry = fallbackCommandEntry(for: identifier)
                return LauncherCatalogItem(
                    kind: .command,
                    itemID: Self.fallbackRowPrefix + identifier,
                    title: entry.title,
                    detail: "\u{201C}\(trimmed)\u{201D} · Fallback Command",
                    value: Self.fallbackRowPrefix + identifier
                )
            }
    }

    /// One row of the Fallback Commands card.
    struct FallbackCommandEntry: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
        let systemImage: String
    }

    /// The configured Fallback Commands, in order, resolved against the
    /// commands that still exist.
    var fallbackCommandEntries: [FallbackCommandEntry] {
        settings.fallbackCommandIDs.map(fallbackCommandEntry(for:))
    }

    /// What one identifier names. A command the user later deleted resolves to
    /// a row that says so rather than vanishing silently.
    func fallbackCommandEntry(for identifier: String) -> FallbackCommandEntry {
        if identifier == FallbackCommandID.askAI {
            return FallbackCommandEntry(
                id: identifier,
                title: "Ask AI",
                detail: "Send the text to \(activeModelDisplay)",
                systemImage: "sparkles"
            )
        }
        if let promptID = FallbackCommandID.savedPromptUUID(from: identifier) {
            guard let prompt = settings.savedPrompts.first(where: { $0.id == promptID }) else {
                return FallbackCommandEntry(
                    id: identifier,
                    title: "Missing command",
                    detail: "This saved AI command was deleted. Remove the row.",
                    systemImage: "questionmark.circle"
                )
            }
            return FallbackCommandEntry(
                id: identifier,
                title: prompt.name,
                detail: "Saved AI command \(settings.savedPromptPrefix)\(prompt.alias)",
                systemImage: "text.quote"
            )
        }
        if let itemID = FallbackCommandID.commandItemID(from: identifier),
           let item = fallbackCommandItems.first(where: { $0.itemID == itemID }) {
            return FallbackCommandEntry(
                id: identifier,
                title: item.title,
                detail: item.detail,
                systemImage: item.systemImage
            )
        }
        return FallbackCommandEntry(
            id: identifier,
            title: "Missing command",
            detail: "This command is no longer available. Remove the row.",
            systemImage: "questionmark.circle"
        )
    }

    /// The app's own command catalogs, as the Fallback Commands card offers
    /// them.
    var fallbackCommandItems: [LauncherCatalogItem] { systemCommands }

    /// One command the Fallback Commands card can add.
    struct FallbackCommandChoice: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
    }

    struct FallbackCommandChoiceGroup: Identifiable, Sendable {
        let id: String
        let title: String
        let choices: [FallbackCommandChoice]
    }

    /// Everything the card can add, in groups, minus what it already holds.
    var fallbackCommandChoiceGroups: [FallbackCommandChoiceGroup] {
        let configured = Set(settings.fallbackCommandIDs)
        var groups: [FallbackCommandChoiceGroup] = []
        if !configured.contains(FallbackCommandID.askAI) {
            groups.append(FallbackCommandChoiceGroup(
                id: "askAI",
                title: "Quick AI",
                choices: [FallbackCommandChoice(
                    id: FallbackCommandID.askAI,
                    title: "Ask AI",
                    detail: "Send the text to \(activeModelDisplay)"
                )]
            ))
        }
        let prompts = settings.savedPrompts.compactMap { prompt -> FallbackCommandChoice? in
            let id = FallbackCommandID.savedPrompt(prompt.id)
            guard !configured.contains(id) else { return nil }
            return FallbackCommandChoice(
                id: id,
                title: prompt.name,
                detail: "Saved AI command \(settings.savedPromptPrefix)\(prompt.alias)"
            )
        }
        if !prompts.isEmpty {
            groups.append(FallbackCommandChoiceGroup(
                id: "prompts",
                title: "AI Commands",
                choices: prompts
            ))
        }
        let commands = fallbackCommandItems.compactMap { item -> FallbackCommandChoice? in
            let id = FallbackCommandID.command(item.itemID)
            guard !configured.contains(id) else { return nil }
            return FallbackCommandChoice(id: id, title: item.title, detail: item.detail)
        }
        if !commands.isEmpty {
            groups.append(FallbackCommandChoiceGroup(
                id: "commands",
                title: "Commands",
                choices: commands
            ))
        }
        return groups
    }

    /// Add one command to the end of the Fallback Commands list.
    func addFallbackCommand(_ identifier: String) {
        guard !settings.fallbackCommandIDs.contains(identifier) else { return }
        updateSettings { $0.fallbackCommandIDs.append(identifier) }
    }

    /// Remove one command. Removing the last one is allowed: unmatched text
    /// then runs nothing on Return.
    func removeFallbackCommand(_ identifier: String) {
        updateSettings { settings in
            settings.fallbackCommandIDs.removeAll { $0 == identifier }
        }
    }

    /// Move a command to a new position, used by the card's drag handle and by
    /// its keyboard move buttons.
    func moveFallbackCommand(_ identifier: String, toIndex index: Int) {
        updateSettings { settings in
            guard let from = settings.fallbackCommandIDs.firstIndex(of: identifier) else { return }
            let item = settings.fallbackCommandIDs.remove(at: from)
            settings.fallbackCommandIDs.insert(
                item,
                at: min(max(index, 0), settings.fallbackCommandIDs.count)
            )
        }
    }
}
