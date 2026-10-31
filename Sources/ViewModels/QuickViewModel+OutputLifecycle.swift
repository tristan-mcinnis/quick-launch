import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    // MARK: - Copy

    /// Auto-copy ("Copy the first answer of each chat automatically") takes
    /// only the first answer of a Quick AI chat. A follow-up never replaces
    /// what the user copied since, and the AI Chat window, where a chat runs
    /// long, never copies on its own. `chatHadAnswer` is whether the chat
    /// already showed an answer when this one was asked.
    func autoCopiesAnswer(chatHadAnswer: Bool) -> Bool {
        settings.autoCopy && !isAIChatWindow && !chatHadAnswer
    }

    /// True while the open chat shows an answer: a saved answer turn, or a
    /// local or command answer drawn under the thread.
    var chatShowsAnswer: Bool {
        !output.isEmpty || currentConversation?.messages.contains { $0.role == .assistant } == true
    }

    /// Copies the answer on screen. Every copy of an AI answer (auto-copy,
    /// Copy Answer, the copy a failed paste falls back to) is transient, so
    /// the Clipboard History and other clipboard managers skip it.
    func copyOutput() {
        guard !output.isEmpty else { return }
        pasteboard.writeTransientString(output)
    }

    func copyOutputAndMark() {
        guard !output.isEmpty else { return }
        copyOutput()
        markJustCopied()
    }

    /// Copy Answer on the Quick AI surface: copy, keep the surface open, and
    /// confirm in the composer.
    func copyAnswerOnSurface() {
        guard !output.isEmpty else { return }
        copyOutputAndMark()
        confirmInComposer("Copied")
        requestInputFocus()
    }

    /// Copy Chat (`⌥⌘C`): the whole thread as a labelled transcript, "You:"
    /// for each question and the model's display name for each answer.
    func copyChatTranscript() {
        guard let conversation = currentConversation, !conversation.messages.isEmpty else { return }
        // A chat is AI answers too: transient, as `copyOutput`.
        pasteboard.writeTransientString(conversation.labelledTranscript)
        markJustCopied()
        confirmInComposer("Chat copied")
        requestInputFocus()
    }

    // MARK: - Just-copied flash

    func markJustCopied() {
        justCopiedTask?.cancel()
        justCopied = true
        justCopiedTask = Task { @MainActor [weak self, timeout = justCopiedTimeout] in
            try? await Task.sleep(for: timeout)
            // A second copy cancelled this task and started a new flash: the
            // old task must not clear the new one.
            guard !Task.isCancelled else { return }
            self?.justCopied = false
        }
    }

    /// The save counterpart of `markJustCopied`: a short launcher flash that
    /// a capture landed in the Screenshots folder.
    func markJustSaved() {
        justSavedTask?.cancel()
        justSaved = true
        justSavedTask = Task { @MainActor [weak self, timeout = justCopiedTimeout] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.justSaved = false
        }
    }

    func clearOutput() {
        output = ""
        errorMessage = nil
    }

    /// Which part of the overlay a reset clears. Every "leave", "clear",
    /// or "start over" path goes through `reset(_:)` so nothing is forgotten.
    struct ResetScope: OptionSet, Sendable {
        let rawValue: UInt8
        /// ⌘K pane, palette, sub-form, delete arming, action query.
        static let layers = ResetScope(rawValue: 1 << 0)
        /// Catalog, Quick Link input, input mode.
        static let mode = ResetScope(rawValue: 1 << 1)
        /// Attachments and screen-awareness context.
        static let attachments = ResetScope(rawValue: 1 << 2)
        /// The answer thread: stream, output, conversation, last question.
        static let thread = ResetScope(rawValue: 1 << 3)
        /// Typed text and the selection index.
        static let input = ResetScope(rawValue: 1 << 4)
        static let all: ResetScope = [.layers, .mode, .attachments, .thread, .input]
    }

    func reset(_ scope: ResetScope, cancelingSubmitTasks: Bool = true) {
        // Leaving the surface or clearing the field: a follow-up held behind
        // a layer is not sent when the layers below close.
        if !scope.isDisjoint(with: [.mode, .input]) { isFollowUpQueued = false }
        if scope.contains(.layers) {
            presentedLayer = nil
            actionPaletteSubmenu = nil
            contextualApplicationID = nil
            contextualCatalogItemID = nil
            activeItemActionForm = nil
            deleteArmedItemID = nil
            actionQuery = ""
            clearTransformFlowState()
        }
        if scope.contains(.mode) {
            catalogIdleResetTask?.cancel()
            isQuickAIPresented = false
            isRecentChatsPresented = false
            catalogScope = nil
            pendingQuickLinkID = nil
            inputMode = nil
            pendingSnippetInsertion = nil
            pendingHouseCommandText = nil
            pendingHouseChoice = nil
            draftCatalogItem = nil
        }
        if scope.contains(.attachments) {
            pendingImages.removeAll()
            pendingContext = nil
            attachmentTray.removeAll()
            clearLaunchScopedState()
        }
        if scope.contains(.thread) {
            // A stream still running belongs to the thread being cleared, as
            // do the command and queued-follow-up tasks: a command result
            // must not land in a just-cleared chat. The submit tasks are
            // cancelled too, unless the reset is running inside one (the
            // new-chat path in `stream`).
            streamGeneration &+= 1
            inFlightTurn = nil
            // A clear waiting on this turn goes with the thread it described.
            isTransientClearDeferred = false
            streamTask?.cancel()
            streamTask = nil
            commandTask?.cancel()
            commandTask = nil
            if cancelingSubmitTasks {
                tabSubmitTask?.cancel()
                tabSubmitTask = nil
                composerSubmitTask?.cancel()
                composerSubmitTask = nil
            }
            queuedFollowUpTask?.cancel()
            queuedFollowUpTask = nil
            discardStreamBuffer()
            isStreaming = false
            streamingStatus = nil
            output = ""
            answerSource = .model
            threadError = nil
            isFollowUpQueued = false
            isThreadFollowingBottom = true
            errorMessage = nil
            lastQuestion = nil
            pendingQuestion = nil
            enrichmentSubmittedInput = nil
            webSearchNote = nil
            liveToolRecords = []
            pendingChatTools = nil
            pendingModelChoice = nil
            threadNotice = nil
            replaceableSelectionContext = nil
            clearTransformFlowState()
            currentConversation = nil
            reattachStates = [:]
        }
        if scope.contains(.input) {
            input = ""
            // A local answer is what was typed, answered; it goes with it.
            rootAnswer = nil
            errorMessage = nil
            applicationSelectionIndex = 0
        }
    }

    /// Back to the root surface, like a fresh open. The conversation is
    /// kept so a reopened overlay can still browse to it; only what was on
    /// screen goes.
    ///
    /// A model answer still streaming owns its text until the turn ends.
    /// Clearing here would drop the prefix already shown while the stream
    /// goes on appending, so the saved answer would be its tail alone; the
    /// clear therefore waits for the turn (`runDeferredTransientClear`).
    func clearTransientDisplay() {
        guard !isStreaming else {
            isTransientClearDeferred = true
            return
        }
        performTransientDisplayClear()
    }

    /// The reader came back to the panel before the deferred clear ran (the
    /// overlay reopens inside its retention window): the surface stays.
    func cancelDeferredTransientClear() {
        isTransientClearDeferred = false
    }

    /// The turn settled: run a clear a dismissal left waiting. Nothing else
    /// is on screen by then, so this is the ordinary transient clear.
    func runDeferredTransientClear() {
        guard isTransientClearDeferred else { return }
        performTransientDisplayClear()
    }

    private func performTransientDisplayClear() {
        isTransientClearDeferred = false
        reset([.layers, .mode, .attachments, .input])
        clearOutput()
        lastQuestion = nil
    }

    /// Overlay open: offer a clipboard image once per copy, only when the
    /// user turned that on. A clipboard the user already saw (or dismissed)
    /// is not re-attached, and a non-image clipboard never clears an
    /// attachment retained for follow-ups.
    func captureImageFromClipboard(from pasteboard: NSPasteboard = .general) {
        guard settings.attachClipboardImageOnOpen else { return }
        // A fresh image belongs in history while browsing a catalog. Offering
        // it as an AI attachment here discarded the retained history panel.
        guard catalogScope == nil else { return }
        guard let fresh = ClipboardImageReader.attachmentIfFresh(from: pasteboard) else { return }
        pendingImage = fresh
        errorMessage = nil
        catalogScope = nil
        pendingQuickLinkID = nil
        applicationSelectionIndex = 0
    }

    /// Backspace: drop the newest attachment; the × button clears all.
    func removePendingImage() {
        if attachmentTray.removeNewest() {
            requestInputFocus()
            return
        }
        if pendingImages.count > 1 {
            pendingImages.removeLast()
            return
        }
        pendingImages.removeAll()
        pendingContext = nil
        requestInputFocus()
    }
}
