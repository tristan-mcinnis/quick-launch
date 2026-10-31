import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    /// `⌘⇧M`: expand or collapse the newest long message in the transcript,
    /// for a reader who never leaves the composer. The control under the
    /// message carries the same key caps.
    /// `⇧⌘M`: expand or collapse the newest long message in the transcript,
    /// for a reader who never leaves the composer. The control under the
    /// message carries the owner's resolved caps (`shortcutKeyCaps`), so a
    /// rebind reaches both the key and the caps under the message.
    static let transcriptCollapseShortcut: KeyShortcut = .commandShift("m")

    /// What the thread draws for one message. Only a user turn collapses;
    /// an answer always shows in full, as in Raycast.
    func collapseState(for message: QuickMessage) -> MessageCollapseState {
        MessageCollapseState(
            text: message.content,
            isExpanded: expandedTranscriptMessageIDs.contains(message.id),
            collapses: message.role == .user
        )
    }

    /// The newest turn that has a Show more control, the one the keyboard
    /// shortcut acts on. The thread shows every message.
    var keyboardToggleMessageID: UUID? {
        conversationMessages.last { collapseState(for: $0).isCollapsible }?.id
    }

    /// Whether this turn's Show more or Collapse control shows the `⇧⌘M`
    /// key caps: only the turn the key acts on does, so an older pill never
    /// names a key that would fold a different message.
    func showsCollapseShortcut(for message: QuickMessage) -> Bool {
        message.id == keyboardToggleMessageID
    }

    /// Toggles one collapsible turn between collapsed and expanded and asks
    /// the thread to bring its head to the top of the view, so the reader
    /// lands on the start of what opened or next to Show more after it
    /// folds. Returns `false` when the id is not a collapsible turn of the
    /// open conversation.
    @discardableResult
    func toggleTranscriptMessage(_ id: UUID) -> Bool {
        guard let message = conversationMessages.first(where: { $0.id == id }),
              collapseState(for: message).isCollapsible
        else { return false }
        if expandedTranscriptMessageIDs.contains(id) {
            expandedTranscriptMessageIDs.remove(id)
        } else {
            expandedTranscriptMessageIDs.insert(id)
        }
        scrollThread(.messageTop(id))
        noteInteraction()
        return true
    }

    /// Asks the thread to scroll. Moving up (a page, the top, a message's
    /// head) stops following the newest text at once, so a streaming
    /// answer does not pull the reader back before the view has moved;
    /// the bottom starts following again.
    func scrollThread(_ target: ThreadScrollRequest.Target) {
        switch target {
        case .bottom: isThreadFollowingBottom = true
        case .top, .pageUp, .messageTop, .messageOffset: isThreadFollowingBottom = false
        case .pageDown: break
        }
        threadScrollRequest = ThreadScrollRequest(
            target: target,
            revision: (threadScrollRequest?.revision ?? 0) + 1
        )
    }

    /// A new question, or another chat: the thread follows the newest text
    /// again, wherever the reader had scrolled.
    func followThreadBottom() {
        if !isThreadFollowingBottom { isThreadFollowingBottom = true }
    }

    /// The thread's view reported where it sits. When the view moved (the
    /// reader scrolled, or a scroll the thread made landed), within
    /// `threadFollowThreshold` of the bottom it follows the newest text and
    /// further up it stays where the reader is. Text landing under a still
    /// view (`moved` false) changes the distance, never the choice.
    func threadDidScroll(distanceFromBottom: CGFloat, moved: Bool = true) {
        lastThreadDistanceFromBottom = distanceFromBottom
        let follows = distanceFromBottom <= Self.threadFollowThreshold
        // Nothing below the view is always "at the bottom", moved or not: room
        // reserved under a new question can settle without a scroll event.
        guard moved || follows else { return }
        if isThreadFollowingBottom != follows { isThreadFollowingBottom = follows }
    }

    /// The "Latest" chip: the reader scrolled up from a thread with
    /// something below. Clicking it, or `⌘↓`, goes back to the newest text.
    var showsJumpToLatest: Bool {
        guard isQuickAIPresented, !isRecentChatsPresented, !isThreadFollowingBottom else { return false }
        return !conversationMessages.isEmpty || isStreaming || !output.isEmpty
    }

    /// The keys that move the thread from the composer: PageUp and
    /// PageDown, or `⌥↑` and `⌥↓`, by a page; `⌘↑` and `⌘↓` to the top and
    /// the bottom. Only on the thread, with no chooser, card, list, or pane
    /// over it; elsewhere the keys keep their meaning.
    enum ThreadKey: Sendable {
        case up
        case down
        case pageUp
        case pageDown
    }

    @discardableResult
    func handleThreadKey(_ key: ThreadKey, command: Bool, option: Bool) -> Bool {
        guard isQuickAIPresented, !isRecentChatsPresented,
              !isTransformChooserPresented, !isModelChooserPresented, !isAddContextMenuPresented,
              !isActionPalettePresented, !isItemActionPanePresented
        else { return false }
        let target: ThreadScrollRequest.Target
        switch key {
        case .pageUp: target = .pageUp
        case .pageDown: target = .pageDown
        case .up where command: target = .top
        case .down where command: target = .bottom
        case .up where option: target = .pageUp
        case .down where option: target = .pageDown
        case .up, .down: return false
        }
        scrollThread(target)
        return true
    }

    /// Plain `↑` or `↓` in the Quick AI composer, once the question card,
    /// the choosers, and Recent Chats have had their turn. On an empty
    /// composer `↑` puts the last question back in it to edit and send
    /// again, as in Raycast, and `↓` does nothing; with text in the field
    /// both keys are the field's. Chats switch with `⌘[` and `⌘]`.
    @discardableResult
    func handleComposerArrow(_ delta: Int) -> Bool {
        guard isQuickAIPresented, input.isEmpty else { return false }
        if delta < 0 { recallLastQuestion() }
        return true
    }

    /// The last question asked on the surface, as it was typed when this
    /// session knows it, else as the thread holds it.
    var lastAskedQuestion: String? {
        if let lastQuestion, !lastQuestion.isEmpty { return lastQuestion }
        let question = conversationMessages.last { $0.role == .user }?.content
        return question?.isEmpty == false ? question : nil
    }

    private func recallLastQuestion() {
        guard let question = lastAskedQuestion else { return }
        input = question
        requestInputFocus()
    }
}
