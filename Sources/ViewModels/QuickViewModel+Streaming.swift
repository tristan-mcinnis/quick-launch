import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

extension QuickViewModel {
    /// Picks the provider and model, records the turn in the conversation,
    /// and streams the answer into `output`.
    func stream(
        _ request: PreparedRequest,
        startsNewChat: Bool,
        preStreamToken: UUID? = nil
    ) async {
        let submittedInput = request.submittedInput
        // The user submitted this text, whatever happens next: a failure or a
        // cancellation must not later read as an abandoned search.
        noteActedQuery(submittedInput)
        let submittedImages = request.submittedImages
        let action = request.action
        let actionDefinition = request.actionDefinition
        let effectivePrompt = request.effectivePrompt
        let usedWebSearch = request.usedWebSearch
        let usedPageRead = request.usedPageRead
        // A saved-prompt transform (`/alias text`) runs in a plain chat of
        // its own: after an answer, and in an assistant chat, it starts one.
        // ⌘R asks a turn of this chat again: it stays in this chat whatever
        // the Start New Chat interval says, and the composer keeps its text.
        // `startsNewChat` was frozen once at submit, before the persist and
        // enrich awaits, and is carried in: it is never re-derived here.
        // Auto-copy takes a chat's first answer only: in a chat that already
        // showed one, this answer is a follow-up.
        let chatHadAnswer = !startsNewChat && request.chatShowedAnswer
        // A question runs as the open chat's assistant, the one the header
        // names. When the new-chat interval moves it to a fresh chat, the
        // assistant goes along. A transform never runs as an assistant.
        let requestAssistant = action == nil ? activeAssistant : nil
        let newChatID = pendingSubmission?.conversationID ?? UUID()
        // The assistant's instructions and context skills, the skill files
        // read once per chat.
        var assistantSystem: String?
        if let requestAssistant {
            assistantSystem = await assistantSystemMessage(
                requestAssistant,
                conversationID: startsNewChat ? newChatID : (currentConversation?.id ?? newChatID)
            )
        }
        guard !Task.isCancelled else {
            restoreEnrichmentInput()
            return
        }

        // One resolver decides the route for this turn, the same one the
        // pre-Send label reads. Pictures on this turn, a turn asked again
        // with its own, or the thread's earlier ones still in memory all go
        // through it; a picture with no usable image route is refused, not
        // silently read by OCR.
        var attachments = request.attachments
        let threadImages = startsNewChat ? [] : (currentConversation?.messages ?? [])
            .flatMap(\.attachmentRefs)
            .compactMap { attachmentStore.storedImage(for: $0) }
        let reaskedImages = attachments.compactMap { attachmentStore.storedImage(for: $0.ref) }
        let candidateImage = submittedImages.last ?? reaskedImages.last ?? threadImages.last
        let route = resolveChatRoute(
            hasImages: candidateImage != nil,
            hasNewImages: !submittedImages.isEmpty,
            actionProviderID: usedWebSearch ? nil : action?.providerID,
            actionModel: action?.model
        )
        var visionImage = candidateImage
        switch route.imageMode {
        case .inline:
            break
        case .textOnly:
            // The images stay on this Mac and only their text reaches the
            // model. Labelled, never silent.
            visionImage = nil
            attachments = await readImagesAsText(attachments)
            guard !Task.isCancelled else {
                restoreEnrichmentInput()
                return
            }
        case .none:
            visionImage = nil
        }
        if let warning = route.warning {
            restoreEnrichmentInput()
            errorMessage = warning
            recordJournal(
                kind: .aiFailed,
                scope: learningScope,
                detail: visionImage != nil || candidateImage != nil ? "missing-vision-route" : "missing-route"
            )
            requestInputFocus()
            return
        }
        let routesToVision = visionImage != nil
        let provider = route.effective.provider
        let model = route.effective.model

        // The tools chosen for the open chat carry into a chat this question
        // starts on its own (the new-chat interval, a saved-prompt follow-up).
        // An assistant's tools stay with the assistant: a transform that
        // leaves an assistant chat starts from the defaults.
        let carriedTools = requestAssistant == nil && activeAssistant != nil
            ? pendingChatTools
            : currentConversation?.enabledTools ?? pendingChatTools
        // Freeze the route for this turn: a later model change, provider
        // edit, or vision fallback cannot rewrite what this turn used.
        // `chosen` is the chat's route frozen at submit; `effective` is what
        // actually ran, so a vision fallback is labelled, never hidden. The
        // thinking recorded here is the same value the request body carries.
        let effectiveModel = ChatModelFreeze.freeze(
            provider: provider,
            model: model,
            thinking: route.thinking,
            supportsThinking: route.thinkingSupported
        )
        let frozenModel = pendingModelFreeze ?? effectiveModel
        let turnSelection = ModelSelection(chosen: frozenModel.choice, effective: effectiveModel.choice)
        pendingModelFreeze = nil
        if startsNewChat {
            // This reset runs inside the submit task; cancelling the submit
            // handles here would cancel this very turn.
            startNewConversation(cancelingSubmitTasks: false)
        }
        if currentConversation == nil {
            currentConversation = QuickConversation(
                id: newChatID,
                providerID: provider.id,
                model: model,
                enabledTools: carriedTools ?? requestAssistant?.enabledTools,
                assistantID: requestAssistant?.id
            )
            pendingChatTools = nil
            pendingModelChoice = nil
        }
        currentConversation?.providerID = provider.id
        currentConversation?.model = model
        // The saved question keeps references only; the text and pictures
        // live in the session store, in memory.
        for content in attachments { attachmentStore.store(content) }
        let submittedMessage = QuickMessage(
            id: pendingSubmission?.messageID ?? UUID(),
            role: .user,
            content: usedWebSearch || usedPageRead ? submittedInput : effectivePrompt,
            attachments: attachments.isEmpty ? nil : attachments.map(\.ref)
        )
        // The title comes from what the user typed, not from the expanded
        // saved prompt or the Add Context preamble the model receives. Set
        // on the first question; a first question that rolled back leaves
        // no user turn, so the next one replaces it.
        if currentConversation?.messages.contains(where: { $0.role == .user }) == false {
            currentConversation?.titleSource = submittedInput
        }
        currentConversation?.messages.append(submittedMessage)
        currentConversation?.updatedAt = Date()
        // The durable submission already happened before `enrich`; the ids
        // reserved there are the ids used here, so the archived turn and the
        // live turn are one. Capture the submission's clock before the handle
        // is cleared: both the archive write and the stream timer read it.
        let submissionStartedAt = pendingSubmission?.startedAt
        pendingSubmission = nil
        // A question left without an answer (stopped before any text, or a
        // provider error) stays in the thread, but the model gets the chat
        // as alternating turns: an unanswered question is left out.
        var requestMessages = Self.answeredTurns(currentConversation?.messages ?? [
            QuickMessage(role: .user, content: effectivePrompt)
        ])
        if (usedWebSearch || usedPageRead), !requestMessages.isEmpty {
            requestMessages[requestMessages.count - 1].content = effectivePrompt
        }
        // Enforce the retrieval decision on this request copy: an
        // out-of-scope turn's attachment blocks are dropped, so a source-first
        // question never silently reads a whole history of files. The saved
        // chat keeps every reference.
        requestMessages = ChatContextPipeline.scopedMessages(
            requestMessages,
            execution: request.contextEvaluation?.execution
        )
        // Each turn's attachments in front of its question, fitted into
        // their share of the answering model's window first.
        if !routesToVision {
            await cacheImageText(for: requestMessages.flatMap(\.attachmentRefs))
            guard !Task.isCancelled else {
                restoreEnrichmentInput()
                return
            }
        }
        let availableImageIDs = routesToVision ? Set(requestMessages.flatMap(\.attachmentRefs)
            .filter { attachmentStore.storedImage(for: $0) != nil }.map(\.id)) : []
        let attachmentBudget = attachmentContextBudget(provider: provider, model: model)
        // The reserve is the instruction this surface actually sends: the
        // grounding sentence and the assistant's message count in full, with
        // their separators, or the share is measured against a prompt that is
        // not on the wire. `makeService` composes the provider body from the
        // same function. This path inserts at most one system message, the
        // assistant's, and the wire joins every system message it is handed;
        // a second one would have to be counted here as well.
        let instruction = systemInstruction(
            for: provider,
            grounded: request.contextEvaluation?.grounded == true,
            assistantInstruction: assistantSystem
        )
        let share = AttachmentRequestComposer.share(
            characterLimit: attachmentBudget.characterLimit,
            reserved: (requestMessages.last?.content.utf8.count ?? 0) + instruction.utf8.count
        )
        // Passage selection: a document-backed source contributes cited
        // chunks (or an honest no-match/partial line) inside the per-file,
        // per-request, and model budgets, rather than its whole text.
        let pipelineContents = requestMessages
            .flatMap(\.attachmentRefs)
            .compactMap { ref -> AttachmentContent? in
                guard let stored = attachmentStore.text(for: ref),
                      let document = stored.extractedDocument else { return nil }
                return AttachmentContent(ref: ref, text: stored.text, extractedDocument: document)
            }
        let documentBlocks = ChatContextPipeline.blocks(
            contents: pipelineContents,
            question: effectivePrompt,
            budget: ChatContextPipeline.documentBudget(
                modelShare: share,
                attachmentCount: max(1, pipelineContents.count)
            )
        )
        let composed = AttachmentRequestComposer.compose(
            messages: requestMessages,
            text: { [attachmentStore] ref in attachmentStore.text(for: ref) },
            share: share,
            excluded: request.inlineAttachmentIDs,
            availableImages: availableImageIDs,
            documentBlocks: documentBlocks
        )
        requestMessages = composed.messages
        let requestImages = routesToVision ? turnImages(for: requestMessages) : [:]
        if let summary = composed.trim.summary {
            noteLiveToolRecord(ChatToolRecord(kind: .context, summary: summary))
        }
        // The system message rides this request only; the saved chat keeps
        // the turns, and the assistant is looked up again next time.
        if let assistantSystem {
            requestMessages.insert(QuickMessage(role: .system, content: assistantSystem), at: 0)
        }
        if request.takesComposerText { input = "" }
        // The question is a turn now; a stream failure keeps it there.
        enrichmentSubmittedInput = nil
        let sentPendingImages = pendingImages
        if !request.reasksTurn {
            pendingImages.removeAll()
            pendingContext = nil
        }
        // The chips that rode leave the tray (and so does a failed one); a
        // chip added while a search ran stays for the next question.
        var takenChips = AttachmentTray.Handoff()
        if !request.reasksTurn {
            takenChips = attachmentTray.handOff()
            let sent = Set(request.trayItemIDs)
            let waiting = takenChips.items.filter { !sent.contains($0.id) && !$0.isFailed }
            if !waiting.isEmpty {
                attachmentTray.adopt(AttachmentTray.Handoff(items: waiting, reads: takenChips.reads))
            }
        }
        lastQuestion = submittedInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // The question is a turn of the thread now; the thread draws it.
        pendingQuestion = nil

        errorMessage = nil
        threadError = nil
        answerSource = .model
        output = ""
        // A new question brings the reader back to the newest text.
        followThreadBottom()
        // The model request is about to start: from here the stream is owned
        // by `streamTask`, so a quit stops it like any other stream. Only this
        // submit's claim retires.
        if let preStreamToken { preStreamSubmitTokens.remove(preStreamToken) }
        durability?.noteActivity()
        isStreaming = true
        // The send path's per-round snapshot writer. Round 0's body is the
        // submission's own snapshot; every later tool round's exact body is
        // written through it before that round's network call.
        let roundRecorder = chatArchive.map { ChatRoundRecorder(archive: $0) }
        guard let service = makeService(
            provider: provider,
            model: model,
            toolOverride: request.contextEvaluation?.gatedTools,
            textOnly: request.actionDefinition?.textOnly == true,
            grounded: request.contextEvaluation?.grounded == true,
            attachmentTrim: composed.trim,
            roundRecorder: roundRecorder
        ) else {
            isStreaming = false
            liveToolRecords = []
            // Only a question that came from the composer goes back there,
            // with its attachments; ⌘R leaves what is typed alone.
            rollbackSubmission(
                messageID: submittedMessage.id,
                restoring: request.takesComposerText ? submittedInput : nil
            )
            if request.takesComposerText {
                pendingImages = sentPendingImages
                // Back on the tray; a chip still waiting there is kept as is.
                attachmentTray.adopt(takenChips)
            }
            errorMessage = "\(provider.name) is not available. Check its model, endpoint, or installed command."
            recordJournal(kind: .aiFailed, scope: learningScope, detail: "service-unavailable")
            isFollowUpQueued = false
            requestInputFocus()
            return
        }
        // The request really starts from here, so this is a run.
        if let action = request.action {
            noteFeatureUse(.savedActionRun, itemID: "action:\(action.actionID.uuidString)")
        }

        // One model request at a time: a request still live is stopped here,
        // and text it buffered but never drew is dropped, so none of it
        // lands in this answer.
        streamTask?.cancel()
        streamTask = nil
        discardStreamBuffer()
        // The exact body this turn sends is archived before inference, with
        // no credentials: the app's request snapshot, committed through the
        // coordinator's lock. A failure blocks the provider.
        let contextReceipt = request.contextEvaluation.map {
            ChatContextGate.standard.receipt(for: $0, budgetCharacters: share)
        }
        // The exact provider body (or an explicit command-line input label),
        // built by the same request builder the service sends with. The API
        // key travels in a header this snapshot never includes.
        let requestSnapshot = Self.requestSnapshotData(
            service: service,
            model: model,
            messages: requestMessages,
            turnImages: requestImages
        )
        if let chatArchive, let conversation = currentConversation {
            do {
                _ = try await chatArchive.submit(TurnSubmission(
                    conversation: conversation,
                    attachmentContents: attachments,
                    model: turnSelection,
                    context: contextReceipt,
                    tools: Array(request.contextEvaluation?.gatedTools ?? []),
                    requestSnapshot: requestSnapshot,
                    requestSnapshotKind: "requestSansKey",
                    endpoint: frozenModel.endpoint,
                    startedAt: submissionStartedAt ?? Date()
                ))
                // The round hook writes against the turn that submission just
                // created, so it is attached before the stream can run.
                await roundRecorder?.attach(
                    conversationID: conversation.id.uuidString,
                    turnID: submittedMessage.id.uuidString
                )
            } catch {
                isStreaming = false
                liveToolRecords = []
                rollbackSubmission(
                    messageID: submittedMessage.id,
                    restoring: request.takesComposerText ? submittedInput : nil
                )
                if request.takesComposerText {
                    pendingImages = sentPendingImages
                    attachmentTray.adopt(takenChips)
                }
                errorMessage = "Could not save this question: \(error.localizedDescription). Nothing was sent."
                recordJournal(kind: .aiFailed, scope: learningScope, detail: "archive-write-failed")
                isFollowUpQueued = false
                requestInputFocus()
                return
            }
        }
        // A stop during the archive write must not go on to call the provider,
        // and must not bump the generation the cancel already moved past.
        guard !Task.isCancelled else { return }
        let stream = service.send(messages: requestMessages, turnImages: requestImages)
        streamGeneration &+= 1
        let generation = streamGeneration
        inFlightTurn = currentConversation.map { ($0.id, submittedMessage.id) }
        // The archived assistant turn and the checkpoint cadence. The live
        // assistant message reuses this id, so the projection and the
        // checkpointed turn are one record.
        let assistantTurnID = UUID()
        currentAssistantTurnID = assistantTurnID
        let archivedConversationID = currentConversation?.id.uuidString
        let archivedConversationUUID = currentConversation?.id
        archiveCheckpointCharacters = 0
        streamStartedAt = submissionStartedAt ?? Date()
        streamFirstTokenAt = nil

        streamTask = Task {
            do {
                for try await delta in stream {
                    if Task.isCancelled || generation != streamGeneration { break }
                    if let status = delta.status {
                        streamingStatus = status
                    }
                    if let record = delta.toolRecord {
                        noteLiveToolRecord(record)
                        // The call is done and its line is drawn; the dots
                        // cover the wait for the next round.
                        streamingStatus = nil
                    }
                    // One finished model-to-tools-to-model round, with its
                    // calls, arguments, results, statuses, adapters and
                    // timing; and the tokens the provider reported.
                    if let toolRound = delta.toolRound {
                        streamToolRounds.append(toolRound)
                    }
                    if let usage = delta.usage {
                        streamUsage = usage
                    }
                    if let text = delta.text {
                        if !text.isEmpty {
                            streamingStatus = nil
                            if streamFirstTokenAt == nil { streamFirstTokenAt = Date() }
                        }
                        appendStreamText(text)
                    }
                    // Periodic durable checkpoint of the answer in flight,
                    // with the tool rounds finished so far.
                    //
                    // Started, never awaited. The checkpoint rewrites the
                    // whole conversation file and fsyncs it twice, so an
                    // `await` here stalls the stream on the disk. One runs at
                    // a time: a checkpoint skipped while another is in flight
                    // costs nothing, because the next one carries everything
                    // it would have written, and `ChatArchive` serializes its
                    // own writes so the order still holds.
                    if let chatArchive, let archivedConversationID, !output.isEmpty,
                       archiveCheckpointTask == nil,
                       output.count - archiveCheckpointCharacters >= 800 {
                        archiveCheckpointCharacters = output.count
                        let partial = output
                        let rounds = streamToolRounds
                        let turnID = assistantTurnID.uuidString
                        archiveCheckpointGeneration &+= 1
                        let checkpointGeneration = archiveCheckpointGeneration
                        archiveCheckpointTask = Task { [weak self] in
                            do {
                                _ = try await chatArchive.checkpoint(
                                    conversationID: archivedConversationID,
                                    turnID: turnID,
                                    update: .checkpoint(
                                        text: partial,
                                        toolRounds: rounds.isEmpty ? nil : rounds
                                    )
                                )
                            } catch {
                                AppLog.persistence.error(
                                    "Chat archive checkpoint failed: \(error.localizedDescription)"
                                )
                            }
                            if self?.archiveCheckpointGeneration == checkpointGeneration {
                                self?.archiveCheckpointTask = nil
                            }
                        }
                    }
                }
                // Stopped: `cancel()` kept the turn and the text that arrived.
                guard generation == streamGeneration else { return }
                flushStreamBuffer()
                // Stream completed normally. The final answer is frozen as a
                // mandatory archive write before the first suspension, so a
                // quit here waits for it instead of reading `isStreaming`.
                // The answer is terminal in the archive first, with the frozen
                // route and the receipt the turn actually ran, before the
                // projection can rewrite the record.
                var terminalWrite: Task<Bool, Never>?
                if !output.isEmpty {
                    let records = answerToolRecords(usedWebSearch: usedWebSearch)
                    currentConversation?.messages.append(
                        QuickMessage(
                            id: assistantTurnID,
                            role: .assistant,
                            content: output,
                            toolRecords: records.isEmpty ? nil : records
                        )
                    )
                    currentConversation?.updatedAt = Date()
                    if let archivedConversationUUID {
                        let finishedAt = Date()
                        let timings = requestTimings(finishedAt: finishedAt)
                        let rounds = streamToolRounds.isEmpty ? nil : streamToolRounds
                        let receipt = RequestReceipt(
                            selection: turnSelection,
                            status: .completed,
                            context: contextReceipt,
                            toolRounds: rounds ?? [],
                            timings: timings,
                            usage: streamUsage,
                            endpoint: frozenModel.endpoint,
                            startedAt: streamStartedAt,
                            finishedAt: finishedAt
                        )
                        terminalWrite = registerTerminalAnswer(
                            conversationID: archivedConversationUUID,
                            turnID: assistantTurnID,
                            status: .completed,
                            text: output,
                            receipt: receipt,
                            selection: turnSelection,
                            timings: timings,
                            usage: streamUsage,
                            toolRounds: rounds,
                            rounds: roundRecorder
                        )
                    }
                }
                streamingStatus = nil
                isStreaming = false
                inFlightTurn = nil
                if !output.isEmpty {
                    persistAnsweredConversation()
                    // The write was owed before `isStreaming` changed; waiting
                    // for it keeps `submit` returning a durable answer, as the
                    // inline write did. A refusal stays owed for the next quit.
                    _ = await terminalWrite?.value
                    // The lines live on the answer now.
                    liveToolRecords = []
                    if usedWebSearch { webSearchNote = nil }
                    // AI Chat is a window you read beside other work: a
                    // VoiceOver user hears that the answer is in.
                    if isAIChatWindow { announce(Self.answerReadyAnnouncement) }
                }
                recordJournal(
                    kind: output.isEmpty ? .aiFailed : .aiSucceeded,
                    scope: learningScope,
                    detail: output.isEmpty ? "empty-answer" : (action == nil ? "prompt" : "action")
                )
                var didAutoWrite = false
                if action?.outputBehavior == .reviewChanges, !output.isEmpty {
                    // Opt-in review: keep the answer on screen and offer the
                    // original beside it. Nothing replaces the selection
                    // until Accept, and Accept fails closed to Copy.
                    //
                    // Freeze the target now: bind only when the transform
                    // ran on the captured live selection itself, so a
                    // clipboard or attached source is never written into the
                    // app that happened to hold the launch selection.
                    let boundTarget = request.actionTarget
                    if !isAIChatWindow { openQuickAI() }
                    pendingTransformReview = PendingTransformReview(
                        original: request.actionSource,
                        proposed: output,
                        sourceApp: boundTarget?.target.applicationName ?? request.actionSourceApp,
                        target: boundTarget
                    )
                    didAutoWrite = true
                } else if action?.outputBehavior == .replaceSelection, !output.isEmpty {
                    didAutoWrite = true
                    // Bind to the text the action ran on. A typed alias
                    // context or a clipboard source never overwrites the
                    // captured launch selection; it copies instead.
                    let context = request.actionTarget
                    if let selectedTextService, let context {
                        _ = await writeBackValidated(
                            output: output,
                            in: context,
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
                // A saved action that ran on a captured selection and left its
                // result on screen is replaceable: offer Replace Selection so the
                // user can write it back explicitly. Scoped to this answer, never
                // inherited by a follow-up or an unrelated ad-hoc answer.
                if !didAutoWrite,
                   actionDefinition != nil,
                   let context = request.actionTarget {
                    replaceableSelectionContext = context
                }
                requestInputFocus()
            } catch is CancellationError {
                // Stopped by `cancel()`: it already kept the turn.
                guard generation == streamGeneration else { return }
                // Cancelled by the web answer's time limit instead: the turn
                // stays with the text that arrived, as Stop leaves it, and
                // `waitForWebAnswer` shows the search results if none did.
                let keptAnswer = keepStoppedAnswer()
                // An interrupted answer is recorded as such, never left
                // looking like it is still streaming.
                if let archivedConversationUUID {
                    let terminalWrite = registerTerminalAnswer(
                        conversationID: archivedConversationUUID,
                        turnID: assistantTurnID,
                        status: .cancelled,
                        error: "Interrupted",
                        text: output.isEmpty ? nil : output,
                        timings: requestTimings(finishedAt: Date()),
                        usage: streamUsage,
                        toolRounds: streamToolRounds.isEmpty ? nil : streamToolRounds
                    )
                    if keptAnswer { persistAnsweredConversation() }
                    _ = await terminalWrite?.value
                }
                liveToolRecords = []
                streamingStatus = nil
                isStreaming = false
                isFollowUpQueued = false
                recordJournal(kind: .aiCancelled, scope: learningScope, detail: "stopped")
                requestInputFocus()
            } catch {
                guard generation == streamGeneration else { return }
                // A provider error keeps the question in the thread with the
                // error under it; ⌘R asks it again. Text that arrived before
                // the error stays on screen, not as a turn.
                flushStreamBuffer()
                liveToolRecords = []
                streamingStatus = nil
                isStreaming = false
                inFlightTurn = nil
                threadError = ThreadError(messageID: submittedMessage.id, message: error.localizedDescription)
                // The failure is durable with the text that arrived.
                if let archivedConversationUUID {
                    let terminalWrite = registerTerminalAnswer(
                        conversationID: archivedConversationUUID,
                        turnID: assistantTurnID,
                        status: .failed,
                        error: error.localizedDescription,
                        text: output.isEmpty ? nil : output,
                        timings: requestTimings(finishedAt: Date()),
                        usage: streamUsage,
                        toolRounds: streamToolRounds.isEmpty ? nil : streamToolRounds
                    )
                    _ = await terminalWrite?.value
                }
                isFollowUpQueued = false
                recordJournal(kind: .aiFailed, scope: learningScope, detail: "provider-error")
                requestInputFocus()
            }
        }

        let task = streamTask
        if let task,
           usedWebSearch,
           let webSearchFallback = request.webSearchFallback {
            await waitForWebAnswer(
                task,
                fallback: webSearchFallback,
                submittedMessageID: submittedMessage.id,
                generation: generation
            )
        } else {
            await task?.value
        }
        // A finished stream leaves no handle behind, so `cancel()` can tell
        // a live model request from an ask still in its search phase.
        if streamTask == task { streamTask = nil }
        // A dismissal that arrived while this turn streamed left its clear
        // waiting. The answer is saved now, so the dismissed surface goes;
        // the reset also drops a follow-up the dismissal abandoned.
        runDeferredTransientClear()
        // A follow-up queued while this answer streamed goes now, unless the
        // stream was stopped or failed (both drop the queue).
        if generation == streamGeneration { await sendQueuedFollowUp() }
    }

    /// The exact provider body when the service is HTTP, or an explicit
    /// command-line input label when it is not. Built by the service's own
    /// request builder, so the system prompt, image parts, tool schemas, and
    /// reasoning fields are all present. Never a credential: the API key
    /// travels in a header this snapshot does not include.
    static func requestSnapshotData(
        service: any QuickService,
        model: String,
        messages: [QuickMessage],
        turnImages: [UUID: [QuickImageAttachment]]
    ) -> Data? {
        if let openAI = service as? OpenAICompatibleService,
           let body = try? openAI.buildRequest(messages: messages, turnImages: turnImages).httpBody {
            return body
        }
        return try? JSONSerialization.data(withJSONObject: [
            "kind": "command-line",
            "model": model,
            "prompt": messages.last(where: { $0.role == .user })?.content ?? "",
        ], options: [.sortedKeys])
    }

    /// The chat as the model gets it: every turn except a question that has
    /// no answer after it (stopped before any text, or a provider error),
    /// so the request alternates as the providers expect.
    static func answeredTurns(_ messages: [QuickMessage]) -> [QuickMessage] {
        return messages.enumerated().compactMap { index, message in
            let next = messages.indices.contains(index + 1) ? messages[index + 1] : nil
            if message.role == .user, next?.role == .user { return nil }
            return message
        }
    }

    /// Stop (or the web answer's time limit) on a model request: the
    /// question stays a turn and the text that arrived becomes its answer,
    /// so `⌘R` asks that same turn again. Written to history only when some
    /// text arrived. Only for the chat the request belongs to; a chat opened
    /// since is left alone. Returns whether it saved the stopped answer.
    @discardableResult
    func keepStoppedAnswer() -> Bool {
        flushStreamBuffer()
        guard let turn = inFlightTurn else { return false }
        inFlightTurn = nil
        guard currentConversation?.id == turn.conversationID,
              currentConversation?.messages.contains(where: { $0.id == turn.messageID }) == true,
              !output.isEmpty
        else { return false }
        let records = answerToolRecords(usedWebSearch: webSearchNote != nil)
        currentConversation?.messages.append(
            QuickMessage(
                id: currentAssistantTurnID ?? UUID(),
                role: .assistant,
                content: output,
                toolRecords: records.isEmpty ? nil : records
            )
        )
        currentConversation?.updatedAt = Date()
        liveToolRecords = []
        return true
    }

    /// What VoiceOver says when an answer finishes in AI Chat.
    static let answerReadyAnnouncement = "Answer ready"

    /// Return while an answer streams: queue what is typed. It stays in the
    /// composer ("Queued ↩") and is sent when the stream ends.
    func queueFollowUp() {
        // Waiting for chips to read is the same send, not a new one.
        guard isStreaming, !isWaitingForAttachments,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        isFollowUpQueued = true
    }

    /// The stream (or command) ended with an answer: send
    /// the queued follow-up as typed text. While a layer above the composer
    /// is open it keeps Return, so the follow-up stays queued and goes when
    /// that layer closes (`resumeQueuedFollowUp`).
    func sendQueuedFollowUp() async {
        guard isFollowUpQueued, !isStreaming, !holdsQueuedFollowUp else { return }
        isFollowUpQueued = false
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await submitTypedText()
    }

    /// A layer above the composer is open: a chooser, Recent Chats, or the
    /// `⌘K` pane or palette. A queued follow-up waits
    /// for it to close.
    private var holdsQueuedFollowUp: Bool {
        isTransformChooserPresented || isModelChooserPresented
            || isAddContextMenuPresented || isRecentChatsPresented || presentedLayer != nil
    }

    /// A layer above the composer closed: a follow-up that waited behind it
    /// after its stream ended goes now.
    func resumeQueuedFollowUp() {
        guard isFollowUpQueued, isQuickAIPresented, !isStreaming, !holdsQueuedFollowUp,
              queuedFollowUpTask == nil
        else { return }
        queuedFollowUpTask = Task { @MainActor [weak self] in
            await self?.sendQueuedFollowUp()
            // `cancel()` drops the handle itself; a cancelled send must not
            // clear a newer one.
            guard !Task.isCancelled else { return }
            self?.queuedFollowUpTask = nil
        }
    }

    // MARK: - Cancel

    /// Stops a stream as Escape does. Returns whether it kept and saved the
    /// stopped answer; a no-text stop returns false and saves nothing.
    @discardableResult
    func cancel() -> Bool {
        var keptStoppedAnswer = false
        // A running command action has no `streamTask`; a model request does.
        // Only claim a cancellation that really happened: the model lane
        // records here, and the command lane records from `runCommandAction`
        // once `ProcessRunner` confirms the child was terminated.
        let wasStreaming = isStreaming
        let cancelledModelRequest = wasStreaming && streamTask != nil
        // Streaming with the question still pending and nothing else running
        // is the enrichment phase (a web search or page read): the submit
        // itself is what is in flight, and the question was never a turn.
        let cancelledEnrichment = wasStreaming && streamTask == nil && commandTask == nil
            && pendingQuestion != nil
        // A send waiting for its chips: the reads stop, the typed text stays.
        cancelAttachmentWait()
        if cancelledModelRequest {
            // Stop keeps the question and what the model said so far, as the
            // turn's answer; `⌘R` asks the same turn again.
            keptStoppedAnswer = keepStoppedAnswer()
            // A stopped answer is terminal in the archive, never left looking
            // like it is still streaming. Registering here, before this
            // method returns, freezes the write and its own retry payload
            // before any quit can await.
            if let conversation = currentConversation,
               let assistantTurnID = currentAssistantTurnID {
                registerTerminalAnswer(
                    conversationID: conversation.id,
                    turnID: assistantTurnID,
                    status: .cancelled,
                    error: "Stopped by the user",
                    text: output.isEmpty ? nil : output,
                    timings: requestTimings(finishedAt: Date()),
                    usage: streamUsage,
                    toolRounds: streamToolRounds.isEmpty ? nil : streamToolRounds
                )
                if keptStoppedAnswer { persistAnsweredConversation() }
            }
        } else {
            discardStreamBuffer()
            output = ""
        }
        // The stopped stream may still end later; from here it writes nothing.
        streamGeneration &+= 1
        inFlightTurn = nil
        streamTask?.cancel()
        streamTask = nil
        commandTask?.cancel()
        commandTask = nil
        // The submit that started the ask (Tab, or Return in the composer)
        // is still awaiting its search; a stopped ask must not go on to
        // call the model when that await returns.
        tabSubmitTask?.cancel()
        tabSubmitTask = nil
        composerSubmitTask?.cancel()
        composerSubmitTask = nil
        queuedFollowUpTask?.cancel()
        queuedFollowUpTask = nil
        isStreaming = false
        streamingStatus = nil
        // A queued follow-up stays in the composer, unsent.
        isFollowUpQueued = false
        liveToolRecords = []
        if cancelledEnrichment {
            pendingQuestion = nil
            // The search line was made for an answer that will not come.
            webSearchNote = nil
            // The question goes back in the composer now, before whatever
            // the caller does next (Recent Chats or root search may clear
            // it), not when the cancelled search returns later.
            restoreEnrichmentInput()
        }
        guard cancelledModelRequest else { return keptStoppedAnswer }
        recordJournal(kind: .aiCancelled, scope: learningScope, detail: "stopped")
        requestInputFocus()
        return keptStoppedAnswer
    }

    // MARK: - Stream buffering

    func appendStreamText(_ text: String) {
        streamBuffer += text
        if output.isEmpty || ContinuousClock.now - lastStreamFlush >= Self.streamFlushInterval {
            flushStreamBuffer()
        } else if streamFlushTask == nil {
            // A pause between tokens must not hide the last few: flush on a timer.
            streamFlushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.streamFlushInterval)
                guard !Task.isCancelled else { return }
                self?.streamFlushTask = nil
                self?.flushStreamBuffer()
            }
        }
    }

    func flushStreamBuffer() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        guard !streamBuffer.isEmpty else { return }
        output += streamBuffer
        streamBuffer = ""
        lastStreamFlush = .now
    }

    func discardStreamBuffer() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        streamBuffer = ""
    }
}
