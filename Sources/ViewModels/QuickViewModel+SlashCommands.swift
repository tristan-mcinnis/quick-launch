import Foundation

/// The composer's `/` palette: what it lists, when it opens, and what taking
/// a row does.
///
/// Every command it shows already worked. `/tldr` has expanded through
/// `SavedPromptResolver` on both surfaces for as long as the prefix has been
/// `/`, and the two built-ins have been routed since the harmonisation. What
/// was missing was any way to find out, on the surface whose own placeholder
/// reads "Ask anything, @ to attach, or / for commands…". Skills are the one
/// addition: they were reachable only when the *model* chose to call
/// `read_skill`, never by asking for one by name.
extension QuickViewModel {
    /// Skills are read from disk, so the listing is taken once when the
    /// palette opens rather than on every keystroke of the filter.
    static let slashSkillLimit = 200

    /// Everything the composer answers to, in one list.
    var slashCommandCatalog: [SlashCommand] {
        var rows = SlashCommand.builtIns
        if settings.savedPromptPrefix == "/" {
            rows += settings.savedPrompts.map { prompt in
                SlashCommand(
                    name: prompt.alias,
                    title: prompt.name,
                    detail: prompt.commandExecutable?.isEmpty == false
                        ? "Runs a command on this Mac"
                        : "Saved prompt",
                    kind: .savedPrompt
                )
            }
        }
        rows += cachedSlashSkillNames.map { name in
            SlashCommand(
                name: name,
                title: name,
                detail: "Reads the skill and answers with it",
                kind: .skill
            )
        }
        return rows
    }

    /// The rows after the typed filter, best match first, sections kept in
    /// order so the built-ins never fall below a skill that scores higher.
    var slashCommandMatches: [SlashCommand] {
        let query = slashCommandQuery
        let rows = slashCommandCatalog
        guard !query.isEmpty else { return rows }
        let ranked = Self.rankByQuery(rows, query: query, title: \.name)
        // A prompt named for what it does should still be findable by that
        // name, not only by its alias.
        let byTitle = Self.rankByQuery(rows, query: query, title: \.title)
        var seen = Set<String>()
        return (ranked + byTitle).filter { seen.insert($0.id).inserted }
    }

    /// What follows the `/` in the draft while the palette is open.
    var slashCommandQuery: String {
        guard input.hasPrefix("/") else { return "" }
        return String(input.dropFirst())
    }

    /// Typing `/` as the first character of an empty draft opens the palette.
    /// Unlike `@`, the character stays: the user is typing a command, and the
    /// palette narrows as they go.
    ///
    /// It closes as soon as the draft stops being a bare command name: a
    /// space means the name is settled and arguments are being typed, and
    /// anything that no longer starts with `/` was never a command.
    @discardableResult
    func slashCommandTriggerDidChange(_ newValue: String) -> Bool {
        guard !isStreaming,
              !isRecentChatsPresented,
              !isAddContextMenuPresented,
              !isCaptureChooserPresented,
              !isModelChooserPresented,
              !isAssistantChooserPresented,
              !isTransformChooserPresented,
              !isActionPalettePresented,
              !isItemActionPanePresented,
              catalogScope == nil,
              inputMode == nil,
              pendingQuickLinkID == nil
        else {
            closeSlashCommandPalette()
            return false
        }
        let isBareCommandName = newValue.hasPrefix("/")
            && !newValue.dropFirst().contains(where: { $0.isWhitespace })
        guard isBareCommandName else {
            closeSlashCommandPalette()
            return false
        }
        if !isSlashCommandPalettePresented { openSlashCommandPalette() }
        slashCommandIndex = 0
        return true
    }

    func openSlashCommandPalette() {
        // Reading `~/.claude/skills` is one directory listing; it is taken
        // here, not in a computed property a body would re-run.
        cachedSlashSkillNames = Array(
            (skillLibrary?.names() ?? []).prefix(Self.slashSkillLimit)
        )
        slashCommandIndex = 0
        isSlashCommandPalettePresented = true
    }

    func closeSlashCommandPalette() {
        guard isSlashCommandPalettePresented else { return }
        isSlashCommandPalettePresented = false
        cachedSlashSkillNames = []
        slashCommandIndex = 0
    }

    func moveSlashCommandSelection(_ delta: Int) {
        let rows = slashCommandMatches
        guard !rows.isEmpty else { return }
        slashCommandIndex = ListSelection.wrappedIndex(
            slashCommandIndex,
            by: delta,
            count: rows.count
        )
    }

    /// Takes the highlighted row: the draft becomes the command, ready for
    /// whatever follows it. Nothing is sent. `/new` and `/clear` take no
    /// argument, so they run on the next Return like any other command, and
    /// a destructive one is never a single keystroke away.
    @discardableResult
    func completeSlashCommand(_ command: SlashCommand? = nil) -> Bool {
        let rows = slashCommandMatches
        let chosen: SlashCommand?
        if let command {
            chosen = command
        } else if rows.indices.contains(slashCommandIndex) {
            chosen = rows[slashCommandIndex]
        } else {
            chosen = nil
        }
        guard let chosen else { return false }
        closeSlashCommandPalette()
        input = chosen.completion(prefix: settings.savedPromptPrefix)
        requestInputFocus()
        return true
    }

    // MARK: - Skills as commands

    /// The skill a draft names, or nil. Read from the library rather than
    /// the palette's cache, so a command typed from memory works with the
    /// palette closed.
    func slashSkillName(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let first = trimmed.dropFirst().split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        guard let first, !first.isEmpty else { return nil }
        // A saved prompt or a built-in wins: a skill may not shadow them.
        guard !SlashCommand.builtIns.contains(where: { $0.name == first }) else { return nil }
        guard !settings.savedPrompts.contains(where: { $0.alias == first }) else { return nil }
        guard skillLibrary?.isValid(first) == true else { return nil }
        return first
    }

    /// The one line the composer shows while a skill command is drafted, so
    /// a 12,000-character skill is never added to a question silently.
    var slashSkillNotice: String? {
        guard let name = slashSkillName(in: input) else { return nil }
        return "Runs the \(name) skill"
    }
}
