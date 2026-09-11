/// The chat entries of the launcher's ⋯ menu, in the order it lists them.
/// "Chat" is Quick AI's; "AI Chat" names only the window.
enum ChatMenuEntry: String, CaseIterable, Identifiable, Sendable {
    /// Quick AI on an empty chat. The chat on the surface stays in history.
    case newChat
    /// Recent Chats inside Quick AI, as `⌘P` opens it.
    case recentChats
    /// The AI Chat window on a new or the last chat.
    case openAIChat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newChat: "New Chat"
        case .recentChats: "Recent Chats"
        case .openAIChat: "Open AI Chat"
        }
    }

    var systemImage: String {
        switch self {
        case .newChat: ResultAction.newChat.systemImage
        case .recentChats: ResultAction.recentChats.systemImage
        case .openAIChat: ResultAction.continueInAIChat.systemImage
        }
    }

    /// The key that does the same from root search, drawn after the title.
    /// `⌘N` is the thread's key only, so New Chat names none.
    var shortcut: KeyShortcut? {
        switch self {
        case .recentChats: ResultAction.recentChats.shortcut
        case .newChat, .openAIChat: nil
        }
    }

    /// The menu item's text: the title, then the key caps, as the
    /// screenshot entries of the same menu draw theirs.
    var menuTitle: String {
        guard let shortcut else { return title }
        return "\(title)  \(shortcut.keyCaps.joined())"
    }
}
