import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

extension QuickViewModel {
    func requestInputFocus() {
        inputFocusRequest &+= 1
    }

    /// Whether a saved action has selected text to work on: a source a
    /// picker or hotkey stashed, an attached Screen Awareness selection, or
    /// the launch selection chip. An assistant's alias alone, its palette
    /// row, or its hotkey runs its prompt on that text instead of picking
    /// the assistant.
    var hasSelectedActionSource: Bool {
        [pendingActionSource, selectionTransformSource].contains { text in
            text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        }
    }

    func openAccessibilitySettings() {
        selectedTextService?.openAccessibilitySettings()
    }

    func captureSelectedText(promptForPermission: Bool) -> SelectedTextContext? {
        if let selectedTextContext { return selectedTextContext }
        // The user removed the chip: do not silently re-capture a selection
        // the user chose to drop, until a fresh launch or an explicit
        // attachment re-arms the selection.
        guard !selectionRecaptureSuppressed else { return nil }
        guard let selectionTarget, let selectedTextService else { return nil }
        let captured = selectedTextService.capture(
            from: selectionTarget,
            promptForPermission: promptForPermission
        )
        selectedTextContext = captured
        return captured
    }

    /// The text an action operates on, in precedence order: the explicit
    /// source stashed by a picker/hotkey dispatch, an explicitly attached
    /// Screen Awareness selection, the text typed after the alias, and only
    /// then the launch-scoped background selection snapshot. Typed or
    /// explicitly attached text always beats the auto-captured snapshot.
    private func resolvedActionSource(
        action: SavedPromptResolver.Resolution,
        launchText: String?
    ) -> String {
        if let explicit = pendingActionSource,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        if let attached = pendingContext?.selectedText,
           !attached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return attached
        }
        // Typed `/alias context` beats the launch snapshot: the user typed
        // it for this invocation, so it is the strongest intent.
        if !action.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return action.context
        }
        if let attached = attachmentTray.readyContents.last(where: { $0.isTransformTextSource })?.text,
           !attached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return attached
        }
        if let launchText, !launchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Resolution is pure: cancelling a required input must not
            // consume the source. Only preparation consumes the snapshot.
            return launchText
        }
        return action.context
    }

    /// The captured live selection a saved action may write back to: only
    /// when its text is exactly the text the action actually ran on.
    ///
    /// A typed alias context (`/alias B` with the launch selection A still
    /// captured), a clipboard source, or any other attached text yields nil,
    /// so the result copies instead of overwriting an unrelated app. This is
    /// the one binding a review, an auto `.replaceSelection`, or an offered
    /// Replace Selection action uses.
    func boundActionTarget(forSource source: String) -> SelectedTextContext? {
        guard let context = selectedTextContext, context.text == source else { return nil }
        return context
    }

    /// One Return, prepared for a provider: the prompt the model receives
    /// plus everything the stream and its rollback need.
    struct PreparedRequest {
        let submittedInput: String
        /// True when the question came from the composer, so it leaves the
        /// field as it becomes a pill; false for ⌘R, which asks a turn of
        /// the thread again and leaves whatever is typed alone.
        var takesComposerText = true
        /// True for ⌘R and Retry: a turn of the open chat asked again. It
        /// stays in that chat, with its earlier turns and images, even past
        /// the Start New Chat interval.
        var reasksTurn = false
        let submittedImages: [QuickImageAttachment]
        /// What the question carries, in the order added: a reference for
        /// each attachment (on the saved message), with what reading it gave
        /// (text, pixels) for the session store. A page read of a URL in
        /// the question joins here as a Link attachment.
        var attachments: [AttachmentContent] = []
        /// The tray chips `attachments` came from, which leave the tray when
        /// the question becomes a turn.
        var trayItemIDs: [UUID] = []
        /// Attachments whose text already rides this request's prompt (the
        /// page read's web-content section), so no block repeats it.
        var inlineAttachmentIDs: Set<UUID> = []
        let action: SavedPromptResolver.Resolution?
        let actionDefinition: SavedPrompt?
        /// The text a saved action ran on, kept for a `.reviewChanges`
        /// result card that offers it back beside the proposed text.
        var actionSource: String = ""
        /// The label of that source ("Clipboard", an app name), so a review
        /// card never attributes an attached source to the live selection.
        var actionSourceApp: String?
        /// The matching live source target frozen before any external work.
        /// Clipboard and unrelated typed sources deliberately have no target.
        var actionTarget: SelectedTextContext?
        var effectivePrompt: String
        var usedWebSearch = false
        var webSearchFallback: String?
        var usedPageRead = false
        /// Whether the open chat already showed an answer when this was
        /// asked, before a web search clears it: auto-copy then leaves the
        /// answer alone (`autoCopiesAnswer`).
        var chatShowedAnswer = false
        /// The retrieval and tool gate resolved for this request: what may
        /// be read, and which broad tools may be offered and run.
        var contextEvaluation: ChatContextEvaluation?

        var submittedImage: QuickImageAttachment? { submittedImages.last }

        /// The references the saved question keeps.
        var attachmentRefs: [ChatAttachmentRef] { attachments.map(\.ref) }
    }

    /// Return on the input. Three stages, each of which may finish the
    /// request itself: `prepareRequest` (aliases, `{selection}`, local
    /// answers), `enrich` (web search, page reading), `stream` (provider).
    func submit() async {
        // The other view may have added to, renamed, or deleted this chat.
        refreshOpenChatFromStore()
        await submit(text: nil)
    }

    /// `text` asks that question instead of the composer's (⌘R asking a
    /// turn again); the composer then keeps what is typed in it.
    func submit(text: String?, reasksTurn: Bool = false) async {
        beginTurnTelemetry()
        // A send the user started is activity from here on, even before the
        // question is durable and long before an answer exists. Bumped before
        // the first suspension so a quit that freezes in the middle of this
        // submit cannot later approve an exit over a turn it never saw.
        durability?.noteActivity()
        let preStreamToken = UUID()
        preStreamSubmitTokens.insert(preStreamToken)
        defer { preStreamSubmitTokens.remove(preStreamToken) }
        // A question asked on the surface supersedes any clear a dismissal
        // left waiting for an earlier turn (a service or archive failure can
        // end that turn before the clear runs). This turn owns the surface.
        isTransientClearDeferred = false
        // Freeze the chat's chosen route before any async work: prepare,
        // enrich, and the model call all read this, so a model change while a
        // page fetch or a search is in flight cannot move this turn.
        if let provider = activeProvider, let model = activeModelID {
            pendingModelFreeze = ChatModelFreeze.freeze(
                provider: provider,
                model: model,
                thinking: modelPreferences.profile(providerID: provider.id, model: model).reasoningEffort,
                supportsThinking: modelPreferences.profile(providerID: provider.id, model: model).supportsReasoningEffort
            )
        } else {
            pendingModelFreeze = nil
        }
        // Draft attachments belong to the next question, not to a turn
        // being retried. A retry never waits on or consumes that draft.
        if !reasksTurn, !(await waitForReadingAttachments()) { return }
        turnPrepareStartedAt = Date()
        guard var request = await prepareRequest(
            text: text,
            reasksTurn: reasksTurn,
            preStreamToken: preStreamToken
        ) else { return }
        turnPrepareFinishedAt = Date()
        // The submitted material is durable before any external network: the
        // page fetch and web search in enrich, and the model call, all come
        // after this. A write failure keeps the draft and blocks send.
        turnPersistStartedAt = Date()
        // Decide once, before any await a time-based window could cross, and
        // carry that decision through persist, enrich and stream: the archived
        // chat and the live chat must be the same chat.
        let startsNewChat = willStartNewChat(for: request)
        // Test seam: holds the exact pre-stream window (after the accept, before
        // the question write). Nil in the app, so no extra suspension.
        await beforeDurableSubmitWrite?()
        let durable = await submitDurableMaterial(request, startsNewChat: startsNewChat)
        turnPersistFinishedAt = Date()
        guard durable else { return }
        // The question is on disk now. Bump again so a quit frozen before this
        // point cannot approve the exit over a submit it never saw finish.
        durability?.noteActivity()
        turnEnrichStartedAt = Date()
        let enriched = await enrich(&request)
        turnEnrichFinishedAt = Date()
        guard enriched else {
            pendingSubmission = nil
            return
        }
        await stream(request, startsNewChat: startsNewChat, preStreamToken: preStreamToken)
    }

    /// Starts a fresh turn's measurements. Every phase timestamp is cleared, so
    /// a later turn can never inherit an earlier one's numbers.
    private func beginTurnTelemetry() {
        turnEntryAt = Date()
        turnPrepareStartedAt = nil
        turnPrepareFinishedAt = nil
        turnPersistStartedAt = nil
        turnPersistFinishedAt = nil
        turnEnrichStartedAt = nil
        turnEnrichFinishedAt = nil
        streamToolRounds = []
        streamUsage = nil
    }

    /// The timings this turn actually measured. A value that was never
    /// measured stays absent rather than being written as a plausible zero.
    func requestTimings(finishedAt: Date) -> RequestTimings {
        var timings = RequestTimings()
        if let started = streamStartedAt {
            timings.totalSeconds = finishedAt.timeIntervalSince(started)
            if let firstToken = streamFirstTokenAt {
                timings.firstTokenSeconds = firstToken.timeIntervalSince(started)
            }
            if let entry = turnEntryAt {
                timings.extra["entryToRequestSeconds"] = .number(started.timeIntervalSince(entry))
            }
        }
        if !streamToolRounds.isEmpty {
            timings.toolSeconds = streamToolRounds.compactMap(\.durationSeconds).reduce(0, +)
        }
        if let start = turnEnrichStartedAt, let end = turnEnrichFinishedAt {
            timings.retrievalSeconds = end.timeIntervalSince(start)
        }
        if let start = turnPrepareStartedAt, let end = turnPrepareFinishedAt {
            timings.extractionSeconds = end.timeIntervalSince(start)
        }
        if let start = turnPersistStartedAt, let end = turnPersistFinishedAt {
            timings.extra["persistenceSeconds"] = .number(end.timeIntervalSince(start))
        }
        // `modelRounds` is filled by the terminal write from the turn's own
        // round recorder, so it is exact for the turn that was archived.
        return timings
    }

    /// Whether this request begins a new chat. Evaluated exactly once in
    /// `submit`, before the persist and enrich awaits, and carried through, so
    /// a time-based window that crosses during them cannot move the turn to a
    /// chat other than the one whose id was reserved.
    func willStartNewChat(for request: PreparedRequest) -> Bool {
        !request.reasksTurn && (shouldStartNewConversation
            || (request.action != nil && (isFollowUp || currentConversation?.assistantID != nil)))
    }

    /// The durable submission of the question and its bytes, before any
    /// external network. The archived turn and the live turn share ids, so a
    /// later commit merges rather than duplicates. False means the write
    /// failed and no provider may be called.
    func submitDurableMaterial(_ request: PreparedRequest, startsNewChat: Bool) async -> Bool {
        guard let chatArchive else { return true }
        let startsNew = startsNewChat
        let conversationID = startsNew ? UUID() : (currentConversation?.id ?? UUID())
        let messageID = UUID()
        var provisional: QuickConversation
        if !startsNew, let current = currentConversation {
            provisional = current
        } else {
            provisional = QuickConversation(
                id: conversationID,
                providerID: activeProvider?.id ?? currentConversation?.providerID ?? UUID(),
                model: activeModelID ?? currentConversation?.model ?? ""
            )
        }
        provisional.messages.append(QuickMessage(
            id: messageID,
            role: .user,
            content: request.effectivePrompt,
            attachments: request.attachmentRefs.isEmpty ? nil : request.attachmentRefs
        ))
        let tools = Array(request.contextEvaluation?.gatedTools ?? chatTools)
        do {
            _ = try await chatArchive.submit(TurnSubmission(
                conversation: provisional,
                attachmentContents: request.attachments,
                model: pendingModelFreeze?.selection,
                tools: tools,
                requestSnapshot: nil,
                endpoint: pendingModelFreeze?.endpoint,
                startedAt: Date()
            ))
            pendingSubmission = PendingSubmission(
                conversationID: conversationID,
                messageID: messageID,
                attachments: request.attachments,
                startedAt: Date()
            )
            return true
        } catch {
            pendingSubmission = nil
            errorMessage = "Could not save this question: \(error.localizedDescription). Nothing was sent."
            recordJournal(kind: .aiFailed, scope: learningScope, detail: "archive-write-failed")
            requestInputFocus()
            return false
        }
    }

    /// Resolves saved-prompt aliases, runs command actions, expands
    /// `{selection}`, and answers locally (math, conversions, facts). Returns
    /// `nil` when the request was handled here or could not proceed.
    func prepareRequest(
        text: String? = nil,
        reasksTurn: Bool = false,
        preStreamToken: UUID? = nil
    ) async -> PreparedRequest? {
        let takesComposerText = text == nil
        var submittedInput = text ?? input
        /// Set when the draft named a skill, so the thread can say so
        /// after the per-request notices are reset further down.
        var skillInUse: String?
        // A skill asked for by name: its own text goes in front of the
        // question, and the command itself never reaches the model. The name
        // must be a folder in `~/.claude/skills` that holds a `SKILL.md`, so
        // a typo still falls through to the unknown-command refusal below.
        // The skill text is capped by `SkillLibrary.maxCharacters`.
        if !reasksTurn, !sendAsTextOnce,
           let skill = slashSkillName(in: submittedInput),
           let skillText = skillLibrary?.read(skill) {
            let question = submittedInput
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .dropFirst(skill.count + 1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            submittedInput = question.isEmpty
                ? skillText
                : skillText + "\n\n" + question
            skillInUse = skill
        }
        if !reasksTurn, submittedInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           pendingContext != nil || launchSelection != nil {
            errorMessage = "Ask a question about the attached context."
            requestInputFocus()
            return nil
        }
        // Built-in slash commands precede any saved-prompt alias: a prompt
        // can never shadow /new or /clear, and an unknown slash line is
        // handled locally instead of being sent to a model as prompt text.
        // Ordinary Return keeps showing the local error; only the explicit
        // Send as Text action (`sendAsTextOnce`) bypasses this.
        if !reasksTurn, !sendAsTextOnce,
           let outcome = quickCommandOutcome(for: submittedInput) {
            switch outcome {
            case .newChat:
                performNewChatCommand()
                return nil
            case .clearChat:
                performClearChatCommand()
                return nil
            case .unknownCommand(_, let message):
                refusedCommandText = submittedInput
                errorMessage = message
                requestInputFocus()
                return nil
            case .appCommand, .notACommand:
                break
            }
        }
        sendAsTextOnce = false
        refusedCommandText = nil
        // A turn asked again keeps its attachments; a new question takes
        // the screenshots and the chips that were read.
        let attachments: [AttachmentContent] = reasksTurn
            ? (reaskedAttachments ?? []).map { AttachmentContent(ref: $0) }
            : pendingAttachmentContents()
        let trayItemIDs = reasksTurn ? [] : attachmentTray.items.filter { $0.content != nil }.map(\.id)
        // Resolve the saved-prompt alias first: a plain transform marked
        // text-only offers the model no tools. That tool set then feeds the
        // one context gate, so the receipt and the request agree.
        let action = SavedPromptResolver.resolveAction(
            input: submittedInput,
            prefix: settings.savedPromptPrefix,
            savedPrompts: settings.savedPrompts
        )
        let actionDefinition = action.flatMap { resolution in
            settings.savedPrompts.first(where: { $0.id == resolution.actionID })
        }
        let isTextOnlyAction = actionDefinition?.textOnly == true
        // Resolve the retrieval and tool gate once, before any branch that
        // might send. Both `enrich` and `stream` read this same evaluation.
        let contextEvaluation = ChatContextGate.standard.evaluate(
            enabledTools: isTextOnlyAction ? [] : chatTools,
            hasCurrentSource: !attachments.isEmpty,
            currentSourceCount: attachments.count,
            historyTurnCount: currentConversation?.messages.count ?? 0,
            historyHasSources: (currentConversation?.messages ?? []).contains { !$0.attachmentRefs.isEmpty },
            question: submittedInput,
            override: contextOverride
        )
        guard !submittedInput.isEmpty || pendingImage != nil || !attachments.isEmpty else { return nil }
        // A new request supersedes any prior answer's replaceable selection
        // and any review card left up by an earlier transform.
        replaceableSelectionContext = nil
        pendingTransformReview = nil
        webSearchNote = nil
        liveToolRecords = []
        threadNotice = nil
        // The thread says which skill ran, so an answer shaped by up to
        // twelve thousand characters of guidance is never unexplained.
        // Set after the reset above, which clears the last turn's notice.
        if let skillInUse { threadNotice = "Using the \(skillInUse) skill" }
        // The pictures this turn carries. The thread's earlier pictures ride
        // their own turns, from the session store (`turnImages`), and a turn
        // asked again finds its own there by reference.
        let submittedImages = attachments.compactMap(\.image)
        let submittedImage = submittedImages.last
        let hasDocuments = attachments.contains { !$0.ref.kind.isImage }

        if reasksTurn {
            // The saved question already contains its original selection
            // and action expansion. Reusing the draft's context here would
            // attach unrelated text to the old question and erase its chip.
            return PreparedRequest(
                submittedInput: submittedInput,
                takesComposerText: false,
                reasksTurn: true,
                submittedImages: submittedImages,
                attachments: attachments,
                action: action,
                actionDefinition: action.flatMap { resolution in
                    settings.savedPrompts.first { $0.id == resolution.actionID }
                },
                effectivePrompt: submittedInput,
                chatShowedAnswer: chatShowsAnswer,
                contextEvaluation: contextEvaluation
            )
        }

        // An assistant's alias alone, with nothing selected, picks the
        // assistant for the chat and sends nothing. With text after it, or
        // with selected text, the alias is a transform like any other saved
        // prompt, below.
        if !hasSelectedActionSource, let assistant = SavedPromptResolver.assistant(
            input: submittedInput,
            prefix: settings.savedPromptPrefix,
            savedPrompts: settings.savedPrompts
        ) {
            noteActedQuery(submittedInput)
            input = ""
            selectAssistant(assistant)
            return nil
        }

        // The launch-scoped selection is a single-use snapshot captured before
        // the overlay took focus. Read it once so every branch below uses the
        // same immutable text, and clear it once a model-bound request is
        // built so it never leaks into a later follow-up or a new chat.
        let launchText = launchSelection?.text

        // Every action entry uses this gate, including a typed alias and a
        // saved-action hotkey. Missing inputs never become an empty request.
        if let action, let definition = actionDefinition,
           pendingActionArguments == nil,
           SavedPromptResolver.argumentSlots(in: definition.prompt).contains(where: {
               $0.defaultValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }) {
            let source = resolvedActionSource(action: action, launchText: launchText)
            await beginTransformArguments(
                action: definition,
                source: source,
                sourceLabel: pendingActionSourceLabel
                    ?? (action.context.isEmpty ? selectionTransformSourceLabel : "Typed text")
            )
            return nil
        }

        // Command actions run a local executable directly and never reach a
        // model provider.
        if let action,
           let definition = settings.savedPrompts.first(where: { $0.id == action.actionID }),
           let executable = definition.commandExecutable,
           !executable.isEmpty {
            let source = resolvedActionSource(action: action, launchText: launchText)
            let sourceLabel = pendingActionSourceLabel
                ?? (action.context.isEmpty ? selectionTransformSourceLabel : "Typed text")
            let target = sourceLabel == ClipboardHistoryAttachments.clipboardAppName
                ? nil : boundActionTarget(forSource: source)
            pendingActionSource = nil
            pendingActionSourceLabel = nil
            pendingActionArguments = nil
            // A dispatched command consumed the launch snapshot (whether the
            // source came via pendingActionSource or the launchText branch):
            // clear the chip so it cannot ride a later request.
            if launchSelection != nil { launchSelection = nil }
            // The command lane writes no archive answer and is stopped by
            // `cancel()` like any stream, so it is not unowned pre-stream work.
            // It retires only its own submit's claim.
            if let preStreamToken { preStreamSubmitTokens.remove(preStreamToken) }
            await runCommandAction(
                definition: definition,
                executable: executable,
                context: source,
                sourceTarget: target,
                submittedInput: submittedInput,
                takesComposerText: takesComposerText
            )
            return nil
        }

        var effectivePrompt: String
        var actionSourceText = ""
        var actionSourceLabel: String?
        var actionTarget: SelectedTextContext?
        if let action,
           let definition = settings.savedPrompts.first(where: { $0.id == action.actionID }) {
            var source = resolvedActionSource(action: action, launchText: launchText)
            // Inspect template syntax, never braces occurring in source data.
            if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               definition.prompt.contains("{selection}") {
                guard let selected = captureSelectedText(promptForPermission: true) else {
                    errorMessage = selectedTextService?.isAccessibilityTrusted == false
                        ? "Allow Accessibility in System Settings, then select text and try again."
                        : "This action needs selected text."
                    requestInputFocus()
                    return nil
                }
                source = selected.text
            }
            actionSourceText = source
            actionSourceLabel = pendingActionSourceLabel
                ?? (action.context.isEmpty ? selectionTransformSourceLabel : "Typed text")
            actionTarget = actionSourceLabel == ClipboardHistoryAttachments.clipboardAppName
                ? nil : boundActionTarget(forSource: source)
            pendingActionSource = nil
            pendingActionSourceLabel = nil
            // Consume the single-use chip once a saved action uses the
            // selection (perform() may have stashed the snapshot in
            // pendingActionSource, which the resolver returns unchanged).
            if launchSelection != nil { launchSelection = nil }
            // Explicit Screen Awareness context is honored for saved actions
            // too: the window/app/page preamble is prepended, minus the
            // selection (which the action carries via `{selection}` or the
            // appended source) so it is not sent twice.
            var preambleParts: [String] = []
            if let submittedContext = pendingContext {
                let preamble = submittedContext.promptPreamble(includeSelectedText: false)
                if !preamble.isEmpty { preambleParts.append(preamble) }
            }
            // The `{argument}` values collected for this invocation, consumed
            // once. `{clipboard}` is read only when the template asks for it,
            // and only now that the user chose the action.
            let argumentValues = pendingActionArguments
                ?? SavedPromptResolver.argumentSlots(in: definition.prompt).map(\.defaultValue)
            pendingActionArguments = nil
            let clipboardText = SavedPromptResolver.readsClipboard(definition.prompt)
                ? pasteboard.readString()
                : nil
            // Keep `{selection}` intact when no source is supplied, so the
            // branch below can capture it fresh instead of blanking it; the
            // shared engine leaves `{selection}` literal while filling
            // `{argument …}` and `{clipboard}`.
            effectivePrompt = source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (SnippetPlaceholders.containsPlaceholders(definition.prompt)
                    ? SnippetPlaceholders.expand(
                        definition.prompt,
                        clipboard: clipboardText,
                        arguments: argumentValues
                    ).text
                    : definition.prompt)
                : SavedPromptResolver.prompt(
                    for: definition,
                    source: source,
                    arguments: argumentValues,
                    clipboard: clipboardText
                )
            let preamble = preambleParts.joined(separator: "\n\n")
            if !preamble.isEmpty {
                effectivePrompt = preamble + "\n\n" + effectivePrompt
            }
        } else {
            effectivePrompt = plainPrompt(
                submittedInput,
                hasImage: submittedImage != nil,
                hasDocuments: hasDocuments,
                launchText: launchText
            )
        }

        // Math, conversions, dates, system facts: the same deterministic
        // resolver the live ranking uses, so Return and the inline row agree.
        // Unit conversions only apply to raw typed input, never to an
        // expanded saved prompt.
        if attachments.isEmpty, answerLocally(
            prompt: effectivePrompt,
            question: submittedInput,
            allowConversions: action == nil,
            takesComposerText: takesComposerText
        ) {
            return nil
        }

        // The launch-scoped background selection rides with exactly one model
        // request; consume it here so it never leaks into a later follow-up
        // or a brand-new conversation. Local answers return above and keep it.
        if launchSelection != nil { launchSelection = nil }

        return PreparedRequest(
            submittedInput: submittedInput,
            takesComposerText: takesComposerText,
            reasksTurn: reasksTurn,
            submittedImages: submittedImages,
            attachments: attachments,
            trayItemIDs: trayItemIDs,
            action: action,
            actionDefinition: actionDefinition,
            actionSource: actionSourceText,
            actionSourceApp: actionSourceLabel,
            actionTarget: actionTarget,
            effectivePrompt: effectivePrompt,
            chatShowedAnswer: chatShowsAnswer,
            contextEvaluation: contextEvaluation
        )
    }

    /// What the model gets for typed text that names no saved prompt: the
    /// text (or, for a bare attachment, a stock question), after any Add
    /// Context and launch-selection preamble.
    private func plainPrompt(
        _ text: String,
        hasImage: Bool,
        hasDocuments: Bool = false,
        launchText: String?
    ) -> String {
        var prompt = text
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if hasDocuments {
                prompt = AttachmentRequestComposer.bareAttachmentQuestion
            } else if hasImage {
                prompt = "Describe this screenshot and answer the most likely useful question about it."
            }
        }
        // Screen Awareness context plus the launch-scoped background
        // selection become context for this question.
        var preambleParts: [String] = []
        if let submittedContext = pendingContext {
            let preamble = submittedContext.promptPreamble()
            if !preamble.isEmpty { preambleParts.append(preamble) }
        }
        if let launchText, !launchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           pendingContext?.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
                != launchText.trimmingCharacters(in: .whitespacesAndNewlines) {
            var context = CaptureContext(
                appName: launchSelection?.appName ?? "the background"
            )
            context.selectedText = launchText
            let preamble = context.promptPreamble()
            if !preamble.isEmpty { preambleParts.append(preamble) }
        }
        let preamble = preambleParts.joined(separator: "\n\n")
        return preamble.isEmpty ? prompt : preamble + "\n\nQuestion: " + prompt
    }

    /// The local lane: math, conversions, dates, and system facts, which
    /// never reach a model. Asked from root search (the field, Tab, or the
    /// Ask AI row), the answer shows inline under its question
    /// (`rootAnswer`), as v1.3.0 drew it and as Raycast's calculator does,
    /// and Quick AI never opens. Asked from the Quick AI composer, it stays
    /// on the surface as its own answer under its own pill ("Local answer"
    /// in the header), like a command's output: never a turn of the chat.
    /// Math that cannot be computed (1/0) is reported, not handed to a
    /// model. Returns true when the lane took the question.
    private func answerLocally(
        prompt: String,
        question: String,
        allowConversions: Bool,
        takesComposerText: Bool
    ) -> Bool {
        if MathExpressionDetector.isMathExpression(prompt),
           (try? MathCalculator.evaluate(prompt)) == nil {
            do {
                _ = try MathCalculator.evaluate(prompt)
            } catch {
                errorMessage = "Math error: \(error)"
            }
            requestInputFocus()
            return true
        }
        guard let result = localAnswer(for: prompt, allowConversions: allowConversions) else { return false }
        errorMessage = nil
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if isQuickAIPresented {
            // Asked in a chat: the reader stays in it. The question is its
            // own pill and the answer draws under it, after the thread.
            let chatHadAnswer = chatShowsAnswer
            lastQuestion = trimmedQuestion
            pendingQuestion = trimmedQuestion
            answerSource = .local
            threadError = nil
            webSearchNote = nil
            output = result
            if takesComposerText { input = "" }
            followThreadBottom()
            if autoCopiesAnswer(chatHadAnswer: chatHadAnswer) {
                pasteboard.writeTransientString(result)
                markJustCopied()
            }
            requestInputFocus()
            return true
        }
        isQuickAIPresented = false
        isRecentChatsPresented = false
        rootAnswer = RootAnswer(question: trimmedQuestion, answer: result)
        if takesComposerText { input = "" }
        applicationSelectionIndex = 0
        // A root answer is a one-off, never a follow-up.
        if autoCopiesAnswer(chatHadAnswer: false) {
            pasteboard.writeTransientString(result)
            markJustCopied()
        }
        requestInputFocus()
        return true
    }

    /// Tab and the Ask AI row on typed text: when it is a local answer, show
    /// it in root search and do not open Quick AI. The same rule
    /// `prepareRequest` applies, decided before the surface opens so it
    /// never opens for math.
    func answerTypedTextLocally() -> Bool {
        let text = input
        guard let prompt = localAnswerPrompt(for: text) else { return false }
        return answerLocally(prompt: prompt, question: text, allowConversions: true, takesComposerText: true)
    }

    /// The prompt `answerTypedTextLocally` checks for a local answer, or nil
    /// when the text must go on (empty, an image attached, a saved prompt).
    private func localAnswerPrompt(for text: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pendingImage == nil,
              attachmentTray.isEmpty,
              SavedPromptResolver.resolveAction(
                  input: text,
                  prefix: settings.savedPromptPrefix,
                  savedPrompts: settings.savedPrompts
              ) == nil
        else { return nil }
        return plainPrompt(text, hasImage: false, launchText: launchSelection?.text)
    }

    /// Whether Tab and the Ask AI row answer this text locally instead of
    /// opening Quick AI: the same rule, so the row never promises the model
    /// for math.
    func typedTextHasLocalAnswer(_ text: String) -> Bool {
        guard let prompt = localAnswerPrompt(for: text) else { return false }
        return localAnswer(for: prompt, allowConversions: true) != nil
    }

    /// Run a command-lane saved action: execute the configured binary with
    /// `{input}` substituted per argv element (no shell), then route stdout
    /// through the action's `outputBehavior`. A non-zero exit surfaces the
    /// command's stderr as the error and produces no result text.
    private func runCommandAction(
        definition: SavedPrompt,
        executable: String,
        context: String,
        sourceTarget: SelectedTextContext?,
        submittedInput: String,
        takesComposerText: Bool
    ) async {
        let chatHadAnswer = chatShowsAnswer
        errorMessage = nil
        output = ""
        if takesComposerText { input = "" }
        // Not a turn of the chat and not the model: the typed alias is its
        // own pill, and the header names the command.
        let question = submittedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuestion = question
        pendingQuestion = question
        answerSource = .command(definition.name)
        threadError = nil
        webSearchNote = nil
        streamingStatus = "Running \(definition.name)…"
        followThreadBottom()
        isStreaming = true
        // The user submitted this alias, whatever the command does next: a
        // failure or a cancellation must not read as an abandoned search.
        noteActedQuery(submittedInput)
        // Retained so Escape can terminate the process instead of only hiding
        // its output; `ProcessRunner` terminates the child when its task is
        // cancelled and rethrows `CancellationError`.
        let task = Task {
            try await CommandActionRunner.run(
                executable: executable,
                arguments: definition.commandArguments ?? [],
                input: context
            )
        }
        commandTask = task
        defer { if commandTask == task { commandTask = nil } }
        do {
            let result = try await task.value
            streamingStatus = nil
            isStreaming = false
            output = result
            noteFeatureUse(.savedActionRun, itemID: "action:\(definition.id.uuidString)")
            recordJournal(kind: .actionSucceeded, scope: learningScope, detail: "command")
            var didAutoWrite = false
            if definition.outputBehavior == .reviewChanges, !output.isEmpty {
                if !isAIChatWindow { openQuickAI() }
                pendingTransformReview = PendingTransformReview(
                    original: context,
                    proposed: output,
                    sourceApp: sourceTarget?.target.applicationName,
                    target: sourceTarget
                )
                didAutoWrite = true
            } else if definition.outputBehavior == .replaceSelection,
               !output.isEmpty {
                didAutoWrite = true
                // The command ran on `context`; only write back when that text
                // is the captured live selection, never a typed alias tail.
                if let selectedTextService, let target = sourceTarget {
                    _ = await writeBackValidated(
                        output: output,
                        in: target,
                        service: selectedTextService
                    )
                } else {
                    copyOutput()
                    markJustCopied()
                    errorMessage = "Could not replace the selection. The result was copied instead."
                }
            } else if autoCopiesAnswer(chatHadAnswer: chatHadAnswer), !output.isEmpty {
                copyOutput()
                markJustCopied()
            }
            if !didAutoWrite, let selectionContext = sourceTarget {
                replaceableSelectionContext = selectionContext
            }
            requestInputFocus()
            await sendQueuedFollowUp()
            return
        } catch is CancellationError {
            // The process was actually terminated: `ProcessRunner` rethrows
            // `CancellationError` only after its cancellation handler ran. No
            // late output can reappear, because the result is never assigned.
            streamingStatus = nil
            isStreaming = false
            output = ""
            // The typed alias comes back, unless a follow-up was typed since.
            if takesComposerText, input.isEmpty { input = submittedInput }
            pendingQuestion = nil
            recordJournal(kind: .actionCancelled, scope: learningScope, detail: "command")
        } catch {
            streamingStatus = nil
            isStreaming = false
            output = ""
            if takesComposerText, input.isEmpty { input = submittedInput }
            pendingQuestion = nil
            errorMessage = error.localizedDescription
            recordJournal(kind: .actionFailed, scope: learningScope, detail: "command-error")
        }
        isFollowUpQueued = false
        requestInputFocus()
    }
}
