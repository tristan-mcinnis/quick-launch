import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// Submitting a question and the work around it.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - Submit

    /// Saved-prompt aliases matching the current `input`, sorted alphabetically.
    /// Empty whenever the input is not a prefix-based command.
    var savedPromptMatches: [SavedPrompt] {
        guard pendingImage == nil, catalogScope == nil, pendingQuickLinkID == nil else { return [] }
        return SavedPromptResolver.matches(
            input: input,
            prefix: settings.savedPromptPrefix,
            savedPrompts: settings.savedPrompts
        )
    }

    var actionMatches: [SavedPrompt] {
        settings.savedPrompts.enumerated().compactMap { ordinal, action -> (SavedPrompt, Int, Int)? in
            let score = [
                FuzzyMatcher.score(query: actionQuery, candidate: action.name),
                FuzzyMatcher.score(query: actionQuery, candidate: action.alias),
            ].compactMap { $0 }.max()
            guard let score else { return nil }
            return (action, score, ordinal)
        }
        .sorted { lhs, rhs in lhs.1 == rhs.1 ? lhs.2 < rhs.2 : lhs.1 > rhs.1 }
        .map(\.0)
    }

    /// The launcher query when the root launcher is active, otherwise `nil`.
    var rootLauncherQuery: String? {
        guard catalogScope == nil, pendingQuickLinkID == nil else { return nil }
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 1,
              query.count <= 64,
              !query.hasPrefix(settings.savedPromptPrefix),
              !query.contains("\n")
        else { return nil }
        return query
    }

    func learnedSignals(query: String, scope: String) -> [String: LauncherRankSignal] {
        guard settings.launcherLearningEnabled else { return [:] }
        return launcherUsage.signals(query: query, scope: scope)
    }

    /// Fuzzy score for a title plus optional alias, with the same exact and
    /// prefix bonuses every catalog uses. `foldedQuery` comes from
    /// `FuzzyMatcher.fold` so one ranking pass folds the query once.
    func matchScore(
        foldedQuery: String,
        title: String,
        alias: String,
        keywords: String = ""
    ) -> Int? {
        let foldedTitle = FuzzyMatcher.fold(title)
        let titleScore = FuzzyMatcher.score(foldedQuery: foldedQuery, foldedCandidate: foldedTitle)
        var foldedAlias = ""
        var aliasScore: Int?
        if !alias.isEmpty {
            foldedAlias = FuzzyMatcher.fold(alias)
            aliasScore = FuzzyMatcher.score(foldedQuery: foldedQuery, foldedCandidate: foldedAlias)
        }
        var keywordScore: Int?
        if !keywords.isEmpty,
           let raw = FuzzyMatcher.score(foldedQuery: foldedQuery, foldedCandidate: FuzzyMatcher.fold(keywords)) {
            // Keywords help but never outrank the same match on a title.
            keywordScore = raw - 50
            let words = FuzzyMatcher.fold(keywords).split(separator: " ")
            if words.contains(where: { $0 == Substring(foldedQuery) }) { keywordScore = raw + 1_500 }
            else if words.contains(where: { $0.hasPrefix(foldedQuery) }) { keywordScore = raw + 800 }
        }
        guard var score = [titleScore, aliasScore, keywordScore].compactMap({ $0 }).max() else { return nil }
        if foldedTitle == foldedQuery { score += 10_000 }
        else if foldedTitle.hasPrefix(foldedQuery) { score += 2_000 }
        // A whole typed phrase inside a title ("dark mode" in "Toggle Dark
        // Mode") is nearly as strong as a prefix, and beats the Ask AI row.
        else if foldedTitle.contains(foldedQuery) { score += foldedQuery.contains(" ") ? 1_950 : 500 }
        if !foldedAlias.isEmpty, foldedAlias == foldedQuery { score += 12_000 }
        score -= min(title.count, 100)
        return score
    }

    /// Query variants that forgive a trailing plural "s": `screenshots` also
    /// tries `screenshot`, which is what screenshot filenames contain. The
    /// singular form is only kept when it stays long enough to be meaningful
    /// (`shots` keeps `shot`; `lens`, `bus`, and `this` keep their exact form),
    /// so short words never turn into loose subsequence noise.
    static func searchVariants(for needle: String) -> [String] {
        let folded = FuzzyMatcher.fold(needle.trimmingCharacters(in: .whitespacesAndNewlines))
        guard folded.count > 4, folded.hasSuffix("s"), !folded.hasSuffix("ss"),
              !folded.hasSuffix("us"), !folded.hasSuffix("is") else { return [folded] }
        let singular = String(folded.dropLast())
        return singular.count >= 4 ? [folded, singular] : [folded]
    }

    func scoredApplications(
        foldedQuery: String,
        signals: [String: LauncherRankSignal],
        hiddenIDs: Set<String> = []
    ) -> [(LaunchableApplication, Int)] {
        guard let applicationCatalog else { return [] }
        let hidden = hiddenIDs.isEmpty ? hiddenLauncherItemIDs() : hiddenIDs
        let aliases = settings.launcherItemConfigurations.reduce(into: [String: String]()) { map, entry in
            guard entry.kind == .application else { return }
            let alias = entry.alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty { map[entry.itemID] = alias }
        }
        return applicationCatalog.applications.compactMap { application in
            // A hidden app stays out of search even when it has an alias,
            // a pin, or a learned abbreviation.
            guard !hidden.contains(LauncherSearchResult.application(application).id) else { return nil }
            guard let score = matchScore(
                foldedQuery: foldedQuery,
                title: application.name,
                alias: aliases[application.id] ?? "",
                keywords: application.alternateNames.joined(separator: " ")
            ) else { return nil }
            let boost = LauncherRanker.boost(
                for: signals[LauncherSearchResult.application(application).id]
            )
            return (application, score + boost)
        }
    }

    var applicationMatches: [LaunchableApplication] {
        guard let query = rootLauncherQuery else { return [] }
        let signals = learnedSignals(query: query, scope: LauncherUsageStore.rootScope)
        return Array(scoredApplications(foldedQuery: FuzzyMatcher.fold(query), signals: signals)
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
                }
                return $0.1 > $1.1
            }
            .prefix(6)
            .map(\.0))
    }

    var snippets: [LauncherCatalogItem] { pinnedFirst(launcherCatalog?.snippets ?? []) }
    var quickLinks: [LauncherCatalogItem] { pinnedFirst(launcherCatalog?.quickLinks ?? []) }
    var clipboardEntries: [LauncherCatalogItem] { clipboardHistory?.entries ?? [] }

    /// The clipboard entries after the active filter, for the list and count.
    var filteredClipboardEntries: [LauncherCatalogItem] {
        guard clipboardCatalogFilter.isActive else { return clipboardEntries }
        return clipboardHistory?.entries(matching: clipboardCatalogFilter)
            ?? clipboardEntries.filter(clipboardCatalogFilter.matches)
    }

    /// Applies a clipboard catalog filter and refreshes the list.
    func setClipboardCatalogFilter(_ filter: ClipboardCatalogFilter) {
        guard filter != clipboardCatalogFilter else { return }
        clipboardCatalogFilter = filter
        applicationSelectionIndex = 0
        invalidateLauncherRanking()
    }

    /// The full clipboard payload for an item, with its raw items loaded from
    /// the blob (in-memory cache first, disk off-main on a miss). Used by
    /// previews and restore; returns nil when the entry is gone.
    func fullClipboardPayload(for item: LauncherCatalogItem) async -> ClipboardPayload? {
        await clipboardHistory?.payload(for: item)
    }

    /// The emoji catalog with the chosen skin tone applied, computed once per
    /// tone. Ids never change, so pins and favourites survive a tone change.
    var emojiItems: [LauncherCatalogItem] {
        let tone = settings.emojiSkinTone
        guard tone > 0 else { return EmojiCatalog.items }
        if let cached = emojiTonedItems, cached.tone == tone { return cached.items }
        let toned = EmojiCatalog.items(skinTone: tone)
        emojiTonedItems = (tone, toned)
        return toned
    }
    var configurableCatalogItems: [LauncherCatalogItem] { snippets + quickLinks }

    func windowCommand(for layout: WindowLayout) -> LauncherCatalogItem {
        LauncherCatalogItem(
            kind: .command,
            itemID: "window.\(layout.rawValue)",
            title: layout.title,
            detail: "Resize the frontmost window",
            value: "window.\(layout.rawValue)"
        )
    }

    func windowMoveCommand(for move: WindowMove) -> LauncherCatalogItem {
        LauncherCatalogItem(
            kind: .command,
            itemID: "window.\(move.rawValue)",
            title: move.title,
            detail: move.detail,
            value: "window.\(move.rawValue)"
        )
    }

    func screenshotCommand(for kind: ScreenshotKind) -> LauncherCatalogItem {
        LauncherCatalogItem(
            kind: .command,
            itemID: kind.commandID,
            title: kind.title,
            detail: kind.detail,
            value: kind.commandID
        )
    }

    /// Built-in user folders plus the ones added in Settings, pinned first.
    var folderItems: [LauncherCatalogItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let locations = FolderLocationService.available(custom: settings.customFolders)
        return pinnedFirst(locations.map { location in
            let path = location.expandedURL.path
            let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
            return LauncherCatalogItem(
                kind: .folder,
                itemID: location.id,
                title: location.title,
                detail: shown,
                value: path,
                keywords: "folder finder directory open " + (location.isBuiltIn ? "" : "custom")
            )
        })
    }

    func folderLocation(for item: LauncherCatalogItem) -> FolderLocation? {
        FolderLocationService.available(custom: settings.customFolders).first { $0.id == item.itemID }
    }

    /// Quick toggles, System Settings panes, and the clipboard and screen
    /// helpers, as Commands catalog items.
    var utilityCommands: [LauncherCatalogItem] {
        let toggles = QuickToggle.allCases.map { toggle in
            LauncherCatalogItem(
                kind: .command,
                itemID: "toggle.\(toggle.rawValue)",
                title: toggle.title,
                detail: toggle.detail,
                value: "toggle.\(toggle.rawValue)",
                keywords: toggle.keywords + " toggle quick"
            )
        }
        let panes = SystemSettingsPaneCatalog.panes.map { pane in
            LauncherCatalogItem(
                kind: .command,
                itemID: "settingspane.\(pane.id)",
                title: "\(pane.title) Settings",
                detail: "System Settings",
                value: "settingspane.\(pane.id)",
                keywords: pane.keywords + " system preferences pane"
            )
        }
        let helpers = [
            LauncherCatalogItem(
                kind: .command,
                itemID: "snippet.create",
                title: "Create Snippet",
                detail: "Write a new snippet: a name and the text it pastes",
                value: "snippet.create",
                keywords: "new snippet add text template placeholder expand"
            ),
            LauncherCatalogItem(
                kind: .command,
                itemID: "quicklink.create",
                title: "Create Quicklink",
                detail: "Save an address you open often; {query} asks for words first",
                value: "quicklink.create",
                keywords: "new quicklink quick link add url address bookmark search"
            ),
            LauncherCatalogItem(
                kind: .command,
                itemID: "ocr.area",
                title: "Copy Text from Screen Area",
                detail: "Drag out an area; the text in it is read on this Mac and copied",
                value: "ocr.area",
                keywords: "ocr read recognize text screenshot copy"
            ),
            LauncherCatalogItem(
                kind: .command,
                itemID: "ocr.areaPaste",
                title: "Paste Text from Screen Area",
                detail: "Drag out an area; its text is read on this Mac and pasted behind Quick Launch",
                value: "ocr.areaPaste",
                keywords: "ocr read recognize text screenshot paste"
            ),
            LauncherCatalogItem(
                kind: .command,
                itemID: "paste.plain",
                title: "Paste as Plain Text",
                detail: "Paste the clipboard into the app behind Quick Launch without formatting",
                value: "paste.plain",
                keywords: "plain text paste clipboard unformatted"
            ),
            LauncherCatalogItem(
                kind: .command,
                itemID: "clipboard.cleanLink",
                title: "Clean Link on Clipboard",
                detail: "Strip utm_ and other tracking parameters from the copied link",
                value: "clipboard.cleanLink",
                keywords: "url link clean tracking utm clipboard"
            ),
        ]
        return toggles + helpers + panes
    }

    /// Every searchable setting, as launcher rows. Kept out of
    /// `systemCommands` on purpose: the Commands catalog and the Items table
    /// should list actions, not the Settings index. Root search folds these in
    /// so typing a setting's words finds the place to change it.
    var settingsDestinationItems: [LauncherCatalogItem] {
        SettingsDestinationIndex.launcherItems
    }

    var systemCommands: [LauncherCatalogItem] {
        let layouts = WindowLayout.allCases.map(windowCommand(for:))
            + WindowMove.allCases.map(windowMoveCommand(for:))
        let screenshots = ScreenshotKind.allCases.map(screenshotCommand(for:)) + [
            LauncherCatalogItem(
                kind: .command,
                itemID: "awareness.area",
                title: "Send Screen Area to AI",
                detail: "Drag out an area of the screen, then ask about it",
                value: "awareness.area",
                keywords: "screenshot region selection capture"
            ),
            LauncherCatalogItem(
                kind: .command,
                itemID: "awareness.selection",
                title: "Send Selected Text to AI",
                detail: "Only the text highlighted in the app behind Quick Launch",
                value: "awareness.selection",
                keywords: "selection context"
            ),
            LauncherCatalogItem(
                kind: .command,
                itemID: LatestScreenshotFinder.commandID,
                title: "Attach Latest Screenshot",
                detail: "The newest file in your screenshots folder, then ask about it",
                value: LatestScreenshotFinder.commandID
            ),
            LauncherCatalogItem(
                kind: .command,
                itemID: "screenshot.pasteLatest",
                title: "Paste Latest Screenshot",
                detail: "Paste the newest screenshot into the app behind Quick Launch",
                value: "screenshot.pasteLatest",
                keywords: "image paste"
            ),
            LauncherCatalogItem(
                kind: .command,
                itemID: "screenshot.save",
                title: "Save Capture to Screenshots",
                detail: "Save the capture waiting to attach as a new PNG in your screenshots folder",
                value: "screenshot.save",
                keywords: "save screenshot capture png file export attachments library"
            ),
        ]
        let caffeine = caffeinateStatusRow
        let translate = LauncherCatalogItem(
            kind: .command,
            itemID: "translate.mode",
            title: "Translate",
            detail: "Open the Translator window (⇧⌘T): source above, translation below",
            value: "translate.mode",
            keywords: "chinese english zh en"
        )
        let typeToClick = LauncherCatalogItem(
            kind: .command,
            itemID: "type-to-click.mode",
            title: "Type to Click",
            detail: settings.typeToClickContinuation == .continuous
                ? "See named targets, type to narrow, and chain actions"
                : "See named targets, type to narrow, and act once",
            value: "type-to-click.mode",
            keywords: "click mouse search overlay accessibility elements buttons menus file edit view window"
        )
        let settings = LauncherCatalogItem(
            kind: .command,
            itemID: "settings.open",
            title: "Open Quick Launch Settings",
            detail: "Configure Quick Launch",
            value: "settings.open",
            keywords: "settings preferences configure quick launch"
        )
        var commands: [LauncherCatalogItem] = []
        commands.append(contentsOf: layouts)
        commands.append(contentsOf: screenshots)
        // Only the status row lives at the root: typing "caffeinate" answers
        // "is it on?" in one line. Timers and Agent Watch sit in the catalog.
        commands.append(contentsOf: [translate, typeToClick, caffeine])
        if aiChatOpener != nil { commands.append(aiChatCommand) }
        commands.append(settings)
        commands.append(contentsOf: utilityCommands)
        // Everything the other house apps publish, last: this app's own
        // commands keep the order they have always had.
        commands.append(contentsOf: houseCommandItems)
        return commands
    }

    /// The one Caffeinate row at the launcher root. The title is the action
    /// that changes the state (Caffeinate or Decaffeinate), the light shows
    /// On, Off, or Paused, and the detail says until when or why it paused.
    /// Return runs the action the title names.
    var caffeinateStatusRow: LauncherCatalogItem {
        let detail: String
        if hasCaffeinateSession {
            if let caffeinatePauseDetail {
                detail = caffeinatePauseDetail
            } else if let caffeinateEndsAt {
                let clock = caffeinateEndsAt.formatted(date: .omitted, time: .shortened)
                let left = Self.remainingTitle(until: caffeinateEndsAt, now: now())
                detail = left.isEmpty ? "Until \(clock)" : "Until \(clock) · \(left) left"
            } else if let caffeinateReason, caffeinateReason.hasPrefix("Caffeinated while") {
                // "Caffeinated while Claude Code is working." → "While Claude Code is working"
                let rest = caffeinateReason.dropFirst("Caffeinated ".count).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                detail = rest.prefix(1).uppercased() + rest.dropFirst()
            } else {
                detail = "Until you turn it off"
            }
        } else {
            detail = "The Mac sleeps normally"
        }
        return LauncherCatalogItem(
            kind: .command,
            itemID: "caffeinate.toggle",
            // One action word per state, like Pin/Unpin. The state is the
            // session, not the assertion, so a battery-paused session still
            // reads Decaffeinate and Return cancels it.
            title: hasCaffeinateSession ? "Decaffeinate" : "Caffeinate",
            detail: detail,
            value: "caffeinate.toggle",
            keywords: "caffeine caffeinate awake sleep decaffeinate keep awake",
            statusLight: !hasCaffeinateSession ? .off : (isCaffeinating ? .on : .paused)
        )
    }

    /// Everything in the Caffeinate catalog, in the order it reads best:
    /// the status row, then the timers, then Agent Watch.
    var caffeinateItems: [LauncherCatalogItem] {
        let timed = Self.caffeinateDurations.map { minutes in
            LauncherCatalogItem(
                kind: .command,
                itemID: "caffeinate.\(minutes)",
                title: "Keep Awake for \(Self.durationTitle(minutes: minutes))",
                detail: "Then let the Mac sleep again",
                value: "caffeinate.\(minutes)",
                keywords: "caffeinate timer"
            )
        }
        let until = LauncherCatalogItem(
            kind: .command,
            itemID: "caffeinate.until",
            title: "Keep Awake Until a Time…",
            detail: "Type a time (17:30, 5:30pm) or a duration (90m, 2h)",
            value: "caffeinate.until",
            keywords: "caffeinate timer schedule"
        )
        let agentWatch = LauncherCatalogItem(
            kind: .command,
            itemID: "caffeinate.agentWatch",
            title: settings.caffeinateAgentWatch ? "Agent Watch: On" : "Agent Watch: Off",
            detail: "Stay awake while Claude Code or Codex is working",
            value: "caffeinate.agentWatch",
            keywords: "agent claude codex",
            statusLight: settings.caffeinateAgentWatch ? .on : .off
        )
        return [caffeinateStatusRow] + timed + [until, agentWatch]
    }

    /// "42 min" / "1 hr 5 min" until `until`; empty once it has passed.
    static func remainingTitle(until: Date, now: Date) -> String {
        let minutes = Int((until.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return "" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    static let caffeinateDurations = [30, 60, 120, 240]

    static func durationTitle(minutes: Int) -> String {
        switch minutes {
        case ..<60: "\(minutes) Minutes"
        case 60: "1 Hour"
        default: minutes % 60 == 0 ? "\(minutes / 60) Hours" : "\(minutes) Minutes"
        }
    }

    static let askAIItemID = "ask"

    /// The one row that sends the typed text to the model. Same record as
    /// every other item: it can be pinned, aliased, given a hotkey, and it
    /// learns from use.
    ///
    /// Two things can change what the row says. Return on unmatched text runs
    /// the first Fallback Command, so when that is not Ask AI the row names
    /// what Return will really do. And the ⇥ hint is drawn only while the Tab
    /// Shortcut setting is on.
    func askAIItem(query: String) -> LauncherCatalogItem {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var item = makeAskAIItem(
            title: "Ask AI",
            detail: askAIDetail(for: trimmed),
            value: trimmed
        )
        item.isPinned = isLauncherItemPinned(item)
        guard !trimmed.isEmpty, !item.isPinned, let fallback = rootFallbackRowCopy else {
            return item
        }
        return makeAskAIItem(title: fallback.title, detail: fallback.detail, value: trimmed)
    }

    /// What the Ask AI row says under its title. The ⇥ hint is drawn only
    /// while the Tab Shortcut setting is on; Tab itself is never conditional.
    /// Text with a local answer (math, a conversion, a date, a fact) never
    /// reaches the model: Tab and Return show the answer in root search, so
    /// the row says so and draws no ⇥ hint.
    private func askAIDetail(for trimmed: String) -> String {
        if typedTextHasLocalAnswer(trimmed) {
            return "Answered here, not sent to \(activeModelDisplay)"
        }
        let base = trimmed.isEmpty
            ? "Ask \(activeModelDisplay) anything"
            : "\u{201C}\(trimmed)\u{201D} to \(activeModelDisplay)"
        // What Tab actually does from root search: it hands the typed text to
        // Quick AI. A matching saved-prompt alias completes first, which is
        // that alias row's own behaviour, not this row's.
        return showsTabShortcutHint ? base + ". ⇥ opens Quick AI" : base
    }

    private func makeAskAIItem(title: String, detail: String, value: String) -> LauncherCatalogItem {
        LauncherCatalogItem(
            kind: .askAI,
            itemID: Self.askAIItemID,
            title: title,
            detail: detail,
            value: value,
            keywords: "ai ask chat question prompt"
        )
    }

    /// What Return on unmatched root-search text will actually run, when the
    /// first Fallback Command is not Ask AI. The row and the key agree.
    private var rootFallbackRowCopy: (title: String, detail: String)? {
        guard let identifier = settings.firstFallbackCommandID,
              identifier != FallbackCommandID.askAI
        else { return nil }
        let entry = fallbackCommandEntry(for: identifier)
        return (entry.title, entry.detail)
    }

    var catalogItems: [LauncherCatalogItem] {
        guard let catalogScope else { return [] }
        switch catalogScope {
        case .snippets: return snippets
        case .quickLinks: return quickLinks
        case .clipboard: return filteredClipboardEntries
        case .emoji: return emojiItems
        case .screenshots: return screenshotItems
        case .caffeinate: return caffeinateItems
        case .chats: return conversationItems
        case .commands: return systemCommands
        case .folders: return folderItems
        }
    }

    /// Every chat, pinned first, newest next, as launcher items.
    var conversationItems: [LauncherCatalogItem] { chatItems(matching: "") }

    /// The rows of every chat list (the Chats catalog, Recent Chats, the AI
    /// Chat rail): one search (`ChatSearch`), ranked while a query is typed,
    /// with a snippet on rows found by their text. Read once per query: a
    /// render that reads the rows again gets the cached rows. Hidden chats
    /// are filtered here, so one hide covers every Quick Launch list.
    func chatItems(matching query: String) -> [LauncherCatalogItem] {
        visibleLauncherItems(searchedChatItems(matching: query))
    }

    /// A chat's time as the lists draw it: the clock today, the day before.
    static func shortStamp(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// One chat as a launcher row: its title, question count, and time,
    /// and the snippet when a search found it by its text.
    func conversationItem(_ conversation: QuickConversation, snippet: ChatSnippet? = nil) -> LauncherCatalogItem {
        let turns = conversation.messages.filter { $0.role == .user }.count
        let stamp = Self.shortStamp(conversation.updatedAt)
        let count = turns == 1 ? "1 question" : "\(turns) questions"
        return LauncherCatalogItem(
            kind: .conversation,
            itemID: conversation.id.uuidString,
            title: title(of: conversation),
            // A pinned row carries the pin glyph; the detail stays the facts.
            detail: "\(count) · \(stamp)",
            value: conversation.lastAnswer ?? "",
            keywords: conversation.isPinned ? "pinned" : "",
            isPinned: conversation.isPinned,
            chatSnippet: snippet
        )
    }

    /// The saved files, newest first, pins floated. The capture and AI
    /// commands are not rows here; they live behind ⌘K so the list stays a
    /// pure screenshots list (they stay searchable from the root).
    var screenshotItems: [LauncherCatalogItem] {
        pinnedFirst(screenshotFiles)
    }


    /// The capture and Screen Awareness commands offered in the Screenshots
    /// catalog's ⌘K pane. No shortcuts: they are palette rows only.
    static let screenAwarenessCommandValues = [
        ScreenshotKind.window.commandID,
        ScreenshotKind.display.commandID,
        "awareness.area",
        LatestScreenshotFinder.commandID,
        "screenshot.pasteLatest",
    ]
    private static let screenCommandIcons = [
        "screenshot.window": "macwindow.on.rectangle",
        "screenshot.display": "rectangle.dashed.badge.record",
        "awareness.area": "rectangle.dashed",
        "screenshot.latest": "photo.badge.arrow.down",
        "screenshot.pasteLatest": "arrow.turn.down.right",
    ]


    var screenAwarenessActions: [ItemAction] {
        var actions = Self.screenAwarenessCommandValues.compactMap { value -> ItemAction? in
            guard let command = systemCommands.first(where: { $0.value == value }) else { return nil }
            return ItemAction(
                kind: .runCommand,
                title: command.title,
                systemImage: Self.screenCommandIcons[value] ?? "photo",
                shortcut: nil,
                commandValue: value
            )
        }
        // Save is offered only when a capture is actually waiting, so the row
        // is a readiness check, not a button that always fails.
        if pendingImage != nil,
           let save = systemCommands.first(where: { $0.value == "screenshot.save" }) {
            actions.append(ItemAction(
                kind: .runCommand,
                title: save.title,
                systemImage: "square.and.arrow.down",
                shortcut: nil,
                commandValue: "screenshot.save"
            ))
        }
        return actions
    }

    /// Marks the items the user pinned and floats them to the top, keeping
    /// the store's order inside each group. No pins: the array is returned as is.
    func pinnedFirst(_ items: [LauncherCatalogItem]) -> [LauncherCatalogItem] {
        let pinnedIDs = Set(settings.launcherItemConfigurations.lazy.filter(\.isPinned).map(\.id))
        guard !pinnedIDs.isEmpty else { return items }
        var pinned: [LauncherCatalogItem] = []
        var rest: [LauncherCatalogItem] = []
        for var item in items {
            if pinnedIDs.contains(item.id) {
                item.isPinned = true
                pinned.append(item)
            } else {
                rest.append(item)
            }
        }
        return pinned + rest
    }

    func reloadScreenshotFiles() {
        screenshotFiles = ScreenshotLibrary.items(
            inFolders: screenshotFolders,
            includeAllMedia: settings.screenshotIncludeAllMedia
        )
        lastScreenshotScanAt = Date()
        if settings.screenshotTextSearch {
            screenshotTextIndex.refresh(for: screenshotFiles, mode: settings.screenshotOCRMode)
        }
        invalidateLauncherRanking()
    }

    /// Maximum rows the launcher list shows at once. The empty-query root
    /// must fit two learned favourites, Ask AI, and every catalog root, so
    /// this tracks the number of catalogs and the list scrolls past it.
    static let maxLauncherRows = LauncherCatalogScope.allCases.count + 3
    /// The emoji grid shows more: 9 columns by 7 rows.
    static let maxGridCells = 63
    static let gridColumns = 9
    /// The saved-media grid's cell cap, matching the emoji grid.
    static let screenshotGridCells = 63
    /// Emoji & Symbols is a grid. The screenshots browser is a grid when the
    /// user chose one. The grid stays put while the ⌘K pane floats over it;
    /// swapping layouts under a popover made the whole window shift.
    var isGridCatalog: Bool {
        catalogScope == .emoji || (catalogScope == .screenshots && settings.screenshotUseGrid)
    }

    /// The live column count: the emoji grid is fixed at nine, the screenshot
    /// grid follows the user's setting (2...6).
    var gridColumnCount: Int {
        catalogScope == .screenshots ? max(2, min(6, settings.screenshotColumns)) : Self.gridColumns
    }

    /// The row cap for the current scope. A screenshot grid lists more cells
    /// than the list's rows so the grid is worth using.
    var effectiveRowLimit: Int {
        if catalogScope == .screenshots, settings.screenshotUseGrid { return Self.screenshotGridCells }
        return Self.maxRows(for: catalogScope)
    }

    /// Catalogs that show the detail pane beside their list. Snippets and
    /// Quicklinks join the preview-worthy set so a row's stored value is
    /// readable before it is pasted or opened.
    static let detailPaneScopes: Set<LauncherCatalogScope> = [
        .screenshots, .clipboard, .snippets, .quickLinks,
    ]

    /// Item kinds the detail pane knows how to draw.
    static let detailPaneKinds: Set<LauncherItemKind> = [
        .screenshot, .clipboard, .snippet, .quickLink,
    ]

    /// Preview-worthy local catalogs share one stable two-pane layout. The
    /// pane stays visible (and the window keeps its width) while ⌘K floats
    /// over it.
    var showsDetailPane: Bool {
        guard let catalogScope, Self.detailPaneScopes.contains(catalogScope),
              inputMode == nil, pendingImage == nil
        else { return false }
        return isHistoryCatalog || detailItem != nil
    }

    /// Histories keep their two-column surface through empty searches and new
    /// copies, instead of collapsing the window on every change in row count.
    var isHistoryCatalog: Bool { catalogScope == .clipboard || catalogScope == .screenshots }

    var detailItem: LauncherCatalogItem? {
        guard let catalogScope, Self.detailPaneScopes.contains(catalogScope) else { return nil }
        let matches = launcherMatches
        guard !matches.isEmpty,
              case .item(let item) = matches[min(applicationSelectionIndex, matches.count - 1)],
              Self.detailPaneKinds.contains(item.kind)
        else { return nil }
        return item
    }

    var currentPanelWidth: CGFloat {
        if isQuickAIPresented { return quickAISize.width }
        if showsDetailPane { return PanelSizing.panelWidthWithDetail }
        return PanelSizing.panelWidth
    }

    /// Window height for the current surface. The AppDelegate applies this
    /// and the pane render-proof tests assert against the same math, so the
    /// drawn view and the window cannot drift apart.
    var estimatedWindowHeight: CGFloat {
        // The Quick AI surface, Recent Chats included, is the size the user
        // left it at (750 × 475 until the first drag): the thread scrolls
        // inside it, and every chooser and pane floats over it, so nothing
        // on it is measured.
        if isQuickAIPresented { return quickAISize.height }
        let showsChooser = isTransformChooserPresented || isCaptureChooserPresented
            || isTransformReviewPresented || isTransformArgumentFieldPresented
        let base = PanelSizing.panelHeight(
            errorMessage: errorMessage,
            // The Transform chooser replaces the launcher list while open, so
            // the launcher block is not counted then.
            suggestionCount: showsChooser ? 0 : max(launcherMatches.count, savedPromptMatches.count),
            showsResultActions: false,
            hasAttachment: hasPendingAttachment,
            showsFooter: showsLauncherFooter,
            launcherRowCount: showsChooser ? 0 : launcherMatches.count,
            gridRows: isGridCatalog
                ? Int((Double(launcherMatches.count) / Double(gridColumnCount)).rounded(.up))
                    + max(0, gridSections.count - 1)
                : 0,
            gridSections: isGridCatalog ? gridSections.count : 0,
            showsDetailPane: showsDetailPane
        )
        // The launch-selection chip and an open chooser are inline content
        // (they sit in the VStack flow), not a floating pane: add their
        // heights so the window cannot clip them. Previously the chooser was
        // treated as a `max(base, pane)` overlay, which left the inline
        // chip + chooser taller than the window and cut off the bottom.
        var total = base
        if isHistoryCatalog, showsDetailPane {
            let measuredListHeight: CGFloat = launcherMatches.isEmpty ? 0
                : max(PanelSizing.detailPaneMinimumHeight,
                      min(CGFloat(launcherMatches.count) * PanelSizing.launcherRowHeight
                          + PanelSizing.launcherListChrome, PanelSizing.launcherListMaximumHeight))
            total += PanelSizing.launcherListMaximumHeight - measuredListHeight
        }
        if let rootAnswer {
            total += PanelSizing.rootAnswerBlockHeight(
                answerHeight: MarkdownRenderer.measuredHeight(
                    markdown: rootAnswer.answer,
                    width: PanelSizing.rootAnswerTextWidth(panelWidth: currentPanelWidth)
                )
            )
        }
        if launchSelection != nil { total += PanelSizing.selectionChipHeight }
        if isTransformChooserPresented { total += PanelSizing.chooserBlockHeight(rows: transformChooserOptions.count) }
        if isTransformReviewPresented { total += PanelSizing.transformReviewBlockHeight }
        if isTransformArgumentFieldPresented { total += PanelSizing.searchableChooserBlockHeight(rows: 0) }
        if isCaptureChooserPresented {
            total += PanelSizing.searchableChooserBlockHeight(rows: captureChooserOptions.count)
        }
        if isModelChooserPresented {
            total += PanelSizing.chooserBlockHeight(rows: modelChooserOptions.count)
        }
        if isAddContextMenuPresented {
            total += PanelSizing.searchableChooserBlockHeight(rows: addContextRows.count)
        }
        var pane: CGFloat?
        if isItemActionPanePresented {
            pane = activeItemActionForm.map(PanelSizing.itemActionFormPaneHeight)
                ?? PanelSizing.itemActionPaneHeight(rows: filteredFocusedItemActions.count)
        } else if isActionPalettePresented {
            pane = PanelSizing.actionPaletteHeight(rows: actionPaletteEntryCount)
        }
        total = PanelSizing.windowHeight(
            base: total,
            paneHeight: pane,
            paneTop: PanelSizing.inputHeight
                + (hasPendingAttachment ? PanelSizing.attachmentHeight : 0)
        )
        return total
    }
}
