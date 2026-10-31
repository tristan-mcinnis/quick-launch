import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// The interaction journal.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - Interaction journal

    /// The one place the journal is written to. Gates on the setting and keeps
    /// the store's bounds in step with the settings.
    ///
    /// The stored `query` digest is opt-in: only `learn` and
    /// `endInteractionSession` pass it. Note what that means — `learn` fires for
    /// every accepted row, *including the Ask AI row*, whose typed text is the
    /// question that goes to the model. So a typed question can reach the digest
    /// path; what never happens is the *text* reaching it. The digest is
    /// HMAC-SHA256 under this install's `interaction-journal-key` and is stored
    /// with only a coarse size band, so a question contributes 12 hex characters
    /// that cannot be recomputed without that file and nothing else. Model
    /// request outcomes (`aiFailed`, `aiSucceeded`, `aiCancelled`) pass no query
    /// at all.
    ///
    /// Session correlation is tracked separately, by `journalActedQuery`.
    func recordJournal(
        kind: InteractionJournalEventKind,
        scope: String = LauncherUsageStore.rootScope,
        itemID: String? = nil,
        query: String? = nil,
        detail: String? = nil
    ) {
        guard settings.interactionJournalEnabled else { return }
        interactionJournal.retentionDays = settings.interactionJournalRetentionDays
        interactionJournal.eventCap = settings.interactionJournalEventCap
        interactionJournal.record(
            kind: kind,
            scope: scope,
            itemID: itemID,
            query: query,
            detail: detail
        )
        interactionJournalRevision += 1
    }

    /// Remembers the folded query the user submitted or acted on, so dismissing
    /// the overlay afterwards is not mistaken for an abandoned search. Called
    /// at every entry point that turns typed text into a request or a choice,
    /// whatever happens next.
    func noteActedQuery(_ query: String) {
        journalActedQuery = LauncherUsageStore.normalizedQuery(query)
    }

    /// Records an action failure from `errorMessage`, which is the single
    /// user-visible failure channel. Only the *category* is journalled — the
    /// message itself is compared and discarded, never stored.
    func noteActionFailure(itemID: String, scope: String, priorError: String?) {
        guard let message = errorMessage, message != priorError else {
            return
        }
        recordJournal(kind: .actionFailed, scope: scope, itemID: itemID, detail: "action")
    }

    /// The overlay was dismissed. When the user typed a query and nothing came
    /// of it — no choice, no answer, no submission — that is an abandoned
    /// search; the store turns an immediate repeat of the same query into a
    /// retry.
    ///
    /// Must be called before the dismissal resets the input. A session whose
    /// query was submitted (and then failed or was cancelled) is not abandoned:
    /// `journalActedQuery` matches the restored text.
    func endInteractionSession() {
        defer { journalActedQuery = nil }
        // Retention is a data-lifecycle rule, not recording: it applies whether
        // or not the journal is on, so an old log does not sit on disk forever
        // after the toggle is turned off. Pruning writes only when something
        // actually expired.
        interactionJournal.prune()
        guard settings.interactionJournalEnabled else { return }
        guard !isStreaming, output.isEmpty else { return }
        let folded = LauncherUsageStore.normalizedQuery(input)
        guard !folded.isEmpty, folded != journalActedQuery else { return }
        recordJournal(kind: .searchAbandoned, scope: learningScope, query: input)
    }

    /// Applies the journal's retention and cap from settings and trims what is
    /// already stored. Called at launch and whenever the settings change.
    func applyInteractionJournalSettings() {
        interactionJournal.retentionDays = settings.interactionJournalRetentionDays
        interactionJournal.eventCap = settings.interactionJournalEventCap
        interactionJournal.prune()
        interactionJournalRevision += 1
    }

    /// Journal rows, newest first, for the Settings review list and export.
    var interactionJournalEvents: [InteractionJournalEvent] {
        interactionJournal.recentEvents()
    }

    /// Bytes the journal occupies on disk.
    var interactionJournalByteSize: Int { interactionJournal.byteSize }

    /// Age of the newest journal row, or `nil` when the journal is empty.
    var interactionJournalLastEventDate: Date? { interactionJournal.lastEventDate }

    /// Explicit, reversible marker: "this recorded choice was the wrong one".
    /// Review metadata only — it is never fed into ranking.
    func setInteractionMarkedAccidental(id: UUID, accidental: Bool) {
        interactionJournal.setMarkedAccidental(accidental, id: id)
        journalActedQuery = nil
        interactionJournalRevision += 1
    }

    func clearInteractionJournal() {
        interactionJournal.clear()
        interactionJournalRevision += 1
    }

    /// Renders the journal for review. Pure: no UI, no disk.
    func renderInteractionJournal(as format: InteractionJournalExportFormat) -> String {
        InteractionJournalExporter.render(interactionJournal.recentEvents(), as: format)
    }

    /// Writes an export the user picked a location for. Owner-only `0600`.
    @discardableResult
    func writeInteractionJournal(
        as format: InteractionJournalExportFormat,
        to url: URL
    ) -> Bool {
        do {
            try InteractionJournalExporter.write(renderInteractionJournal(as: format), to: url)
            return true
        } catch {
            errorMessage = "Could not export the interaction journal: \(error.localizedDescription)"
            return false
        }
    }

    /// Shows the journal file in Finder, or its folder when nothing is stored
    /// yet. Local data only; nothing is uploaded.
    func revealInteractionJournal() {
        let file = InteractionJournalStore.defaultFileURL()
        if FileManager.default.fileExists(atPath: file.path) {
            workspace.revealInFileViewer([file])
        } else {
            workspace.revealInFileViewer([AppPaths.applicationSupportDirectory])
        }
    }

    var contextualCatalogItem: LauncherCatalogItem? {
        guard var item = resolveContextualCatalogItem() else { return nil }
        // Some sources (raw screenshot files, the emoji catalog) carry no
        // pin flag; without the stamp the ⌘K pane kept offering "Pin to
        // Top" on an item that was already pinned.
        if !item.isPinned { item.isPinned = isLauncherItemPinned(item) }
        return item
    }

    private func resolveContextualCatalogItem() -> LauncherCatalogItem? {
        guard let contextualCatalogItemID else { return nil }
        // A draft exists nowhere else yet, so it answers for itself.
        if let draftCatalogItem, draftCatalogItem.id == contextualCatalogItemID {
            return draftCatalogItem
        }
        if contextualCatalogItemID.hasPrefix("emoji:") {
            return emojiItems.first { $0.id == contextualCatalogItemID }
        }
        if contextualCatalogItemID.hasPrefix("screenshot:") {
            return screenshotFiles.first { $0.id == contextualCatalogItemID }
        }
        if contextualCatalogItemID.hasPrefix("conversation:") {
            return conversationItems.first { $0.id == contextualCatalogItemID }
        }
        return (configurableCatalogItems + clipboardEntries + systemCommands).first {
            $0.id == contextualCatalogItemID
        }
    }

    var pendingQuickLink: LauncherCatalogItem? {
        guard let pendingQuickLinkID else { return nil }
        return quickLinks.first { $0.id == pendingQuickLinkID }
    }

    var inputPlaceholder: String {
        switch inputMode {
        case .caffeinateUntil: return "Until 17:30, 5:30pm, 90m, or 2h…"
        case .renameChat: return "New name for this chat…"
        case .renameClipboard: return "New name for this entry…"
        case .houseCommandArgument:
            guard let row = pendingHouseCommandText else { return "Value…" }
            return "\(row.command.title)…"
        case .snippetArgument:
            guard let argument = pendingSnippetInsertion?.currentArgument else { return "Value…" }
            return argument.defaultValue.isEmpty
                ? "\(argument.name)…"
                : "\(argument.name) (\(argument.defaultValue))…"
        case nil: break
        }
        if let pendingQuickLink { return "Enter input for \(pendingQuickLink.title)…" }
        if let catalogScope { return "Search \(catalogScope.title.lowercased())…" }
        return "Search for apps and commands…"
    }

    /// The Quick AI composer's placeholder on an empty surface, Raycast's
    /// own words.
    static let quickAIPlaceholder = "Ask anything, @ to attach, or / for commands…"
    /// Once a thread exists and the next question joins it.
    static let quickAIFollowUpPlaceholder = "Ask a follow-up…"
    /// While Recent Chats is up the composer filters the list.
    static let recentChatsPlaceholder = "Search chats…"
    /// While an answer streams, Return queues what is typed and sends it
    /// when the answer ends; Escape stops the answer.
    static let streamingPlaceholder = "Type a follow-up; it sends when this answer ends"

    /// What the empty Quick AI composer says right now: what typing will do.
    var quickAIComposerPlaceholder: String {
        if isRecentChatsPresented { return Self.recentChatsPlaceholder }
        if isStreaming { return Self.streamingPlaceholder }
        if hasPendingChatContext { return "Ask about the attached context…" }
        if isFollowUp, !shouldStartNewConversation { return Self.quickAIFollowUpPlaceholder }
        return Self.quickAIPlaceholder
    }

    /// The one quiet line an empty Quick AI surface shows. Add Context and
    /// the commands are named by the composer placeholder and the model by
    /// the header, so only Recent Chats, which nothing else names, is here.
    /// Empty once the surface has anything to draw.
    var quickAIEmptyStateHints: [String] {
        guard conversationMessages.isEmpty,
              !isStreaming,
              threadNotice == nil,
              output.isEmpty,
              pendingQuestion == nil,
              lastQuestion == nil
        else { return [] }
        return ["\(shortcutLabel(for: .recentChats)) opens recent chats"]
    }

    /// What Return does from the Quick AI composer right now, drawn inside
    /// the field as a label and its key cap. The surface has no footer; this
    /// is its one hint.
    struct ComposerAction: Equatable, Sendable {
        enum Behavior: Equatable, Sendable { case submit, stop }
        let label: String
        let keys: [String]
        var behavior: Behavior = .submit
    }

    /// The visible button can offer Stop while Return still queues a draft.
    /// Keep its behavior explicit instead of interpreting its displayed label.
    func performComposerPrimaryAction() {
        switch quickAIComposerAction.behavior {
        case .submit: submitFromComposer()
        case .stop: cancel()
        }
    }

    /// What Return does in the Transform chooser, in its header and in the
    /// composer.
    static let transformChooserConfirmTitle = "Run"
    /// What Return does in Add Context, in its header and in the composer.
    static let addContextConfirmTitle = "Add"
    /// What Return does in the capture chooser (⇧⌘S), in both places.
    static let captureChooserConfirmTitle = "Attach"
    /// The composer's label while a follow-up waits for the stream to end.
    static let queuedActionLabel = "Queued"

    var quickAIComposerAction: ComposerAction {
        // A chooser above the composer takes Return (the order of
        // `topLayer`), so the field names the chooser's own action: two ↩
        // hints on one screen never disagree.
        if isTransformChooserPresented {
            return ComposerAction(label: Self.transformChooserConfirmTitle, keys: ["↩"])
        }
        if isModelChooserPresented {
            return ComposerAction(label: modelChooserPurpose.confirmTitle, keys: ["↩"])
        }
        if isAssistantChooserPresented {
            return ComposerAction(label: Self.assistantChooserConfirmTitle, keys: ["↩"])
        }
        if isCaptureChooserPresented {
            return ComposerAction(label: Self.captureChooserConfirmTitle, keys: ["↩"])
        }
        if isAddContextMenuPresented {
            return ComposerAction(label: Self.addContextConfirmTitle, keys: ["↩"])
        }
        // In Recent Chats, Return opens the highlighted chat; ↩ means one
        // thing on the screen.
        if isRecentChatsPresented { return ComposerAction(label: "Open", keys: ["↩"]) }
        if isStreaming {
            // A follow-up queued with Return waits in the field for the
            // stream to end; the label says so until it goes.
            if isFollowUpQueued { return ComposerAction(label: Self.queuedActionLabel, keys: ["↩"]) }
            return ComposerAction(label: "Stop", keys: ["esc"], behavior: .stop)
        }
        if !hasPendingChatContext, !output.isEmpty, input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch primaryAnswerAction {
            case .pasteToActiveApp: return ComposerAction(label: "Paste Response", keys: ["↩"])
            case .copyToClipboard: return ComposerAction(label: "Copy Response", keys: ["↩"])
            }
        }
        return ComposerAction(label: "Ask", keys: ["↩"])
    }

    /// The Quick AI header title: the conversation once it has an answer,
    /// "Quick AI" before that.
    var quickAITitle: String {
        guard let conversation = currentConversation,
              conversation.messages.contains(where: { $0.role == .assistant })
        else { return "Quick AI" }
        return title(of: conversation)
    }

    /// A chat's title with this Mac's saved-prompt prefix and aliases, so
    /// only a real alias is dropped from the question. The header, Recent
    /// Chats, the Chats catalog, and the menu all name a chat through here.
    func title(of conversation: QuickConversation) -> String {
        conversation.title(
            aliasPrefix: settings.savedPromptPrefix,
            aliases: Set(settings.savedPrompts.map(\.alias))
        )
    }

    /// The provider that answers the next text message: the open chat's
    /// own, a pick made before the chat began, then the Quick AI default.
    var activeProvider: InferenceProvider? {
        if let choice = chatModelChoice,
           let provider = settings.providers.first(where: { $0.id == choice.providerID }) {
            return provider
        }
        return settings.quickAIProvider
    }

    /// The id of the model that answers the next text message, or `nil`
    /// with no provider. What the chooser compares against; the header
    /// shows `activeModelDisplay`.
    var activeModelID: String? {
        guard let provider = activeProvider else { return nil }
        return chatModelOverride(for: provider) ?? provider.selectedModel
    }

    /// The model is per chat. The open chat answers on the model it keeps
    /// while that model is still offered (a chat written on a model since
    /// turned off, the sunset vision id for one, falls back); before a chat
    /// exists, a Change Model made on the empty surface. Nil leaves the
    /// Quick AI default in Settings.
    var chatModelChoice: ChatModelChoice? {
        if let conversation = currentConversation,
           !conversation.model.isEmpty,
           settings.providers.contains(where: { $0.id == conversation.providerID }),
           modelPreferences.isEnabled(providerID: conversation.providerID, model: conversation.model) {
            return ChatModelChoice(providerID: conversation.providerID, model: conversation.model)
        }
        return pendingModelChoice
    }

    /// The model the next text message uses on `provider`: the chat's own
    /// when it is on that provider, else the Quick AI default's override.
    func chatModelOverride(for provider: InferenceProvider) -> String? {
        if let choice = chatModelChoice, choice.providerID == provider.id { return choice.model }
        return settings.quickAIModelOverride(for: provider.id)
    }

    /// The header's second line: the display name of the model that will
    /// answer the next message (the vision model only while an image is
    /// attached), falling back to the id when the catalogue has no name.
    var activeModelDisplay: String {
        // Derived from the same resolved route the pre-Send control and the
        // send freeze read, so the header cannot name a different model than
        // the one that will answer.
        let route = resolvedNextRoute()
        if route.hasImages {
            guard route.canSendImages else { return "No vision model" }
            return route.model.isEmpty ? visionDisplayName : ModelProfile.displayName(forModelID: route.model)
        }
        guard let provider = activeProvider, let model = activeModelID else { return "No model" }
        return model.isEmpty ? provider.name : ModelProfile.displayName(forModelID: model)
    }

    /// The answer on screen (or running) came from a command action, not
    /// from the model: the header names that source.
    var answerSourceTitle: String? {
        guard isStreaming || !output.isEmpty else { return nil }
        switch answerSource {
        case .model: return nil
        case .command(let name): return name
        case .local: return Self.localAnswerSourceTitle
        }
    }

    /// The header's second line under a local answer asked in a chat.
    static let localAnswerSourceTitle = "Local answer"

    /// The Quick AI header's second line: the source of a command
    /// answer, otherwise the model that answers the next message.
    var quickAIHeaderSubtitle: String {
        answerSourceTitle ?? activeModelDisplay
    }

    /// Whether the ⇥ hint is drawn in root search. The key itself is not
    /// conditional: `handleTab()` always opens Quick AI.
    var showsTabShortcutHint: Bool { settings.tabShortcutHintVisible }

    var isFollowUp: Bool { !(currentConversation?.messages.isEmpty ?? true) }
    var conversationMessages: [QuickMessage] { currentConversation?.messages ?? [] }

    /// A finished answer that is not the thread's last assistant turn: a
    /// local answer (math, a conversion), a command action's result,
    /// or the partial text a failed stream left behind. The surface
    /// draws it after the thread; a streaming answer is drawn live instead.
    var quickAIDetachedAnswer: String? {
        guard !isStreaming, !output.isEmpty else { return nil }
        let lastAssistant = conversationMessages.last { $0.role == .assistant }?.content
        return lastAssistant == output ? nil : output
    }
    var pasteTargetName: String? { selectionTarget?.applicationName }
    var applications: [LaunchableApplication] { applicationCatalog?.applications ?? [] }
    var contextualApplication: LaunchableApplication? {
        guard let contextualApplicationID else { return nil }
        return applications.first { $0.id == contextualApplicationID }
    }
    var needsAccessibilityPermission: Bool {
        selectedTextService?.isAccessibilityTrusted == false
    }

    /// Replace `input` with `<prefix><alias> ` so the user can keep typing
    /// context after committing to a saved prompt.
    func complete(savedPrompt: SavedPrompt) {
        input = settings.savedPromptPrefix + savedPrompt.alias + " "
        requestInputFocus()
    }

    func completeFirstFuzzyAlias() {
        guard let first = savedPromptMatches.first else { return }
        complete(savedPrompt: first)
    }

    /// What Return means for the current input, in one fixed precedence.
    /// Live ranking (`rankLauncherMatches`) and Return both derive from the
    /// same rules: exact alias, then a deterministic local answer, then the
    /// highlighted row, then the model.
    enum SubmitIntent: Equatable {
        /// An attachment travels with whatever was typed; straight to `submit`.
        case attachment
        /// A typing-capture mode owns Return (`submitInputMode`).
        case inputMode
        /// An exact `/alias` that runs a local executable. Always wins, even
        /// over an active answer thread.
        case commandAlias
        /// Answer on screen, nothing typed: Return is a no-op.
        case answerIdle
        /// A local answer inline in root search, nothing typed: Return does
        /// what the answer row does (copy it).
        case rootAnswerIdle
        /// A Quick Link that takes typed input.
        case quickLinkInput
        /// A highlighted launcher row (application, catalog, item, or the
        /// inline local-answer row).
        case launcherRow(Int)
        /// A bare `/ali` that fuzzy-matches one saved prompt: complete and run.
        case fuzzyAliasCompletion
        /// Unmatched root-search text: it runs the first Fallback Command.
        /// `nil` is the empty list, where Return runs nothing.
        case fallbackCommand(String?)
        /// Everything else: saved prompt alias with context, or a free prompt.
        case prompt
    }

    func classifySubmit() -> SubmitIntent {
        // Only an explicit attachment forces the model-bound submission. A
        // captured background selection rides with the model when the model
        // is the chosen destination; it must not override Return on every
        // other launcher row (`hasPendingChatContext` counts both).
        if hasPendingAttachment { return .attachment }
        if inputMode != nil { return .inputMode }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if pendingQuickLink == nil, exactCommandAlias() != nil { return .commandAlias }
        if isAnswerActive {
            if trimmed.isEmpty { return .answerIdle }
        }
        if rootAnswer != nil, trimmed.isEmpty { return .rootAnswerIdle }
        if pendingQuickLink != nil { return .quickLinkInput }
        let matches = launcherMatches
        if !matches.isEmpty {
            let index = min(applicationSelectionIndex, matches.count - 1)
            if isRootFallbackRow(matches[index], query: trimmed) {
                return .fallbackCommand(settings.firstFallbackCommandID)
            }
            return .launcherRow(index)
        }
        if exactSavedPromptAction() == nil, isBareAliasQuery, savedPromptMatches.first != nil {
            return .fuzzyAliasCompletion
        }
        return .prompt
    }

    /// The always-present Ask AI row that carries the typed text is the row
    /// the Fallback Commands list replaces. A row the user pinned or asked for
    /// by its alias is an explicit choice and still asks the model.
    private func isRootFallbackRow(_ result: LauncherSearchResult, query: String) -> Bool {
        guard case .item(let item) = result,
              item.kind == .askAI,
              !item.value.isEmpty,
              !item.isPinned
        else { return false }
        let alias = launcherItemAlias(for: item)
        if !alias.isEmpty, FuzzyMatcher.fold(alias) == FuzzyMatcher.fold(query) { return false }
        return true
    }

    /// The saved prompt an exact `/alias` names, resolved once per Return.
    private func exactSavedPromptAction() -> SavedPromptResolver.Resolution? {
        SavedPromptResolver.resolveAction(
            input: input,
            prefix: settings.savedPromptPrefix,
            savedPrompts: settings.savedPrompts
        )
    }

    private func exactCommandAlias() -> SavedPromptResolver.Resolution? {
        guard let exact = exactSavedPromptAction(),
              settings.savedPrompts.first(where: { $0.id == exact.actionID })?
                  .commandExecutable?.isEmpty == false else { return nil }
        return exact
    }

    func submitResolvingFuzzyAlias() async {
        // A chooser floats above Recent Chats (`topLayer`), so it takes
        // Return first, in the same order Escape closes them.
        if isTransformArgumentFieldPresented {
            // Return in the argument field takes the typed value; empty is
            // refused rather than substituted.
            await submitTransformArgument()
            return
        }
        if isTransformReviewVisible {
            // Return on the review card accepts it, through the same
            // fail-closed write-back as Replace Selection.
            _ = await acceptTransformReview()
            return
        }
        if isTransformChooserPresented {
            // Return runs the focused transform in the keyboard-first chooser,
            // or picks the highlighted argument option while one is filling.
            await runTransformChooserSelection()
            return
        }
        if isModelChooserPresented {
            // Return in the model chooser picks the model the keys are on.
            await runModelChooserSelection()
            return
        }
        if isAssistantChooserPresented {
            // Return in Change Assistant picks the assistant the keys are on.
            runAssistantChooserSelection()
            return
        }
        if isCaptureChooserPresented {
            // Return in the capture chooser attaches the highlighted capture.
            await runCaptureChooserSelection()
            return
        }
        if isAddContextMenuPresented {
            // Return in Add Context attaches the highlighted entry.
            await runAddContextSelection()
            return
        }
        if isRecentChatsPresented {
            // Return in Recent Chats opens the highlighted chat in the thread.
            openSelectedRecentChat()
            return
        }
        // A built-in command never queues behind a stream: /new and /clear
        // run now, cancelling and resetting the chat before the follow-up
        // queue can defer them.
        if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let outcome = quickCommandOutcome(for: input) {
            switch outcome {
            case .newChat:
                performNewChatCommand()
                return
            case .clearChat:
                performClearChatCommand()
                return
            default:
                break
            }
        }
        // The composer keeps focus while an answer streams; Return queues
        // what is typed and it is sent when the stream ends. A chooser
        // above still takes Return while the stream runs.
        if isStreaming {
            queueFollowUp()
            return
        }
        await submitTypedText()
    }

    /// Return on typed text with no layer above the composer: what
    /// `classifySubmit` says it means. A queued follow-up is sent this way
    /// too, never through the layers above, which would pick in an open
    /// chooser instead of sending it.
    func submitTypedText() async {
        // Whatever is typed goes now; a follow-up queued before is this one.
        isFollowUpQueued = false
        switch classifySubmit() {
        case .attachment, .commandAlias, .prompt:
            await submit()
        case .inputMode:
            _ = await submitInputMode()
        case .answerIdle:
            // Return on a finished answer runs the Quick AI primary action:
            // paste into the app behind the overlay, or copy. ⌘↩ stays the
            // explicit paste, exactly as every other result action.
            await runPrimaryAnswerAction()
        case .rootAnswerIdle:
            if let rootAnswer { await performLauncherItem(Self.answerItem(rootAnswer)) }
        case .fallbackCommand(let identifier):
            await runRootFallback(identifier)
        case .quickLinkInput:
            if let pendingQuickLink { openQuickLink(pendingQuickLink, input: input) }
        case .launcherRow(let index):
            await performLauncherResult(launcherMatches[index])
        case .fuzzyAliasCompletion:
            if let first = savedPromptMatches.first {
                input = settings.savedPromptPrefix + first.alias
            }
            await submit()
        }
    }

    func resetApplicationSelection() {
        applicationSelectionIndex = 0
    }

    /// ↑↓ move a whole grid row in Emoji & Symbols and the screenshots grid, one item elsewhere.
    func moveSelectionVertically(_ direction: Int) {
        moveApplicationSelection(isGridCatalog ? direction * gridColumnCount : direction)
    }

    func moveApplicationSelection(_ delta: Int) {
        let matches = launcherMatches
        guard !matches.isEmpty else { return }
        // Swift's `%` keeps the dividend's sign, so a full grid-row step up from
        // the first row (`delta` of -9 in a short match list) would land on a
        // negative index and trap when the row is announced. Normalise it.
        let offset = (applicationSelectionIndex + delta) % matches.count
        applicationSelectionIndex = offset < 0 ? offset + matches.count : offset
        announceCurrentLauncherSelection()
        noteInteraction()
    }

    func announceCurrentLauncherSelection() {
        let matches = launcherMatches
        guard !matches.isEmpty else { return }
        let index = min(applicationSelectionIndex, matches.count - 1)
        let result = matches[index]
        let detail = Self.displayDetail(result)
        let detailPhrase = detail.isEmpty ? "" : ", \(detail)"
        launcherSelectionAnnouncement = "\(Self.displayTitle(result))\(detailPhrase), selected, \(index + 1) of \(matches.count). \(primaryActionTitle(for: result)) with Return."
        launcherSelectionAnnouncementRevision &+= 1
    }

    @discardableResult
    func launch(application: LaunchableApplication) -> Bool {
        guard let applicationCatalog else { return false }
        guard applicationCatalog.launch(application) else {
            errorMessage = "Could not open \(application.name)."
            requestInputFocus()
            return false
        }
        self.input = ""
        errorMessage = nil
        overlayPresenter.dismissOverlay()
        return true
    }

    func performLauncherResult(_ result: LauncherSearchResult) async {
        switch result {
        case .application(let application):
            // Capture the typed query first: a successful launch clears the
            // input, and the mnemonic must record what was actually typed.
            // A launch that fails is not a choice, so it must not teach
            // ranking. The attempt is still noted so dismissing the overlay
            // afterwards is not logged as an abandoned search.
            let typed = input
            let priorError = errorMessage
            if launch(application: application) {
                learn(result, query: typed)
            } else {
                noteActedQuery(typed)
                noteActionFailure(itemID: result.id, scope: learningScope, priorError: priorError)
            }
        case .catalog(let scope, _):
            learn(result)
            enterCatalog(scope)
        case .item(let item):
            learn(result)
            await performLauncherItem(item)
        }
    }

    /// Pull what the manager knows into the observable state.
    func syncCaffeinateState() {
        isCaffeinating = caffeinateManager?.isEnabled ?? false
        hasCaffeinateSession = caffeinateManager?.hasLiveSession ?? isCaffeinating
        caffeinatePauseDetail = caffeinateManager?.pauseDetail
        caffeinateEndsAt = caffeinateManager?.endsAt
        caffeinateReason = caffeinateManager?.reason
        invalidateLauncherRanking()
        scheduleCaffeinateCountdown()
    }

    /// The Settings › General › Caffeinate master switch: starts or stops a
    /// manual, indefinite session, exactly like the launcher's Caffeinate row.
    /// A timed session lives in `caffeinateUntil` and leaves this off.
    ///
    /// Returns whether the manager actually applied it. A failed assertion is
    /// not persisted as intent, so the toggle and the manager cannot disagree.
    @discardableResult
    func setCaffeinateEnabled(_ enabled: Bool) -> Bool {
        let applied = caffeinateManager?.setEnabled(enabled) ?? enabled
        guard applied else {
            syncCaffeinateState()
            return false
        }
        settings.caffeinateEnabled = enabled
        if enabled { settings.caffeinateUntil = nil }
        persistSettings(settings)
        syncCaffeinateState()
        return true
    }

    /// The manager's one-line effective state: held, why, or battery-paused.
    /// `isCaffeinating` is false while the battery has paused an otherwise-live
    /// intent, so the policy summary is the only honest source for the line.
    var caffeinateStatusSummary: String {
        caffeinateManager?.statusSummary
            ?? (isCaffeinating ? "Caffeinated." : "Decaffeinated. Normal Mac sleep is enabled.")
    }

    /// Pushes the Caffeinate preference switches (Agent Watch, battery cutoff,
    /// display assertion) onto the running manager and persists. It never
    /// starts or stops a session; `setCaffeinateEnabled` owns that.
    func applyCaffeinatePreferences() {
        caffeinateManager?.isAgentWatchEnabled = settings.caffeinateAgentWatch
        caffeinateManager?.batteryCutoff = settings.caffeinateBatteryCutoff
        caffeinateManager?.keepsDisplayAwake = settings.caffeinateKeepDisplayAwake
        persistSettings(settings)
        syncCaffeinateState()
    }

    /// A timed session shows minutes left, so the row is re-derived once a
    /// minute while one is running. Nothing runs when there is no deadline.
    private func scheduleCaffeinateCountdown() {
        caffeinateCountdownTask?.cancel()
        caffeinateCountdownTask = nil
        guard isCaffeinating, caffeinateEndsAt != nil else { return }
        caffeinateCountdownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self else { return }
            self.syncCaffeinateState()
        }
    }

    /// Scope key used when learning from a selection in the current view.
    var learningScope: String {
        catalogScope?.rawValue ?? LauncherUsageStore.rootScope
    }

    /// Remember that the user chose `result` for the current input. `query`
    /// overrides the field for a path that clears it before recording (a
    /// successful app launch), so the mnemonic keeps what was typed.
    func learn(_ result: LauncherSearchResult, query explicitQuery: String? = nil) {
        let query = explicitQuery ?? input
        noteActedQuery(query)
        recordJournal(
            kind: .selectionAccepted,
            scope: learningScope,
            itemID: result.id,
            query: query
        )
        guard settings.launcherLearningEnabled else { return }
        launcherUsage.recordSelection(query: query, scope: learningScope, itemID: result.id)
        launcherRankingVersion += 1
    }

    /// Remember a use that skipped the launcher, such as a global hotkey.
    func learnDirectUse(of item: LauncherCatalogItem) {
        learnDirectUse(itemID: item.id, scope: LauncherUsageStore.rootScope)
    }

    func learnDirectUse(of application: LaunchableApplication) {
        learnDirectUse(
            itemID: LauncherSearchResult.application(application).id,
            scope: LauncherUsageStore.rootScope
        )
    }

    /// One hotkey run of an item that never passed through the launcher.
    /// Journals the review row and, when ranking learning is on, the use count.
    func learnDirectUse(itemID: String, scope: String) {
        noteDirectHotkeyUse(itemID: itemID, scope: scope)
        guard settings.launcherLearningEnabled else { return }
        launcherUsage.recordUse(itemID: itemID, scope: scope)
        launcherRankingVersion += 1
    }

    /// Journal row for a hotkey run with no launcher item to learn against,
    /// such as a saved AI action. Ranking is left untouched.
    /// The hotkey row for a saved action: `action:<uuid>`, the same id a
    /// `savedActionRun` row carries.
    func noteDirectHotkeyUse(ofAction action: SavedPrompt) {
        noteDirectHotkeyUse(itemID: "action:\(action.id.uuidString)")
    }

    func noteDirectHotkeyUse(
        itemID: String,
        scope: String = LauncherUsageStore.rootScope
    ) {
        recordJournal(kind: .directHotkeyUse, scope: scope, itemID: itemID)
    }

    /// Journal row for a feature that has no launcher row: kind and a stable
    /// id only (`feature:<name>`, `action:<uuid>`, `command:<id>`), never
    /// the text, selection, answer or prompt it worked on.
    func noteFeatureUse(_ kind: InteractionJournalEventKind, itemID: String) {
        recordJournal(kind: kind, itemID: itemID)
    }

    /// The app's wiring from Type to Click to the journal. AppDelegate and the
    /// tests both call this, so a test exercises the real path.
    func journalFeatureUse(of controller: TypeToClickController) {
        controller.onTargetUsed = { [weak self] in
            self?.noteFeatureUse(.typeToClickUsed, itemID: "feature:type-to-click")
        }
    }

    /// The app's wiring from the Translator window to the journal.
    func journalFeatureUse(of model: TranslatorModel) {
        model.onTranslationRun = { [weak self] in
            self?.noteFeatureUse(.translatorRun, itemID: "feature:translator")
        }
    }

    func forgetLearnedRanking() {
        launcherUsage.reset()
        launcherRankingVersion += 1
        applicationSelectionIndex = 0
    }

    /// Call after an alias or hotkey edit so cached rankings pick it up.
    func invalidateLauncherRanking() {
        launcherRankingVersion += 1
    }
}
