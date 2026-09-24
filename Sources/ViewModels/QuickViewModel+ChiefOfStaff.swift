import Foundation

/// The Chief of Staff's pinned conversation, on the ordinary chat pipeline.
/// Its questions run through this view model's providers, tools, and
/// attachments on one backing chat (`ChiefOfStaffModel.conversationID`),
/// with the Chief of Staff's system message on every request, and each
/// answered turn goes to the `cos` thread through `cos append`. The backing
/// chat never shows in a chat list; the pinned row is its one way in.
extension QuickViewModel {
    /// The root-search command that opens the pinned conversation.
    static let chiefOfStaffCommandID = "chiefofstaff.open"

    /// The launcher row: "Chief of Staff", its waiting count as the detail,
    /// found by `cos` too.
    var chiefOfStaffCommand: LauncherCatalogItem? {
        guard let chiefOfStaff, chiefOfStaff.isAvailable, chiefOfStaffOpener != nil else { return nil }
        return LauncherCatalogItem(
            kind: .command,
            itemID: Self.chiefOfStaffCommandID,
            title: ChiefOfStaffModel.title,
            detail: "\(chiefOfStaff.summary) · Open the pinned conversation in AI Chat",
            value: Self.chiefOfStaffCommandID,
            keywords: "cos chief of staff proposals cards waiting inbox"
        )
    }

    /// Whether the open chat is the pinned Chief of Staff conversation.
    var isChiefOfStaffChatOpen: Bool {
        currentConversation?.id == ChiefOfStaffModel.conversationID
    }

    /// The launcher row, `⌘K`, or a notification: the AI Chat window on the
    /// pinned conversation.
    func openChiefOfStaff() {
        guard let chiefOfStaffOpener else { return }
        input = ""
        overlayPresenter.dismissOverlay()
        chiefOfStaffOpener(nil)
    }

    /// Opens the backing chat here: the saved one, or a new one on DeepSeek
    /// Flash when that model is offered (else the Quick AI default), with
    /// the read-only tools. A stream on another chat stops first and keeps
    /// what arrived, as leaving any chat does.
    func openChiefOfStaffChat() {
        let id = ChiefOfStaffModel.conversationID
        guard !isChiefOfStaffChatOpen else {
            isQuickAIPresented = true
            requestInputFocus()
            return
        }
        if isStreaming {
            cancel()
            persistCurrentConversation()
        }
        if history.contains(where: { $0.id == id }) {
            continueConversation(itemID: id.uuidString)
        } else {
            startNewConversation()
            // A Clear History tombstones every id; the pinned chat starts
            // over under its own.
            store.deletedChatIDs.remove(id)
            let route = chiefOfStaffRoute
            currentConversation = QuickConversation(
                id: id,
                providerID: route?.providerID ?? UUID(),
                model: route?.model ?? "",
                customTitle: ChiefOfStaffModel.title,
                enabledTools: ChiefOfStaffModel.tools
            )
            pendingChatTools = nil
            pendingModelChoice = nil
        }
        isQuickAIPresented = true
        requestInputFocus()
    }

    /// DeepSeek Flash when a DeepSeek provider offers it, else the Quick AI
    /// default provider and model.
    var chiefOfStaffRoute: ChatModelChoice? {
        if let deepSeek = settings.providers.first(where: { $0.id == InferenceProvider.deepSeekID }),
           deepSeek.models.contains(InferenceProvider.deepSeekDefaultModel)
            || deepSeek.selectedModel == InferenceProvider.deepSeekDefaultModel,
           modelPreferences.isEnabled(providerID: deepSeek.id, model: InferenceProvider.deepSeekDefaultModel) {
            return ChatModelChoice(providerID: deepSeek.id, model: InferenceProvider.deepSeekDefaultModel)
        }
        guard let provider = settings.quickAIProvider else { return nil }
        return ChatModelChoice(providerID: provider.id, model: provider.selectedModel)
    }

    /// The Chief of Staff's system message for a request in chat `id`, put
    /// before an assistant's own when both apply.
    func pinnedSystemMessage(forChat id: UUID, assistant: String?) -> String? {
        let discussing = currentConversation?.id == id ? currentConversation?.cosCard : nil
        guard let pinned = chiefOfStaff?.systemMessage(forChat: id, discussing: discussing) else { return assistant }
        return [pinned, assistant].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// A Reply typed in a notification: the pinned chat asks it.
    func sendChiefOfStaffReply(_ text: String) {
        openChiefOfStaffChat()
        input = text
        submitFromComposer()
    }

    // MARK: - Discuss

    /// The card the open chat discusses, while the Chief of Staff is there.
    var discussedCardID: String? {
        guard let chiefOfStaff, chiefOfStaff.isAvailable else { return nil }
        return currentConversation?.cosCard
    }

    /// A Tell Chief of Staff is running for the open chat.
    var isTellingChiefOfStaff: Bool {
        currentConversation.map { chiefOfStaff?.telling.contains($0.id) == true } ?? false
    }

    /// Tell Chief of Staff (⇧⌘↩) in a Discuss chat: the draft, else the last
    /// question, goes to `cos tell` about the card. The reply joins the chat
    /// as the Chief of Staff's, with the card it made drawn under it and the
    /// keyboard on that card.
    func tellChiefOfStaff() {
        guard let chiefOfStaff, let card = discussedCardID, let chat = currentConversation,
              !chiefOfStaff.telling.contains(chat.id) else { return }
        let draft = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let text: String
        if !draft.isEmpty {
            text = draft
            input = ""
            appendMessage(QuickMessage(role: .user, content: draft), toChat: chat.id)
        } else if let last = chat.messages.last(where: { $0.role == .user }) {
            text = CosTellReply.message(last.content, attachments: last.attachmentRefs)
        } else {
            errorMessage = "Type what to tell the Chief of Staff first."
            return
        }
        errorMessage = nil
        chiefOfStaff.send(.tell(text: text, card: card, chat: chat.id))
    }

    /// A Tell Chief of Staff came back for chat `id`: the reply joins it,
    /// and the keyboard goes onto the card it made while the chat is open.
    func chiefOfStaffTold(_ outcome: Result<CosTellReply, any Error>, inChat id: UUID) {
        switch outcome {
        case .success(let reply):
            let made = reply.kind == .proposal ? reply.card : nil
            // Named, so it never reads as this chat's model talking.
            appendMessage(
                QuickMessage(role: .assistant, content: "Chief of Staff: " + reply.text, cosTell: CosTold(card: made)),
                toChat: id
            )
            if let made, currentConversation?.id == id {
                chiefOfStaff?.focusTold(made)
            }
        case .failure(let error):
            guard currentConversation?.id == id else { return }
            errorMessage = "The Chief of Staff did not take it: \(error.localizedDescription)"
        }
    }
}
