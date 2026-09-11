/// Actions on the Quick AI window or the AI Chat window itself rather than
/// on an answer. They sit in the `⌘K` palette while the surface is up,
/// after the answer actions. Each window offers its own: Quick AI offers
/// Reset Quick AI Size; AI Chat offers the chat list, find, and Keep on Top
/// (`AIChatWindowModel.windowSurfaceActions`).
enum QuickAISurfaceAction: String, CaseIterable, Identifiable, Sendable {
    /// Back to the standard 750 × 475 after the user dragged the window
    /// larger. Offered only when the size is not the standard one.
    case resetSize
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resetSize: "Reset Quick AI Size"
        case .showChatList: "Show Chat List"
        case .hideChatList: "Hide Chat List"
        case .findInChat: "Find in Chat"
        case .keepOnTop: "Keep on Top"
        case .stopKeepingOnTop: "Stop Keeping on Top"
        }
    }

    var detail: String {
        switch self {
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
        }
    }

    /// Keep on Top's glyph, in the palette and in the AI Chat header while
    /// the window is kept on top.
    static let keepOnTopSymbol = "square.3.layers.3d.top.filled"

    var systemImage: String {
        switch self {
        case .resetSize: "arrow.down.right.and.arrow.up.left"
        case .showChatList, .hideChatList: "sidebar.left"
        case .findInChat: "magnifyingglass"
        // Layers with the top one filled: "in front". Not the pin, which
        // marks a pinned chat.
        case .keepOnTop: Self.keepOnTopSymbol
        case .stopKeepingOnTop: "square.3.layers.3d.slash"
        }
    }

    /// The key that does the same, drawn as caps in the palette row.
    var shortcut: KeyShortcut? {
        switch self {
        case .resetSize, .keepOnTop, .stopKeepingOnTop: nil
        case .showChatList, .hideChatList: AIChatWindowModel.chatListShortcut
        case .findInChat: AIChatWindowModel.findShortcut
        }
    }
}
