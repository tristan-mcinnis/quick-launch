import CoreFoundation

/// Layout of the `⌘J` conversation view. It stays inside the one overlay
/// window, so these are the sizes the panel resizes to and the ones the view
/// draws with.
enum ConversationViewLayout {
    /// Wider than the answer surface: the thread and the chat list sit side
    /// by side.
    static let panelWidth: CGFloat = 940

    /// The chat history rail beside the thread.
    static let historyWidth: CGFloat = 260

    /// The scrolling thread and rail block. The composer row and the footer
    /// are added around it by the panel height below.
    static let bodyHeight: CGFloat = 470

    /// Whole window height while the conversation view is open.
    static var panelHeight: CGFloat {
        House.Control.input + House.hairline + bodyHeight
    }
}
