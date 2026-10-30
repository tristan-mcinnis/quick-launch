import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// Continue in pi.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - Continue in pi

    /// The start of the pi line when the hand-off stopped an answer.
    static let piStoppedAnswerPrefix = "Answer stopped. "

    /// Continue in pi (`⌥⌘P`): the thread goes to a new pi session in its
    /// own tmux session, and Ghostty opens on it (`PiHandoffService`). The
    /// surface stays open and the thread ends with a line naming the
    /// session. When Ghostty does not open, the session still runs and the
    /// attach command is copied instead. An answer still streaming stops
    /// first and keeps what arrived, as Escape does; pi gets it, and the
    /// line says the answer was stopped.
    func continueInPi() async {
        isActionPalettePresented = false
        guard piHandoff != nil,
              currentConversation?.messages.isEmpty == false,
              !isHandingOffToPi
        else { return }
        let stoppedAnswer = isStreaming
        if stoppedAnswer {
            cancel()
            // The question too, when no text arrived to save it with.
            persistCurrentConversation()
        }
        guard let piHandoff,
              let conversation = currentConversation,
              !conversation.messages.isEmpty
        else { return }
        isHandingOffToPi = true
        defer { isHandingOffToPi = false }
        errorMessage = nil
        let request = PiHandoffRequest(
            title: title(of: conversation),
            markdown: piHandoffMarkdown(for: conversation),
            workingDirectory: nil
        )
        do {
            let result = try await piHandoff.handOff(request)
            noteFeatureUse(.piHandoffWritten, itemID: "feature:pi-handoff")
            // The line belongs to the chat that was handed off.
            if currentConversation?.id == conversation.id {
                let stopped = stoppedAnswer ? Self.piStoppedAnswerPrefix : ""
                if result.openedGhostty {
                    setThreadNotice(
                        stopped + "Opened in pi · tmux session \(result.sessionName)",
                        symbol: Self.piNoticeSymbol
                    )
                } else {
                    // Plumbing the app wrote, not a copy the user keeps.
                    pasteboard.writeTransientString(result.attachCommand)
                    setThreadNotice(
                        stopped + "Started pi in tmux session \(result.sessionName) · "
                            + "Ghostty did not open, attach command copied",
                        symbol: Self.piNoticeSymbol
                    )
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        requestInputFocus()
    }

    /// The thread as pi gets it: every answer with its saved tool lines and
    /// sources. A search line still on screen and not yet saved opens the
    /// answer it was made for: the first answer after the newest question.
    func piHandoffMarkdown(for conversation: QuickConversation, date: Date = Date()) -> String {
        var toolLines: [UUID: [String]] = [:]
        if let note = webSearchNote,
           let lastQuestion = conversation.messages.lastIndex(where: { $0.role == .user }),
           let answer = conversation.messages[lastQuestion...].first(where: { $0.role == .assistant }) {
            toolLines[answer.id] = [note]
        }
        let attachments = attachmentStore
        return PiHandoffDocument.markdown(
            title: title(of: conversation),
            modelName: ModelProfile.displayName(forModelID: conversation.model),
            messages: conversation.messages,
            toolLines: toolLines,
            attachmentText: { attachments.text(for: $0)?.text },
            date: date
        )
    }

    /// Shows `message` with a checkmark in the composer for
    /// `composerConfirmationDuration`. A second copy restarts the clock.
    func confirmInComposer(_ message: String) {
        composerConfirmationTask?.cancel()
        composerConfirmation = message
        composerConfirmationTask = Task { @MainActor [weak self, duration = composerConfirmationDuration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.composerConfirmation = nil
        }
    }

    /// Replace the originally captured selection with the current output.
    /// Only ever called by an explicit user action: a saved action that used a
    /// captured selection leaves its result on screen, then the user picks
    /// Replace Selection (here) or Copy. The captured target and text are
    /// retained across the request, so the write goes back to the snapshot the
    /// action ran on, not the app that happens to be frontmost now. Before
    /// writing we re-read the live selection and fail **closed** to Copy: if the
    /// selection changed or cannot be read at all, we never overwrite what we
    /// cannot confirm is the original, and we say so truthfully.
    @discardableResult
    func replaceOutputInCapturedSelection() async -> Bool {
        guard !output.isEmpty else { return false }
        guard let selectedTextService else { return false }
        guard let context = replaceableSelectionContext else {
            copyOutputAndMark()
            errorMessage = "The current answer did not replace a captured selection. The result was copied instead."
            requestInputFocus()
            return false
        }
        return await writeBackValidated(output: output, in: context, service: selectedTextService)
    }

    /// Shared fail-closed write-back: re-reads the live selection and only
    /// writes when it still matches the captured one. Used by both the explicit
    /// Replace Selection action and a custom `.replaceSelection` saved action's
    /// auto-write, so a stale or unreadable selection is never overwritten.
    /// On any failure it copies the output and reports why, truthfully.
    func writeBackValidated(
        output text: String,
        in context: SelectedTextContext?,
        service selectedTextService: any SelectedTextServicing
    ) async -> Bool {
        guard let context, !text.isEmpty else {
            copyOutputAndMark()
            errorMessage = "Could not replace the selection. The result was copied instead."
            requestInputFocus()
            return false
        }
        // Fail closed: if the live selection cannot be read, we cannot confirm
        // it is still the original, so copy instead of risk overwriting it.
        guard let live = selectedTextService.capture(
            from: context.target,
            promptForPermission: false
        ) else {
            copyOutputAndMark()
            errorMessage = "Could not read the current selection in \(context.target.applicationName). The result was copied instead."
            requestInputFocus()
            return false
        }
        if live.text != context.text {
            copyOutputAndMark()
            errorMessage = "The selection changed. The result was copied instead of replacing."
            requestInputFocus()
            return false
        }
        prepareForExternalAction?()
        await Task.yield()
        let outcome = await selectedTextService.replaceOutcome(text, in: context)
        if outcome == .clipboardChanged {
            errorMessage = Self.clipboardChangedMessage
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        guard outcome == .pasted else {
            copyOutputAndMark()
            errorMessage = selectedTextService.isAccessibilityTrusted
                ? "Could not replace the selection in \(context.target.applicationName). The result was copied instead."
                : "Allow Accessibility in System Settings, then try again. The result was copied."
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        overlayPresenter.dismissOverlay()
        return true
    }

    @discardableResult
    func pasteOutputToPreviousApp() async -> Bool {
        guard !output.isEmpty else { return false }
        guard let selectionTarget, let selectedTextService else {
            // Nothing to paste into: copy, as every other failure here does,
            // so the answer is never trapped on screen with no way out.
            copyOutputAndMark()
            errorMessage = "Open Quick Launch from the app where you want to paste. The result was copied instead."
            requestInputFocus()
            return false
        }
        let outcome = await selectedTextService.pasteOutcome(output, to: selectionTarget)
        if outcome == .clipboardChanged {
            errorMessage = Self.clipboardChangedMessage
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        guard outcome == .pasted else {
            copyOutputAndMark()
            errorMessage = "Could not paste into \(selectionTarget.applicationName). The result was copied instead."
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        overlayPresenter.dismissOverlay()
        return true
    }

    /// Paste Formatted Response (`⌃⌘V`): publish the answer's plain, HTML and
    /// RTF representations on the pasteboard and press ⌘V in the app behind.
    ///
    /// The rich path never uses the accessibility insert-at-caret text write,
    /// which only carries a string and would drop the formatting; the
    /// pasteboard plus ⌘V is what preserves it. When the answer is plain prose
    /// with no structure to keep, or a rich representation could not be built,
    /// it falls back to the ordinary plain paste, so the action never fails
    /// just because there was nothing rich to carry. Either way the answer is
    /// on the clipboard first, one manual ⌘V away.
    @discardableResult
    func pasteFormattedOutputToPreviousApp() async -> Bool {
        guard !output.isEmpty else { return false }
        let representation = FormattedPasteBuilder.representation(fromMarkdown: output)
        guard let selectionTarget, let selectedTextService else {
            // Nothing to paste into: publish the rendered text transiently and
            // say so, rather than dropping the answer.
            pasteboard.writeTransientString(representation.plainText)
            markJustCopied()
            errorMessage = "Open Quick Launch from the app where you want to paste. The result was copied instead."
            requestInputFocus()
            return false
        }
        guard representation.prefersRichPaste else {
            // No structure to preserve: the plain path is the honest one.
            let outcome = await selectedTextService.pasteOutcome(representation.plainText, to: selectionTarget)
            if outcome == .clipboardChanged {
                errorMessage = Self.clipboardChangedMessage
                recoverFromExternalActionFailure?()
                requestInputFocus()
                return false
            }
            guard outcome == .pasted else {
                pasteboard.writeTransientString(representation.plainText)
                markJustCopied()
                errorMessage = "Could not paste into \(selectionTarget.applicationName). The result was copied instead."
                recoverFromExternalActionFailure?()
                requestInputFocus()
                return false
            }
            overlayPresenter.dismissOverlay()
            return true
        }
        // The rich types are published transiently so a clipboard manager
        // skips the paste plumbing; ⌘V is the only insertion path here.
        pasteboard.writeTransientFormatted(representation)
        let outcome = await selectedTextService.pastePasteboardOutcome(to: selectionTarget)
        if outcome == .clipboardChanged {
            errorMessage = Self.clipboardChangedMessage
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        guard outcome == .pasted else {
            pasteboard.writeTransientString(representation.plainText)
            markJustCopied()
            errorMessage = "Could not paste into \(selectionTarget.applicationName). The result was copied instead."
            recoverFromExternalActionFailure?()
            requestInputFocus()
            return false
        }
        overlayPresenter.dismissOverlay()
        return true
    }

    /// Shown when a paste was skipped because the user copied something else
    /// first. The answer is not copied over their newer copy.
    static let clipboardChangedMessage =
        "Clipboard changed, so the paste was skipped. The answer is still in Quick Launch."

    /// What Return on an empty composer does with a finished answer: the
    /// Primary Action setting in the launcher; always Copy in the AI Chat
    /// window, which has no app behind it to paste into.
    var primaryAnswerAction: QuickAIPrimaryAction {
        isAIChatWindow ? .copyToClipboard : settings.quickAIPrimaryAction
    }

    /// Return with an empty composer on a finished answer runs the Quick AI
    /// primary action. Automatic copy is untouched: `autoCopy` still decides
    /// what happens the moment an answer arrives.
    func runPrimaryAnswerAction() async {
        guard !output.isEmpty, !isStreaming else { return }
        switch primaryAnswerAction {
        case .pasteToActiveApp:
            // Fails safe: it copies and explains when there is no target.
            _ = await pasteOutputToPreviousApp()
        case .copyToClipboard:
            copyAnswerOnSurface()
        }
    }
}
