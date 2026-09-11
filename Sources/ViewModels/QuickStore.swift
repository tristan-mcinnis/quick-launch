import Foundation
import Observation

/// What the launcher and the AI Chat window share: the settings and the
/// chat history. One store, two views. Each window has its own
/// `QuickViewModel` (its own composer, thread, stream, and layers), and both
/// read and write `settings` and `history` through the same instance, so a
/// chat asked in one window is in the other's list at once, a model picked
/// in one is the model in the other.
///
/// Each view model still holds its own copy of the chat it shows
/// (`currentConversation`). The store is the single source for that chat:
/// a view model re-reads it before it asks, when its window comes back, and
/// when it saves (`QuickViewModel+AIChat.swift`, "One store, two views"),
/// so neither view writes a stale copy over the other's turns, rename, pin,
/// or delete.
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

    init(settings: QuickSettings = QuickSettings(), history: [QuickConversation] = []) {
        self.settings = settings
        self.history = history
    }
}
