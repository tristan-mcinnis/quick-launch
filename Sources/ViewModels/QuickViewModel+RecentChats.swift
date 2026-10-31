import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    // MARK: - Recent Chats (⌘P)

    /// `⌘P`: the recent chat list in place of the thread, inside the same
    /// Quick AI window. One column; `↑↓` move, `↩` opens, `esc` returns to
    /// the thread. P for past chats: `⌘J` became Open in AI Chat
    /// (Raycast's key) in v1.5.0, and `⌘P` was free in every key table
    /// (`⇧⌘P` is Pin, `⌥⌘P` is Continue in pi). In the AI Chat window the
    /// same key opens the chat list.
    static let recentChatsShortcut: KeyShortcut = .command("p")

    /// Recent Chats has something to list.
    var canOpenRecentChats: Bool { !history.isEmpty || currentConversation != nil }

    /// Opens Recent Chats. The thread, the model, and any attachments are
    /// already in state, so they carry over untouched; this only changes
    /// what is drawn.
    func openRecentChats() {
        guard canOpenRecentChats else {
            errorMessage = "No chats yet. Ask a question first."
            requestInputFocus()
            return
        }
        // The same entry as Tab: a catalog, an input mode, or a Quick Link
        // input steps aside so the composer's Return asks.
        openQuickAI()
        isRecentChatsPresented = true
        isModelChooserPresented = false
        isCaptureChooserPresented = false
        isAddContextMenuPresented = false
        // The composer is the list's search field now; a half-typed
        // follow-up would filter the list, so the list opens on all chats.
        // A queued follow-up leaves the field with it, so it is not queued.
        isFollowUpQueued = false
        input = ""
        recentChatsIndex = currentConversation
            .flatMap { conversation in
                recentChatItems.firstIndex { $0.itemID == conversation.id.uuidString }
            } ?? 0
        requestInputFocus()
    }

    /// Back to the thread. The search text belonged to the list, so it goes
    /// with it rather than becoming a follow-up.
    func closeRecentChats() {
        guard isRecentChatsPresented else { return }
        isRecentChatsPresented = false
        input = ""
        requestInputFocus()
    }

    /// Escape in Recent Chats: typed search text clears first, as in every
    /// catalog, then the list closes.
    func popRecentChatsLayer() {
        if input.isEmpty {
            closeRecentChats()
        } else {
            input = ""
            recentChatsIndex = 0
            requestInputFocus()
        }
    }

    func toggleRecentChats() {
        if isRecentChatsPresented {
            closeRecentChats()
        } else {
            openRecentChats()
        }
    }

    /// The rows of Recent Chats: the launcher's own chat rows (the Chats
    /// catalog), pinned first, newest next, narrowed by the composer text
    /// while the list is up. `recentChatsIndex` indexes this list, so the
    /// keys and the drawn rows agree.
    var recentChatItems: [LauncherCatalogItem] {
        chatItems(matching: isRecentChatsPresented ? input : "")
    }

    /// The composer's text changed on the Quick AI surface. In Recent Chats
    /// it is the search, so typing moves the highlight to the first match
    /// (a search cleared by opening or Escape keeps the highlight it set);
    /// elsewhere a typed `@` opens Add Context.
    func quickAIComposerDidChange(_ newValue: String, allowsContextTrigger: Bool = true) {
        noteInteraction()
        // A queued follow-up cleared from the field is no longer queued.
        if isFollowUpQueued, newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isFollowUpQueued = false
        }
        if isRecentChatsPresented {
            if !newValue.isEmpty { recentChatsIndex = 0 }
        } else {
            if allowsContextTrigger { addContextTriggerDidChange(newValue) }
            // The `/` palette opens on the character and narrows as the
            // name is typed, so it is evaluated on every change, not only
            // on the keystroke that opened it.
            slashCommandTriggerDidChange(newValue)
        }
    }

    func moveRecentChatsSelection(_ delta: Int) {
        let count = recentChatItems.count
        guard count > 0 else { return }
        recentChatsIndex = ListSelection.wrappedIndex(
            recentChatsIndex,
            by: delta,
            count: count
        )
    }

    /// Return in Recent Chats: open the highlighted chat in the thread and
    /// clear the search text. A search with no match keeps the list up.
    func openSelectedRecentChat() {
        let items = recentChatItems
        guard items.indices.contains(recentChatsIndex) else {
            if input.isEmpty { closeRecentChats() }
            return
        }
        // A stream still running belongs to the chat being left.
        if isStreaming { cancel() }
        continueConversation(itemID: items[recentChatsIndex].itemID)
        isRecentChatsPresented = false
        input = ""
        requestInputFocus()
    }
}
