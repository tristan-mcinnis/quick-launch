import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// Lightweight follow-up history.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - Lightweight follow-up history

    /// Whether the next question starts a fresh chat. "Always" and "Never"
    /// are not windows: one starts a new chat every time, the other keeps the
    /// thread until the user starts a new chat by hand. The AI Chat window
    /// is a chat you come back to: a follow-up there always stays in it.
    var shouldStartNewConversation: Bool {
        guard !isAIChatWindow, let conversation = currentConversation else { return false }
        // A picked assistant with nothing asked yet is the chat the next
        // question starts, however long ago it was picked.
        if conversation.messages.isEmpty, conversation.assistantID != nil { return false }
        let updatedAt = conversation.updatedAt
        switch settings.newChatInterval {
        case .always:
            return true
        case .never:
            return false
        case let option:
            guard let minutes = option.minutes else { return false }
            return now().timeIntervalSince(updatedAt) > Double(minutes) * 60
        }
    }

    func loadHistory() {
        // With the canonical archive present the archive is the authority: a
        // legacy "Keep chat history" switch or "Chats to keep" count no
        // longer decides what is read or kept. Their keys stay in the
        // settings blob for rollback, but they gate only the legacy cache.
        if chatArchive != nil {
            loadCanonicalHistory()
            return
        }
        guard settings.historyEnabled, let historyFileURL else {
            history = []
            return
        }
        switch QuickHistoryStore.loadResult(from: historyFileURL) {
        case .loaded(let legacy):
            history = legacy
        case .missing:
            history = []
        case .corrupt:
            // A damaged legacy cache is rollback evidence: never read as
            // empty and never overwritten.
            AppLog.persistence.error("Chat history cache is damaged; keeping it as rollback data.")
            history = []
        }
    }

    /// Reads the canonical archive as the chat list, whatever the legacy
    /// retention settings say.
    private func loadCanonicalHistory() {
        // The legacy file is read once, as a migration source, and never as
        // the authority. A damaged one defers to the archive.
        var legacy: [QuickConversation] = []
        if let historyFileURL, case .loaded(let cached) = QuickHistoryStore.loadResult(from: historyFileURL) {
            legacy = cached
        }
        cutoverToArchive(legacy: legacy)
    }

    /// The one-time cutover to the durable archive. The legacy cache is
    /// backed up for rollback, its chats are imported (idempotent), and the
    /// migration must be clean and verified readable before the archive
    /// becomes the canonical, unbounded list. The legacy file is left in
    /// place and is only ever rewritten as a bounded cache.
    func cutoverToArchive(legacy: [QuickConversation]) {
        guard let chatArchive else { return }
        let appVersion = currentVersion
        let historyFileURL = historyFileURL
        let limit = settings.historyLimit
        Task { [weak self] in
            guard let self else { return }
            do {
                if let historyFileURL {
                    _ = try QuickHistoryStore.backupForRollback(from: historyFileURL)
                }
                let report = await chatArchive.migrate(legacy: legacy, appVersion: appVersion)
                guard report.isClean else {
                    AppLog.persistence.error(
                        "Chat archive migration was not clean: \(report.failures.joined(separator: "; "))"
                    )
                    return
                }
                // Verified readable. Damaged records are surfaced, never
                // silently dropped, and the cache is not rewritten from a
                // partial list.
                let projection = try await chatArchive.projectReadable()
                self.history = QuickHistoryStore.ordered(QuickHistoryStore.droppingRetired(projection.conversations))
                self.archiveDamagedCount = projection.damaged.count
                if projection.damaged.isEmpty, let historyFileURL {
                    QuickHistoryStore.rebuildCache(self.history, limit: limit, to: historyFileURL)
                } else if !projection.damaged.isEmpty {
                    AppLog.persistence.error(
                        "Chat archive has \(projection.damaged.count) unreadable records; the cache was left untouched."
                    )
                }
                AppLog.persistence.info(
                    "Chat archive cutover: \(report.imported) imported, \(report.alreadyPresent) already present, \(projection.conversations.count) canonical"
                )
            } catch {
                AppLog.persistence.error("Chat archive cutover failed: \(error.localizedDescription)")
            }
        }
    }

    func startNewConversation(cancelingSubmitTasks: Bool = true) {
        expandedTranscriptMessageIDs.removeAll()
        reset([.thread, .input], cancelingSubmitTasks: cancelingSubmitTasks)
        requestInputFocus()
    }
    /// Confirmed deletion of every saved chat.
    ///
    /// The view calls this **only** after the user confirms in the delete
    /// alert; it is never inferred from a toggle, never run at startup, and
    /// never runs twice at once. It stops requests that are in flight or still
    /// being prepared first, so nothing prepared before the deletion can write
    /// a chat back into the store, then tombstones and removes every owned
    /// chat and reclaims the bytes no record still references.
    ///
    /// A failure is `savedHistoryOperationError` and the list is left as it
    /// was: the canonical archive preflights every record, so "could not read
    /// one chat" never turns into "deleted everything".
    func clearHistory() {
        guard !isClearingHistory else { return }
        savedHistoryOperationError = nil
        guard let chatArchive else {
            clearLegacyHistory()
            return
        }
        // Nothing prepared or streaming may write into the store we are
        // emptying. `cancel()` also keeps the text that already arrived.
        cancel()
        cancelAttachmentWait()
        isClearingHistory = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await chatArchive.deleteAll()
                if report.isComplete {
                    self.applyClearedHistory()
                    self.savedHistoryOperationError = report.gcIssue.map {
                        "Saved chats were deleted, but their stored files could not all be reclaimed: \($0)"
                    }
                } else {
                    self.savedHistoryOperationError =
                        "Some saved chats could not be deleted (\(report.failedIDs.count)). Nothing else was removed."
                    self.refreshHistoryFromArchive()
                }
            } catch {
                // Fail closed: nothing was deleted, so the list stays.
                self.savedHistoryOperationError = "Could not delete saved chats: \(error.localizedDescription)"
            }
            self.isClearingHistory = false
            self.requestInputFocus()
        }
    }

    /// The legacy store when no canonical archive exists: this is all there
    /// is, and the old retention settings still bound it.
    private func clearLegacyHistory() {
        store.deletedChatIDs.formUnion(history.map(\.id))
        history = []
        // The attachments' text goes with the chats: it lived in memory only.
        attachmentStore.removeAll()
        currentConversation = nil
        if let historyFileURL { QuickHistoryStore.clear(from: historyFileURL) }
        output = ""
        errorMessage = nil
    }

    /// Everything the deletion removed, as the UI now shows it.
    private func applyClearedHistory() {
        store.deletedChatIDs.formUnion(history.map(\.id))
        history = []
        archiveDamagedCount = 0
        attachmentStore.removeAll()
        currentConversation = nil
        if let historyFileURL { QuickHistoryStore.clear(from: historyFileURL) }
        output = ""
        errorMessage = nil
    }

    /// After a partial failure: the list is exactly what the archive still
    /// holds, so the user is not shown a chat that is gone or hidden from one
    /// that is not.
    private func refreshHistoryFromArchive() {
        guard let chatArchive else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let projection = try? await chatArchive.projectReadable() else { return }
            self.history = QuickHistoryStore.ordered(QuickHistoryStore.droppingRetired(projection.conversations))
            self.archiveDamagedCount = projection.damaged.count
        }
    }

    func loadConversation(id: UUID) {
        guard let conversation = history.first(where: { $0.id == id }) else { return }
        loadConversation(conversation)
    }

    /// Puts a chat on the thread: the stored copy (`loadConversation(id:)`),
    /// or the one a hand-off carried when history is off.
    func loadConversation(_ conversation: QuickConversation) {
        currentConversation = conversation
        // A new chat starts from the policy's own decision, not the one
        // chat's override.
        contextOverride = nil
        openChatBase = history.first { $0.id == conversation.id }.map(StoredChatStamp.init)
        expandedTranscriptMessageIDs.removeAll()
        output = conversation.messages.last(where: { $0.role == .assistant })?.content ?? ""
        // The chat answers on its own model (`chatModelChoice`); opening it
        // leaves the Quick AI default and the other window alone.
        pendingModelChoice = nil
        errorMessage = nil
        threadError = nil
        answerSource = .model
        // The finished-search line belongs to the answer it was made for,
        // as does a question that never became a turn, and the hand-off
        // line to the chat it was for.
        webSearchNote = nil
        liveToolRecords = []
        threadNotice = nil
        pendingQuestion = nil
        input = ""
        // Another chat opens where it was left, or on its newest turn.
        if let anchor = threadAnchors.anchor(for: conversation.id),
           conversation.messages.contains(where: { $0.id == anchor.messageID }) {
            isThreadFollowingBottom = false
            openingAnchor = (conversation.id, anchor)
        } else {
            openingAnchor = nil
            threadAnchors.record(nil, for: conversation.id)
            followThreadBottom()
        }
        resumeRetainedAttachments(for: conversation)
    }

    /// Loads a reopened chat's attachment text and images back into the
    /// session store from the durable archive, so a follow-up or a reopen
    /// works without re-reading a source that may have changed. The archive
    /// is the only source here; a role that was never archived stays missing
    /// and is never fetched again.
    func resumeRetainedAttachments(for conversation: QuickConversation) {
        guard chatArchive != nil else { return }
        let refs = conversation.messages.flatMap(\.attachmentRefs)
        let conversationID = conversation.id.uuidString
        Task { [weak self] in
            guard let self, let chatArchive = self.chatArchive else { return }
            // A turn in flight when the app quit is marked interrupted, so it
            // never reads as still streaming in the archive.
            if let record = try? await chatArchive.load(id: conversationID) {
                for turn in record.turns where turn.role == .assistant {
                    let status = turn.request?.status
                    if status == .streaming || status == .pending {
                        do {
                            _ = try await chatArchive.failTurn(
                                conversationID: conversationID,
                                turnID: turn.id,
                                error: "Interrupted before completion",
                                status: .cancelled,
                                text: turn.text.isEmpty ? nil : turn.text
                            )
                        } catch {
                            AppLog.persistence.error(
                                "Chat archive interrupt write failed: \(error.localizedDescription)"
                            )
                        }
                    }
                }
            }
            for ref in refs {
                if self.attachmentStore.isLoaded(ref) { continue }
                do {
                    guard let source = try await chatArchive.retainedSource(
                        conversationID: conversationID,
                        attachmentID: ref.id.uuidString
                    ) else { continue }
                    if source.extractedText != nil {
                        // The versioned extraction artifact: the model text and
                        // the structured document both come from here, never
                        // from the raw UTF-8 blob.
                        if let text = try await chatArchive.retainedText(
                            conversationID: conversationID,
                            attachmentID: ref.id.uuidString
                        ), !text.isEmpty {
                            let document = try await chatArchive.retainedDocument(
                                conversationID: conversationID,
                                attachmentID: ref.id.uuidString
                            )
                            self.attachmentStore.storeText(
                                AttachmentSessionStore.Text(
                                    text: text,
                                    kindLabel: ref.kind.displayName,
                                    notes: [],
                                    extractedDocument: document
                                ),
                                for: ref
                            )
                        } else if !source.damagedRoles.isEmpty {
                            // The envelope is stored but no longer decodes, so
                            // the model text is not there. Say so instead of
                            // letting the attachment resume as absent.
                            AppLog.persistence.error(
                                "Retained extraction is damaged and cannot be resumed: \(ref.kind.displayName)"
                            )
                        }
                    }
                    if ref.kind.isImage, let imageRef = source.normalizedImage {
                        let imageData = try await chatArchive.readArtifact(imageRef)
                        let ext = imageRef.fileExtension?.lowercased()
                        let mime = (ext == "jpg" || ext == "jpeg") ? "image/jpeg" : "image/png"
                        self.attachmentStore.storeImage(
                            QuickImageAttachment(
                                data: imageData,
                                mimeType: mime,
                                pixelWidth: ref.pixelWidth ?? 0,
                                pixelHeight: ref.pixelHeight ?? 0
                            ),
                            for: ref
                        )
                    }
                } catch {
                    // A missing or damaged artifact stays missing: it is never
                    // re-read from the source or re-fetched.
                    AppLog.persistence.error(
                        "Retained attachment could not be read: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    func persistCurrentConversation() {
        // The canonical archive keeps every chat whatever the legacy
        // retention settings say. Without one, the old switch bounds the
        // only store there is.
        if chatArchive == nil, !settings.historyEnabled { return }
        guard let local = currentConversation,
              let conversation = conversationToStore(local)
        else { return }
        currentConversation = conversation
        // The canonical in-memory list is never capped; only the on-disk
        // cache is bounded by the "Chats to keep" setting.
        var merged = history.filter { $0.id != conversation.id }
        merged.append(conversation)
        history = QuickHistoryStore.ordered(merged)
        openChatBase = StoredChatStamp(conversation)
        saveHistory()
        syncConversationToArchive(conversation)
    }

    /// The projection of the latest turn into the structured archive. The
    /// question was already committed before Send; this carries the answer and
    /// the chat's current shape. The write is owed until it lands, so a quit
    /// waits for it and a failure is retried instead of logged and forgotten.
    func syncConversationToArchive(_ conversation: QuickConversation) {
        guard chatArchive != nil,
              conversation.messages.contains(where: { $0.role == .assistant })
        else { return }
        durability?.record(conversation, after: archiveCheckpointTask)
    }

    /// Registers the final answer of one turn as a mandatory archive write.
    /// Synchronous on purpose: the caller runs it where the text became final
    /// and before its first suspension, so a quit cannot observe a finished
    /// answer with no debt behind it. A chat the user deleted gets no write.
    @discardableResult
    func registerTerminalAnswer(
        conversationID: UUID,
        turnID: UUID,
        status: RequestStatus,
        error: String? = nil,
        text: String?,
        receipt: RequestReceipt? = nil,
        selection: ModelSelection? = nil,
        timings: RequestTimings,
        usage: TokenUsage?,
        toolRounds: [ToolRound]?,
        rounds: ChatRoundRecorder? = nil
    ) -> Task<Bool, Never>? {
        guard let durability, !store.deletedChatIDs.contains(conversationID) else { return nil }
        return durability.register(
            AnswerTerminalWrite(
                conversationID: conversationID,
                turnID: turnID,
                status: status,
                error: error,
                text: text,
                receipt: receipt,
                selection: selection,
                timings: timings,
                usage: usage,
                toolRounds: toolRounds,
                rounds: rounds,
                checkpointFence: archiveCheckpointTask
            )
        )
    }

    /// The activity revision a quit compares against after its awaits. A
    /// change means work was accepted after the freeze, so the attempt is stale.
    var answerDurabilityRevision: Int { durability?.revision ?? 0 }

    /// True while any accepted submit has not reached its model request yet.
    var isSubmitBeforeStream: Bool { !preStreamSubmitTokens.isEmpty }

    /// Freezes the archive writes this quit owns. Call it after the stop and
    /// before the first await: a late completion can only finish frozen
    /// persistence, never stop a request that started after a refusal.
    func freezeAnswerDurability() -> AnswerDurability.Snapshot {
        durability?.freeze() ?? .empty
    }

    /// Awaits one quit's frozen archive work and reports what is still owed.
    func settleAnswerDurability(_ snapshot: AnswerDurability.Snapshot) async -> AnswerDurability.Verdict {
        guard let durability else { return .durable }
        return await durability.settle(snapshot)
    }

    /// Convenience for callers that freeze and settle in one step.
    @discardableResult
    func flushArchiveForQuit() async -> Bool {
        await settleAnswerDurability(freezeAnswerDurability()) == .durable
    }

    /// Clears the local slash-command refusal (the composer's Send as Text,
    /// `/new`, `/clear`).
    func clearRefusedCommand() { refusedCommandText = nil }

    /// A question that became a turn but could not go out leaves the
    /// thread. `submittedInput` goes back in the composer when given and
    /// the field is empty; `nil` (⌘R) leaves the composer alone.
    func rollbackSubmission(messageID: UUID, restoring submittedInput: String?) {
        currentConversation?.messages.removeAll { $0.id == messageID }
        currentConversation?.updatedAt = Date()
        if let submittedInput, input.isEmpty { input = submittedInput }
    }
}
