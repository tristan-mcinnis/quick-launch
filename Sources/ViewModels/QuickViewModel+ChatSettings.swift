import Foundation

/// Settings › General › Chat and Settings › General › History: the status
/// lines under the chat defaults, and the history limit.
extension QuickViewModel {

    /// Asks the probe again and keeps the answer. The lookups run off the
    /// main thread; the card shows "Checking" until they return.
    func refreshChatBackendStatus() async {
        guard let chatBackendProbe else { return }
        let status = await chatBackendProbe.probe()
        chatBackendStatus = status
    }

    /// The limits the History card's picker offers: the standard ones, plus
    /// a stored value that is not one of them, so the menu can show it.
    var historyLimitChoices: [Int] {
        let limit = settings.historyLimit
        var choices = QuickHistoryStore.limitOptions
        if limit > 0, !choices.contains(limit) {
            choices.append(limit)
            choices.sort()
        }
        return choices
    }

    /// Settings › History › Chats to keep. A lower limit prunes the oldest
    /// unpinned chats at once, in memory and on disk; pinned chats stay.
    func setHistoryLimit(_ limit: Int) {
        guard limit > 0 else { return }
        updateSettings { $0.historyLimit = limit }
        history = QuickHistoryStore.bounded(history, limit: limit)
        guard settings.historyEnabled, let historyFileURL else { return }
        QuickHistoryStore.save(history, limit: limit, to: historyFileURL)
    }
}
