import Foundation
import Observation

/// What the launcher and the AI Chat window share: the settings and the
/// chat history. One store, two views. Each window has its own
/// `QuickViewModel` (its own composer, thread, stream, and layers), and both
/// read and write `settings` and `history` through the same instance, so a
/// chat asked in one window is in the other's list at once. The model a
/// chat answers with is the chat's own (`QuickConversation.model`), so a
/// Change Model in one window never changes the other.
///
/// Each view model still holds its own copy of the chat it shows
/// (`currentConversation`). The store is the single source for that chat:
/// a view model re-reads it whenever the other view writes the history,
/// before it asks, and when its window comes back, and it merges when it
/// saves (`QuickViewModel+AIChat.swift`, "One store, two views"), so
/// neither view writes a stale copy over the other's turns, rename, pin,
/// or delete. One chat is open in one view: opening a chat the other view
/// has open takes it from there.
///
/// The disk side is unchanged: `QuickSettings.save()` and
/// `QuickHistoryStore` (one serial `JSONFileStore` queue) still do the I/O.
@Observable @MainActor final class QuickStore {
    var settings: QuickSettings
    var history: [QuickConversation]
    /// Chats deleted this session (one by one, or by Clear History). A view
    /// that still shows one drops it instead of saving it back. In memory
    /// only: the ids are random, so they never come back on their own.
    @ObservationIgnored var deletedChatIDs: Set<UUID> = []
    /// The text (and pictures) of the chats' attachments, in memory for this
    /// session only. History keeps each attachment's reference, never its
    /// text; both views read the text here, so a chat moved between them
    /// keeps its attachments.
    let attachments: AttachmentSessionStore

    init(
        settings: QuickSettings = QuickSettings(),
        history: [QuickConversation] = [],
        attachments: AttachmentSessionStore = AttachmentSessionStore()
    ) {
        self.settings = settings
        self.history = history
        self.attachments = attachments
    }

    // MARK: - The views on this store

    /// A view held weakly, so the store never keeps a view model alive.
    private struct WeakView {
        weak var view: QuickViewModel?
    }

    /// The launcher's view model and the AI Chat window's, in the order
    /// they joined. Each joins in its own `init`.
    @ObservationIgnored private var registeredViews: [WeakView] = []

    func register(_ view: QuickViewModel) {
        registeredViews.removeAll { $0.view == nil || $0.view === view }
        registeredViews.append(WeakView(view: view))
    }

    /// Every live view on this store but `view`.
    func views(besides view: QuickViewModel) -> [QuickViewModel] {
        registeredViews.compactMap(\.view).filter { $0 !== view }
    }

    /// `writer` changed the history: every other view brings its open chat
    /// up to the store now, not only when its window comes back.
    func historyDidChange(by writer: QuickViewModel) {
        for view in views(besides: writer) {
            view.storeHistoryDidChange()
        }
    }
}
