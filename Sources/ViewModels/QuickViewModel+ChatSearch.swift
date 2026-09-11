import Foundation

/// The chat lists' search: the Chats catalog, Recent Chats (`⌘P`), and the
/// AI Chat rail read their rows through `chatItems(matching:)`, which lands
/// here. One engine (`ChatSearch`), one index kept per view model, and one
/// cached answer per query, so a render that reads the rows five times
/// searches once (spec 4.1, 4.7).
extension QuickViewModel {
    /// Rows that get a snippet: only the first rows of a result list are
    /// on screen, so only they pay for one.
    static let chatSnippetRowLimit = 20

    /// The rows for `query`: every chat in `QuickHistoryStore.ordered`
    /// order with no query; with one, the chats that match every term, best
    /// first, the first `chatSnippetRowLimit` rows with a snippet when the
    /// first term was found in their text.
    func searchedChatItems(matching query: String) -> [LauncherCatalogItem] {
        let index = chatSearchIndex
        let titleContext = chatTitleContext
        if index.titleContext != titleContext { index.titleContext = titleContext }
        let key = ChatSearchIndex.RowKey(
            query: query,
            history: history,
            titleContext: titleContext,
            revision: index.revision
        )
        if let rows = index.cachedRows(for: key) { return rows }

        let parsed = ChatSearchQuery(query)
        let rows: [LauncherCatalogItem]
        if parsed.isEmpty {
            // No search yet: fold the text now (or start the first build
            // off the main actor), so it is ready when a query is typed.
            index.update(history, title: title(of:))
            rows = QuickHistoryStore.ordered(history).map { conversationItem($0) }
        } else {
            let ranked = QuickHistoryStore.matching(history, query: query, title: title(of:), index: index)
            rows = ranked.enumerated().map { position, conversation in
                let snippet = position < Self.chatSnippetRowLimit
                    ? chatSnippet(for: conversation, query: parsed, index: index)
                    : nil
                return conversationItem(conversation, snippet: snippet)
            }
        }
        index.storeRows(rows, for: key)
        return rows
    }

    /// Where the first term of `query` was found in `conversation`, as a
    /// row's snippet line. Nil for a title hit.
    private func chatSnippet(
        for conversation: QuickConversation,
        query: ChatSearchQuery,
        index: ChatSearchIndex
    ) -> ChatSnippet? {
        let source = ChatSearchSource(
            conversation,
            title: title(of: conversation),
            attachments: ChatSearchSource.attachments(in: conversation)
        )
        return ChatSearch.snippet(document: index.document(for: source), source: source, query: query)
    }

    /// What a chat's title depends on besides the chat: the saved-prompt
    /// prefix and aliases (`title(of:)` drops a real alias).
    private var chatTitleContext: String {
        ([settings.savedPromptPrefix] + settings.savedPrompts.map(\.alias)).joined(separator: "\u{1}")
    }
}
