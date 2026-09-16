/// Actions on the Quick AI window or the AI Chat window itself rather than
/// on an answer. They sit in the `⌘K` palette while the surface is up,
/// after the answer actions. Each window offers its own: Quick AI offers
/// Reset Quick AI Size; AI Chat offers the chat list, find, and Keep on Top
/// (`AIChatWindowModel.windowSurfaceActions`). Both offer Copy Message and
/// Capture Message to Memory, which act on any message of the chat.
enum QuickAISurfaceAction: String, CaseIterable, Identifiable, Sendable {
    /// Back to the standard 750 × 475 after the user dragged the window
    /// larger. Offered only when the size is not the standard one.
    case resetSize
    /// The composer’s plus menu: files, links, and captured context.
    case attach
    /// Shared provider choice for explicit searches and model tool calls.
    case searchSettings
    /// AI Chat: slide the chat list in (`⌘\`).
    case showChatList
    /// AI Chat: slide the chat list out (`⌘\`).
    case hideChatList
    /// AI Chat: the find bar (`⌘F`).
    case findInChat
    /// AI Chat: keep the window above other apps' windows. Remembered.
    case keepOnTop
    /// AI Chat: back to a normal window level.
    case stopKeepingOnTop
    /// Copy any question or answer of the chat: a list in the palette.
    case copyMessage
    /// Send any question or answer of the chat to `recall remember`.
    case captureMessage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .attach: "Attach…"
        case .searchSettings: "Search Provider…"
        case .resetSize: "Reset Quick AI Size"
        case .showChatList: "Show Chat List"
        case .hideChatList: "Hide Chat List"
        case .findInChat: "Find in Chat"
        case .keepOnTop: "Keep on Top"
        case .stopKeepingOnTop: "Stop Keeping on Top"
        case .copyMessage: "Copy Message…"
        case .captureMessage: "Capture Message to Memory…"
        }
    }

    var detail: String {
        switch self {
        case .attach:
            "Add a file, link, selection, or screenshot"
        case .searchSettings:
            "Choose the search source used by all chats"
        case .resetSize:
            "Back to \(Int(QuickAISize.standard.width)) × \(Int(QuickAISize.standard.height))"
        case .showChatList, .hideChatList:
            "Pinned and recent chats beside the thread"
        case .findInChat:
            "Search the messages of this chat"
        case .keepOnTop:
            "Stay above other windows"
        case .stopKeepingOnTop:
            "Back to a normal window"
        case .copyMessage:
            "Any question or answer in this chat"
        case .captureMessage:
            "Send any question or answer to recall"
        }
    }

    /// Keep on Top's glyph, in the palette and in the AI Chat header while
    /// the window is kept on top.
    static let keepOnTopSymbol = "square.3.layers.3d.top.filled"

    var systemImage: String {
        switch self {
        case .attach: "plus"
        case .searchSettings: "magnifyingglass"
        case .resetSize: "arrow.down.right.and.arrow.up.left"
        case .showChatList, .hideChatList: "sidebar.left"
        case .findInChat: "magnifyingglass"
        // Layers with the top one filled: "in front". Not the pin, which
        // marks a pinned chat.
        case .keepOnTop: Self.keepOnTopSymbol
        case .stopKeepingOnTop: "square.3.layers.3d.slash"
        case .copyMessage: ResultAction.copy.systemImage
        case .captureMessage: ResultAction.captureToMemory.systemImage
        }
    }

    /// The key that does the same, drawn as caps in the palette row.
    var shortcut: KeyShortcut? {
        switch self {
        case .attach: QuickViewModel.attachShortcut
        case .resetSize, .keepOnTop, .stopKeepingOnTop, .copyMessage, .captureMessage, .searchSettings: nil
        case .showChatList, .hideChatList: AIChatWindowModel.chatListShortcut
        case .findInChat: AIChatWindowModel.findShortcut
        }
    }

    /// The registry action this row's key belongs to, so a view can draw the
    /// resolved caps rather than the built-in default. Nil when the row has
    /// no key of its own.
    var shortcutAction: ShortcutAction? {
        switch self {
        case .attach: .attachMenu
        case .showChatList, .hideChatList: .chatList
        case .findInChat: .findInChat
        case .resetSize, .keepOnTop, .stopKeepingOnTop, .copyMessage, .captureMessage, .searchSettings:
            nil
        }
    }
}
