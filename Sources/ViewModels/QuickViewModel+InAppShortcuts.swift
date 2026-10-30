import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// In-app shortcuts.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - In-app shortcuts

    /// The live in-app shortcut table, read through this view model's own
    /// settings: the router, the footer hints, the palette rows, the key-cap
    /// badges and the tooltips all resolve through it, so a rebind in Settings
    /// redraws every surface at once. The two AppKit surfaces that have no
    /// view model of their own (the launcher panel, the AI Chat menu) are
    /// handed these same bindings by their owner.
    var shortcuts: ShortcutBindings { settings.shortcuts }

    /// The key an action answers to now, for caps and help text.
    func shortcut(for action: ShortcutAction) -> KeyShortcut {
        shortcuts.keyShortcut(for: action)
    }

    func shortcutKeyCaps(for action: ShortcutAction) -> [String] {
        shortcuts.keyCaps(for: action)
    }

    func shortcutDisplayName(for action: ShortcutAction) -> String {
        shortcuts.displayName(for: action)
    }

    /// The caps as one label, for a tooltip: `⌥⌘K`.
    func shortcutLabel(for action: ShortcutAction) -> String {
        shortcuts.displayName(for: action)
    }

    /// Why a key may not be bound to an action, given every other setting
    /// that owns a key. Nil means it may.
    func shortcutConflict(for action: ShortcutAction, candidate: ActionHotkey) -> String? {
        settings.shortcutConflict(for: action, candidate: candidate)
    }

    /// Rebinds one action, persists it, and tells the AppKit layers (the AI
    /// Chat menu rebuilds its key equivalents). A collision refuses the change
    /// and returns its message for the row to show; nil means it was applied.
    /// Nothing process-wide is written: the resolved table is derived from
    /// these settings, and every reader holds the settings it belongs to.
    @discardableResult
    func setShortcut(_ hotkey: ActionHotkey?, for action: ShortcutAction) -> String? {
        var updated = settings
        if let conflict = updated.setShortcut(hotkey, for: action) { return conflict }
        settings = updated
        settings.save()
        NotificationCenter.default.post(name: .shortcutBindingsChanged, object: nil)
        return nil
    }

    /// Back to the built-in key for one action.
    func resetShortcut(_ action: ShortcutAction) {
        setShortcut(nil, for: action)
    }

    /// Back to every built-in key.
    func resetAllShortcuts() {
        var updated = settings
        updated.resetAllShortcuts()
        settings = updated
        settings.save()
        NotificationCenter.default.post(name: .shortcutBindingsChanged, object: nil)
    }
    /// Every write tells the other view on the store (`QuickStore`), so its
    /// open chat follows at once.
    var history: [QuickConversation] {
        get { store.history }
        set {
            store.history = newValue
            store.historyDidChange(by: self)
        }
    }
    /// Whether chats are kept at all. With the canonical archive present the
    /// answer is always yes: the legacy "Keep chat history" switch no longer
    /// decides what is read or kept, and its key survives only as rollback
    /// data and as the bound on the legacy cache. Without an archive (the
    /// legacy store, and tests that keep history in memory) the old switch
    /// still decides, because then that store is all there is.
    var canonicalHistoryActive: Bool { chatArchive != nil || settings.historyEnabled }
    /// Ids reserved for the durable submission of one question.
    struct PendingSubmission: Sendable {
        var conversationID: UUID
        var messageID: UUID
        var attachments: [AttachmentContent]
        var startedAt: Date
    }
    /// The one ⌘K layer that can sit above the launcher. Exclusive by
    /// construction: a palette and a pane can never both be open.
    enum PresentedLayer: Equatable, Sendable {
        case actionPalette
        case applicationPane
        case catalogPane
    }
    var isActionPalettePresented: Bool {
        get { presentedLayer == .actionPalette }
        set { presentedLayer = newValue ? .actionPalette : (presentedLayer == .actionPalette ? nil : presentedLayer) }
    }
    var isApplicationActionPanePresented: Bool {
        get { presentedLayer == .applicationPane }
        set { presentedLayer = newValue ? .applicationPane : (presentedLayer == .applicationPane ? nil : presentedLayer) }
    }
    var isCatalogActionPanePresented: Bool {
        get { presentedLayer == .catalogPane }
        set { presentedLayer = newValue ? .catalogPane : (presentedLayer == .catalogPane ? nil : presentedLayer) }
    }
    /// Where the thread should scroll, and a revision so asking twice for
    /// the same place scrolls twice. Set by Show more and Collapse (the
    /// message's head to the top), by PageUp/PageDown and ⌥↑/⌥↓ (a page),
    /// by ⌘↑/⌘↓ (the ends), and by the "Latest" chip; the thread observes it.
    struct ThreadScrollRequest: Equatable, Sendable {
        enum Target: Equatable, Sendable {
            case messageTop(UUID)
            /// Find in Chat: the hit `y` points below the message's head,
            /// as the thread measured it, a third of the way down the view.
            case messageOffset(UUID, CGFloat)
            case pageUp
            case pageDown
            case top
            case bottom
        }
        let target: Target
        let revision: Int

        init(target: Target, revision: Int) {
            self.target = target
            self.revision = revision
        }

        /// Show more and Collapse: the message's head at the top.
        init(messageID: UUID, revision: Int) {
            self.init(target: .messageTop(messageID), revision: revision)
        }

        var messageID: UUID? {
            if case .messageTop(let id) = target { return id }
            return nil
        }
    }
    /// The newest attachment. Setting appends; setting nil clears all.
    var pendingImage: QuickImageAttachment? {
        get { pendingImages.last }
        set {
            if let newValue {
                if !pendingImages.contains(newValue) { pendingImages.append(newValue) }
            } else {
                pendingImages.removeAll()
            }
        }
    }
    enum InputMode: Equatable, Sendable {
        case caffeinateUntil
        case renameChat(UUID)
        /// A clipboard entry is asking for a new name; `itemID` identifies it.
        case renameClipboard(String)
        /// A snippet is asking for one `{argument}`; `pendingSnippetInsertion`
        /// holds which, and what to do once every slot is answered.
        case snippetArgument
        /// A house command is asking for its one `text` argument;
        /// `pendingHouseCommandText` holds which command is waiting.
        case houseCommandArgument
    }

    /// How an expanded snippet reaches the user: the same three moves every
    /// launcher row already offers.
    enum SnippetInsertMode: Equatable, Sendable {
        case paste
        case copy
        case copyAndPaste
    }

    /// A snippet waiting on its `{argument}` slots. Each Return fills the
    /// next one, in the order the template names them; the insertion runs
    /// when the last is answered.
    struct PendingSnippetInsertion: Equatable, Sendable {
        let item: LauncherCatalogItem
        let arguments: [SnippetArgument]
        var collected: [String]
        let mode: SnippetInsertMode
        /// The row's ⌘↩ closes the overlay once the text is out; ⌘C inside a
        /// catalog leaves it open. Either way the prompt runs first.
        var dismissesOverlay = false

        var currentArgument: SnippetArgument? {
            arguments.indices.contains(collected.count) ? arguments[collected.count] : nil
        }
    }

}
