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

    /// Drops the tool backends this Mac does not have, so a model is never
    /// offered a tool that can only fail: Memory and Tasks need the `recall`
    /// CLI. The app calls it
    /// once at launch with the probe's answer; a backend installed later is
    /// picked up on the next launch.
    func dropMissingChatBackends(_ status: ChatBackendStatus) {
        if !status.recallFound { memoryService = nil }
    }

}
