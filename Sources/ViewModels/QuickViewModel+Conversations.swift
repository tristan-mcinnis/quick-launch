import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    // MARK: - Quick AI chats

    /// Return on a Chats catalog row: the chat on the Quick AI surface, as
    /// Return in Recent Chats opens it. A stream still running belongs to
    /// the chat being left.
    func continueChatInQuickAI(itemID: String) {
        guard let id = UUID(uuidString: itemID), history.contains(where: { $0.id == id }) else { return }
        if isStreaming { cancel() }
        continueConversation(itemID: itemID)
        openQuickAI()
    }

    func continueConversation(itemID: String) {
        guard let id = UUID(uuidString: itemID) else { return }
        // One chat, one view: a chat the other view has open moves here.
        takeChatFromOtherViews(id)
        closeItemActionPane()
        catalogScope = nil
        inputMode = nil
        loadConversation(id: id)
        lastQuestion = currentConversation?.messages.last(where: { $0.role == .user })?.content
        invalidateLauncherRanking()
        requestInputFocus()
    }

    /// One writer per chat for archive-only metadata. The history is a cache
    /// and the archive is canonical, so writes queue in the order the user
    /// made them and a failure is logged, never hidden.
    private func enqueueArchiveWrite(
        for chatID: UUID,
        _ operation: @escaping @Sendable (ChatArchive) async throws -> Void
    ) {
        let previous = archiveWriteChain[chatID]
        archiveWriteChain[chatID] = Task { [chatArchive] in
            await previous?.value
            guard let chatArchive else { return }
            do {
                try await operation(chatArchive)
            } catch {
                AppLog.persistence.error(
                    "Chat archive write failed for \(chatID.uuidString): \(error.localizedDescription)"
                )
            }
        }
    }

    func togglePinConversation(id: UUID) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].isPinned.toggle()
        if currentConversation?.id == id { currentConversation?.isPinned = history[index].isPinned }
        let pinned = history[index].isPinned
        saveHistory()
        invalidateLauncherRanking()
        // The canonical record is the archive; the history is a cache.
        if chatArchive != nil {
            enqueueArchiveWrite(for: id) { archive in
                try await archive.setPinned(id: id.uuidString, isPinned: pinned)
            }
        }
    }

    func renameConversation(id: UUID, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].customTitle = clean.isEmpty ? nil : clean
        if currentConversation?.id == id { currentConversation?.customTitle = history[index].customTitle }
        let custom = history[index].customTitle
        let titleSource = history[index].titleSource
        saveHistory()
        invalidateLauncherRanking()
        if chatArchive != nil {
            enqueueArchiveWrite(for: id) { archive in
                try await archive.rename(id: id.uuidString, customTitle: custom, titleSource: titleSource)
            }
        }
    }

    func deleteConversation(id: UUID) {
        store.deletedChatIDs.insert(id)
        let deleted = history.filter { $0.id == id }
        history.removeAll { $0.id == id }
        if currentConversation?.id == id {
            forgetAttachments(of: deleted + [currentConversation].compactMap { $0 })
        } else {
            forgetAttachments(of: deleted)
        }
        if currentConversation?.id == id { startNewConversation() }
        saveHistory()
        invalidateLauncherRanking()
        applicationSelectionIndex = 0
        // Delete the canonical record: the tombstone stops a late write from
        // recreating the chat. The delete is owed until it lands, so a quit
        // waits for it and a failure is retried; a chat the user deleted must
        // not survive a quit just because a write failed.
        if chatArchive != nil {
            durability?.registerDeletion(id)
        }
    }

    func saveHistory() {
        // The canonical archive is the authority for what is kept; the legacy
        // file is only a bounded, rebuildable cache once that archive exists.
        // Without one (a legacy fixture) the old switch still bounds this
        // store, because then it is all there is.
        if chatArchive == nil, !settings.historyEnabled { return }
        guard let historyFileURL else { return }
        QuickHistoryStore.save(history, limit: settings.historyLimit, to: historyFileURL)
    }

    /// ⌘[ / ⌘]: move through recent chats, pinned first.
    func browseConversations(_ delta: Int) {
        let ordered = QuickHistoryStore.ordered(history)
        guard !ordered.isEmpty else { return }
        // History is newest first: positive delta goes to older chats
        // (backwards in time), negative to newer ones. With no chat open,
        // either direction lands on the most recent chat first.
        let currentIndex = ordered.firstIndex { $0.id == currentConversation?.id }
        let next = currentIndex.map { ($0 + delta + ordered.count) % ordered.count } ?? 0
        continueConversation(itemID: ordered[next].id.uuidString)
    }

    /// The thread ends on a question with no answer after it: stopped
    /// before any text arrived, or a provider error.
    var hasUnansweredTurn: Bool { conversationMessages.last?.role == .user }

    /// ⌘R: ask the last question again and replace its answer: the answer
    /// that finished, the partial one a Stop kept, or the error a failure
    /// left. Whatever is typed in the composer stays there.
    func regenerateLastAnswer() async {
        refreshOpenChatFromStore()
        guard !isStreaming,
              var conversation = currentConversation,
              let lastUser = conversation.messages.lastIndex(where: { $0.role == .user })
        else { return }
        let question = conversation.messages[lastUser].content
        let replaced = Array(conversation.messages[lastUser...])
        let previousOutput = output
        let previousError = threadError
        conversation.messages.removeSubrange(lastUser...)
        currentConversation = conversation
        output = ""
        threadError = nil
        // The turn is asked with the attachments it had: its references,
        // read from the session store (pictures included).
        reaskedAttachments = replaced.first?.attachments
        defer { reaskedAttachments = nil }
        await submit(text: question, reasksTurn: true)
        // The ask never went out (no provider, no key): the thread is left
        // as it was, and the bottom line says why.
        if currentConversation?.id == conversation.id,
           currentConversation?.messages.count == conversation.messages.count {
            currentConversation?.messages.append(contentsOf: replaced)
            output = previousOutput
            threadError = previousError
        }
    }

    /// Retry under a failed turn: `⌘R`, from the control.
    func retryFailedTurn() {
        guard retryTask == nil, !isStreaming else { return }
        retryTask = Task { @MainActor [weak self] in
            await self?.regenerateLastAnswer()
            self?.retryTask = nil
        }
    }

    /// Turn a clipboard entry into a snippet or a Quick Link, then open the
    /// new item's editor so the title can be fixed right away.
    func saveClipboardEntry(_ item: LauncherCatalogItem, asLink: Bool) {
        guard let launcherCatalog else {
            errorMessage = LauncherCatalogError.creationUnsupported.localizedDescription
            requestInputFocus()
            return
        }
        do {
            let created: LauncherCatalogItem
            if asLink {
                let host = URL(string: item.value.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "Link"
                created = try launcherCatalog.createQuickLink(title: host, value: item.value)
            } else {
                created = try launcherCatalog.createSnippet(title: Self.snippetTitle(from: item.value), value: item.value)
            }
            errorMessage = nil
            catalogScope = asLink ? .quickLinks : .snippets
            input = ""
            openActionPane(for: .item(created), form: asLink ? .alias : .edit)
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
        }
    }

    func revealInFinder(_ application: LaunchableApplication) {
        closeItemActionPane()
        input = ""
        overlayPresenter.dismissOverlay()
        workspace.revealInFileViewer([application.url])
    }

    func closeCatalogActionPane() {
        closeItemActionPane()
    }
}
