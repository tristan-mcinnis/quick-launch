import Foundation

/// The connected input flow the composer drives: choosing a source from the
/// Clipboard History submenu, filling a saved transform's `{argument …}`
/// slots through the existing Transform chooser, and reviewing the result of
/// a `.reviewChanges` transform before anything is written back.
///
/// Every path here attaches or shows; nothing sends on its own. A chosen
/// clipboard item becomes an ordinary tray attachment (no auto-send, the
/// draft is never touched), and an argument chooser uses the same keyboard
/// routing the Transform chooser already had.
extension QuickViewModel {
    // MARK: - Clipboard History submenu

    /// The clipboard catalog rows the submenu lists, after its own search.
    /// The rows are the store's own `LauncherCatalogItem`s, so type and pin
    /// metadata come for free and no new store is introduced.
    var clipboardHistoryRows: [LauncherCatalogItem] {
        ClipboardHistoryAttachments.rows(from: clipboardEntries, query: clipboardHistoryQuery)
    }

    /// Open the submenu over Add Context. It is keyboard-first: the pane's
    /// field takes typing, the arrows move, Return attaches, Escape goes back
    /// to the Add Context rows.
    func openClipboardHistory() {
        clipboardHistoryIndex = 0
        clipboardHistoryQuery = ""
        isClipboardHistoryOpen = true
        requestInputFocus()
    }

    /// Escape in the submenu: back to the Add Context rows.
    func closeClipboardHistory() {
        guard isClipboardHistoryOpen else { return }
        isClipboardHistoryOpen = false
        clipboardHistoryQuery = ""
        requestInputFocus()
    }

    func moveClipboardHistorySelection(_ delta: Int) {
        let rows = clipboardHistoryRows
        guard !rows.isEmpty else { return }
        clipboardHistoryIndex = ListSelection.wrappedIndex(
            clipboardHistoryIndex,
            by: delta,
            count: rows.count
        )
    }

    /// Return in the submenu: attach the highlighted item, then close back to
    /// the composer with the draft intact. Nothing is sent.
    func runClipboardHistorySelection() async {
        let rows = clipboardHistoryRows
        guard rows.indices.contains(clipboardHistoryIndex) else { return }
        await attachClipboardHistoryItem(rows[clipboardHistoryIndex])
    }

    /// Attach one clipboard catalog item. Text becomes a labelled retained
    /// selection; a picture or a file becomes a typed attachment. The store
    /// has already dropped concealed and transient copies, so this reads only
    /// what the user's own history kept.
    func attachClipboardHistoryItem(_ item: LauncherCatalogItem) async {
        guard let payload = await fullClipboardPayload(for: item) else {
            errorMessage = "That clipboard item is no longer available."
            requestInputFocus()
            return
        }
        let sources = ClipboardHistoryAttachments.sources(for: payload)
        guard !sources.isEmpty else {
            errorMessage = "That clipboard item has nothing to attach."
            requestInputFocus()
            return
        }
        errorMessage = nil
        if sources.count == 1, let text = sources[0].transformText {
            // The user chose this source, so a transform must act on it; the
            // stale launch snapshot steps aside rather than overriding it.
            explicitTransformSource = text
            explicitTransformSourceLabel = ClipboardHistoryAttachments.clipboardAppName
            launchSelection = nil
        }
        // Every file the payload held attaches, never only the first one.
        for source in sources { attachmentTray.add(source) }
        let omitted = ClipboardHistoryAttachments.omittedFileCount(for: payload)
        errorMessage = omitted > 0
            ? "\(omitted) \(omitted == 1 ? "file was" : "files were") not attached."
            : nil
        isClipboardHistoryOpen = false
        clipboardHistoryQuery = ""
        closeAddContextMenu()
        requestInputFocus()
    }

    // MARK: - The selection a transform acts on

    /// The text a selection-shaped transform can act on, from the strongest
    /// source available: the launch snapshot, an explicitly attached
    /// selection, or a selection chip chosen from Clipboard History. Nil when
    /// nothing is available. This is what makes a transform reachable from a
    /// chosen clipboard source, not only from a live selection.
    var selectionTransformSource: String? {
        // An explicitly chosen source always beats the auto-captured launch
        // snapshot: text the user attached (from Clipboard History or the
        // selected text) must not be overridden by stale background text.
        if let text = explicitTransformSource, Self.isMeaningful(text),
           attachmentTray.readyContents.contains(where: { $0.isTransformTextSource && $0.text == text }) {
            return text
        }
        if let text = pendingContext?.selectedText, Self.isMeaningful(text) { return text }
        if let text = attachmentTray.readyContents
            .last(where: { $0.isTransformTextSource })?.text, Self.isMeaningful(text) {
            return text
        }
        if let text = launchSelection?.text, Self.isMeaningful(text) { return text }
        return nil
    }

    /// Whether a transform of any kind is reachable right now.
    var hasTransformSource: Bool { selectionTransformSource != nil }

    /// Where the active transform source came from. "Clipboard" or an app
    /// name; nil when there is no source. Only metadata: it never changes what
    /// text the transform acts on.
    var selectionTransformSourceLabel: String? {
        if let text = explicitTransformSource, Self.isMeaningful(text),
           attachmentTray.readyContents.contains(where: { $0.isTransformTextSource && $0.text == text }) {
            return explicitTransformSourceLabel
        }
        if let text = pendingContext?.selectedText, Self.isMeaningful(text) {
            return pendingContext?.appName
        }
        if let chip = attachmentTray.readyContents.last(where: { $0.isTransformTextSource }),
           Self.isMeaningful(chip.text ?? "") {
            if chip.kindLabel == "Clipboard" { return ClipboardHistoryAttachments.clipboardAppName }
            return chip.ref.name.hasPrefix("Selection · ")
                ? String(chip.ref.name.dropFirst("Selection · ".count))
                : chip.ref.name
        }
        if let text = launchSelection?.text, Self.isMeaningful(text) {
            return launchSelection?.appName
        }
        return nil
    }

    private static func isMeaningful(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Transform arguments

    /// The rows the Transform chooser draws: the saved transforms normally,
    /// or the current argument slot's options while one is being filled.
    var transformChooserOptions: [ChipTransformOption] {
        guard let pending = pendingTransformArguments,
              let slot = pending.currentSlot
        else { return chipTransformOptions }
        return slot.options.enumerated().map { index, option in
            ChipTransformOption(
                kind: .argument(index),
                title: option,
                systemImage: index == 0 ? "1.circle" : "\(min(index + 1, 9)).circle"
            )
        }
    }

    /// The chooser's heading: the slot being filled, or the generic label.
    var transformChooserTitle: String {
        guard let slot = pendingTransformArguments?.currentSlot else {
            return "Transform selected text"
        }
        return "Choose \(slot.name)"
    }

    /// Start a transform run. A prompt with an unfilled slot that offers
    /// `options` opens the chooser for that slot (one at a time, never a
    /// modal storm); otherwise the defaults are collected and the transform
    /// sends at once.
    func beginTransformArguments(
        action: SavedPrompt,
        source: String,
        sourceLabel: String? = nil
    ) async {
        // Required fields always have a visible owner, even from root search.
        if !isQuickAIPresented && !isAIChatWindow { openQuickAI() }
        let slots = SavedPromptResolver.argumentSlots(in: action.prompt)
        let values = slots.map(\.defaultValue)
        pendingTransformArguments = PendingTransformArguments(
            actionID: action.id,
            alias: action.alias,
            source: source,
            sourceLabel: sourceLabel,
            slots: slots,
            values: values,
            choosing: nil,
            filling: nil
        )
        await advanceTransformArguments()
    }

    /// The first slot, in the order the template names them, that still
    /// needs the user. A slot with a `default` is already filled; an option
    /// slot needs a choice; a slot with no default needs a typed value.
    private static func firstPendingSlot(
        in slots: [SnippetArgument],
        values: [String]
    ) -> Int? {
        slots.enumerated().first { index, slot in
            let value = values.indices.contains(index) ? values[index] : ""
            guard value.isEmpty else { return false }
            if slot.offersOptions { return true }
            return slot.defaultValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.offset
    }

    /// Move to the next slot that still needs the user, in order: an option
    /// slot opens the Transform chooser, a required free-text slot opens the
    /// argument field. When none is left, the transform runs with what was
    /// collected.
    func advanceTransformArguments() async {
        guard var pending = pendingTransformArguments else { return }
        if let index = Self.firstPendingSlot(in: pending.slots, values: pending.values) {
            let slot = pending.slots[index]
            pending.choosing = slot.offersOptions ? index : nil
            pending.filling = slot.offersOptions ? nil : index
            pendingTransformArguments = pending
            if slot.offersOptions {
                presentTransformArguments()
            } else {
                presentTransformArgumentField()
            }
            return
        }
        let finished = pending
        pendingTransformArguments = nil
        transformArgumentInput = ""
        isTransformChooserPresented = false
        guard let action = settings.savedPrompts.first(where: { $0.id == finished.actionID }) else { return }
        await runCollectedTransform(
            action: action,
            source: finished.source,
            sourceLabel: finished.sourceLabel,
            arguments: finished.values
        )
    }

    /// True while a required free-text `{argument}` is being typed.
    var isTransformArgumentFieldPresented: Bool {
        pendingTransformArguments?.filling != nil
    }

    /// The label of the slot the argument field is asking for.
    var transformArgumentPrompt: String? {
        pendingTransformArguments?.fillingSlot?.name
    }

    /// Return in the argument field: the typed value, or a refusal when the
    /// slot would be left empty. The field owns IME composition, so a Return
    /// that is committing an IME candidate never reaches here as a submit.
    func submitTransformArgument() async {
        guard let pending = pendingTransformArguments, let index = pending.filling else { return }
        let text = transformArgumentInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "Enter a value for \(pending.fillingSlot?.name ?? "this argument")."
            requestInputFocus()
            return
        }
        var updated = pending
        updated.values[index] = text
        updated.filling = nil
        pendingTransformArguments = updated
        errorMessage = nil
        await advanceTransformArguments()
    }

    private func presentTransformArgumentField() {
        transformArgumentInput = ""
        isTransformChooserPresented = false
        isModelChooserPresented = false
        isAssistantChooserPresented = false
        isCaptureChooserPresented = false
        isAddContextMenuPresented = false
        isActionPalettePresented = false
        isClipboardHistoryOpen = false
        errorMessage = nil
        requestInputFocus()
    }

    private func presentTransformArguments() {
        transformChooserIndex = 0
        isTransformChooserPresented = true
        isModelChooserPresented = false
        isAssistantChooserPresented = false
        isCaptureChooserPresented = false
        isAddContextMenuPresented = false
        isActionPalettePresented = false
        isClipboardHistoryOpen = false
        errorMessage = nil
        requestInputFocus()
    }

    /// Pick one option for the slot the chooser is on. The next slot with a
    /// choice opens in the same chooser; after the last, the transform runs.
    func chooseTransformArgument(index: Int) async {
        guard var pending = pendingTransformArguments,
              let slot = pending.currentSlot,
              slot.options.indices.contains(index)
        else { return }
        pending.values[slot.index] = slot.options[index]
        pending.choosing = nil
        pendingTransformArguments = pending
        transformChooserIndex = 0
        await advanceTransformArguments()
    }

    /// Escape out of the argument chooser or field: nothing is sent, the
    /// source and the composer draft stay as they were.
    func cancelTransformArguments() {
        pendingTransformArguments = nil
        transformArgumentInput = ""
        isTransformChooserPresented = false
        requestInputFocus()
    }

    /// Run a saved transform with its collected argument values, through the
    /// normal submit path so persistence, the frozen route, and the context
    /// receipt are exactly a transform's.
    private func runCollectedTransform(
        action: SavedPrompt,
        source: String,
        sourceLabel: String?,
        arguments: [String]
    ) async {
        pendingActionSource = source
        pendingActionSourceLabel = sourceLabel ?? selectionTransformSourceLabel
        pendingActionArguments = arguments
        // The source is stashed on the request now; the attached chip stays
        // as the transform source for any later run.
        explicitTransformSource = nil
        explicitTransformSourceLabel = nil
        isActionPalettePresented = false
        actionQuery = ""
        input = settings.savedPromptPrefix + action.alias
        await submit()
    }

    // MARK: - Transform review (.reviewChanges)

    /// True while a `.reviewChanges` transform's original/proposed card is up.
    var isTransformReviewPresented: Bool { pendingTransformReview != nil }

    /// True only when that card is drawn on the surface that owns it. The
    /// review is rendered by the Quick AI / AI Chat floating chooser, so a
    /// Return at the root after leaving Quick AI must not accept an invisible
    /// review.
    var isTransformReviewVisible: Bool {
        isTransformReviewPresented && (isQuickAIPresented || isAIChatWindow)
    }

    /// Drop any in-progress transform flow: a pending argument chooser or
    /// field, and a review card. Called wherever the surface changes, so an
    /// abandoned transform can never be resumed or accepted later.
    func clearTransformFlowState() {
        pendingTransformArguments = nil
        transformArgumentInput = ""
        isTransformChooserPresented = false
        pendingTransformReview = nil
    }

    /// Accept the review: write the proposed text back through the same
    /// fail-closed live-selection check every Replace Selection uses. A
    /// changed or unreadable selection copies instead and says so.
    @discardableResult
    func acceptTransformReview() async -> Bool {
        guard let review = pendingTransformReview, isTransformReviewVisible else { return false }
        pendingTransformReview = nil
        // No bound live selection (a clipboard or attached source, or the
        // selection was not the transformed text): copy, never guess an app.
        guard let target = review.target, let selectedTextService else {
            copyOutputAndMark()
            errorMessage = review.target == nil
                ? "This transform ran on an attached source, so the result was copied instead of replacing a selection."
                : "Could not replace the selection. The result was copied instead."
            requestInputFocus()
            return false
        }
        return await writeBackValidated(
            output: review.proposed,
            in: target,
            service: selectedTextService
        )
    }

    /// Cancel the review: keep the answer on screen, replace nothing.
    func cancelTransformReview() {
        guard pendingTransformReview != nil else { return }
        pendingTransformReview = nil
        requestInputFocus()
    }

    /// Copy the proposed text and take the card down.
    func copyTransformReview() {
        pendingTransformReview = nil
        copyOutputAndMark()
        requestInputFocus()
    }
}
