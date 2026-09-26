import Foundation

/// The Chief of Staff's pinned conversation, on the ordinary chat pipeline
/// with one backing chat (`ChiefOfStaffModel.conversationID`). While `cos` is
/// installed, every message there is answered by `cos tell`, which records
/// both turns in its thread itself (`ChiefOfStaffModel.tellService`); only
/// without it does a model answer, and that turn goes to the thread through
/// `cos append`. The backing chat never shows in a chat list; the pinned row
/// is its one way in.
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
        let branch = currentConversation?.id == id ? currentConversation : nil
        guard let pinned = chiefOfStaff?.systemMessage(
            forChat: id,
            discussing: branch?.cosCard,
            made: branch?.messages.compactMap(\.cosTell?.card) ?? []
        ) else { return assistant }
        return [pinned, assistant].compactMap { $0 }.joined(separator: "\n\n")
    }

    /// A Reply typed in a notification: the pinned chat asks it.
    func sendChiefOfStaffReply(_ text: String) {
        openChiefOfStaffChat()
        input = text
        submitFromComposer()
    }

    // MARK: - Branches

    /// The card the open chat is a branch about, while the Chief of Staff
    /// is there.
    var discussedCardID: String? {
        guard let chiefOfStaff, chiefOfStaff.isAvailable else { return nil }
        return currentConversation?.cosCard
    }

    /// A `cos tell` is running for the open branch.
    var isTellingChiefOfStaff: Bool {
        currentConversation.map { chiefOfStaff?.telling[$0.id] != nil } ?? false
    }

    /// The newest branch about `card` among the saved chats.
    func branchConversation(for card: String) -> QuickConversation? {
        history.filter { $0.cosCard == card }.max { $0.updatedAt < $1.updatedAt }
    }

    /// Every branch, newest first.
    var branchConversations: [QuickConversation] {
        history.filter { $0.cosCard != nil }.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// A message was asked in branch `conversation`: it also goes to `cos
    /// tell` about the card, and the first one links the branch to it.
    func branchDidAsk(_ conversation: QuickConversation, text: String) {
        guard let chiefOfStaff, chiefOfStaff.isAvailable, let card = conversation.cosCard else { return }
        if chiefOfStaff.onTold == nil {
            chiefOfStaff.onTold = { [weak self] chat, outcome in self?.chiefOfStaffTold(outcome, inChat: chat) }
        }
        if conversation.messages.filter({ $0.role == .user }).count == 1 {
            chiefOfStaff.send(.linkBranch(card: card, branch: conversation.id, title: title(of: conversation)))
        }
        chiefOfStaff.send(.tell(text: text, card: card, chat: conversation.id))
    }

    /// A branch's `cos tell` came back for chat `id`: a card it made joins
    /// the branch under the answer (after the answer, when one is still
    /// streaming), with the keyboard on it while the draft is empty. An
    /// answer stays in the thread's branch turns; the chat model answers here.
    func chiefOfStaffTold(_ outcome: Result<CosTellReply, any Error>, inChat id: UUID) {
        switch outcome {
        case .success(let reply):
            guard reply.kind == .proposal, reply.card != nil else { return }
            if isStreaming, currentConversation?.id == id {
                deferredChiefOfStaffReplies.append((id, reply))
                return
            }
            if let card = appendToldReply(reply, toChat: id), currentConversation?.id == id, input.isEmpty {
                chiefOfStaff?.focusTold(card)
            }
        case .failure(let error):
            guard currentConversation?.id == id else { return }
            errorMessage = "The Chief of Staff did not take it: \(error.localizedDescription)"
        }
    }

    /// The replies that waited for a stream to finish, into their chats.
    /// Returns the last card made in the open chat.
    @discardableResult
    func flushDeferredChiefOfStaffReplies() -> String? {
        let replies = deferredChiefOfStaffReplies
        deferredChiefOfStaffReplies = []
        var made: String?
        for (id, reply) in replies {
            if let card = appendToldReply(reply, toChat: id), currentConversation?.id == id { made = card }
        }
        return made
    }

    /// A proposal reply as the Chief of Staff's turn, named, with its card.
    private func appendToldReply(_ reply: CosTellReply, toChat id: UUID) -> String? {
        guard let card = reply.card else { return nil }
        appendMessage(
            QuickMessage(role: .assistant, content: "Chief of Staff: " + reply.text, cosTell: CosTold(card: card)),
            toChat: id
        )
        return card
    }

    /// The merge-back line of branch `conversation`: the done card's
    /// headline (else the newest card's, else the model's last answer),
    /// and how many actions its cards ran.
    func branchSummary(of conversation: QuickConversation) -> String? {
        guard let chiefOfStaff, conversation.cosCard != nil,
              conversation.messages.contains(where: { $0.role == .user }) else { return nil }
        let made = conversation.messages.compactMap(\.cosTell?.card).compactMap { chiefOfStaff.proposal($0) }
        let done = made.filter { $0.status == .done }
        let actions = done.reduce(0) { $0 + $1.actions.count }
        let answer = conversation.messages.last { $0.role == .assistant && $0.cosTell == nil }?.content
        let line = done.last?.headline ?? made.last?.headline ?? answer.map(Self.oneLine) ?? title(of: conversation)
        return "Discussed: \(line) · \(actions) \(actions == 1 ? "action" : "actions") done"
    }

    /// The first sentence of an answer, plain, cut at a word near 100
    /// characters.
    nonisolated static func oneLine(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let first = plain.split(whereSeparator: \.isNewline).first.map(String.init) ?? plain
        var sentence = first.range(of: ". ").map { String(first[..<$0.lowerBound]) } ?? first
        sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        guard sentence.count > 100 else { return sentence }
        let cut = sentence.prefix(100)
        return (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
    }

    /// Branch `id` merges back: one line under its card, unless nothing
    /// was said since the last one (`force` writes it anyway, after a Do it).
    func mergeBranch(_ id: UUID, force: Bool = false) {
        guard let chiefOfStaff,
              let conversation = currentConversation?.id == id ? currentConversation : history.first(where: { $0.id == id }),
              let card = conversation.cosCard, let text = branchSummary(of: conversation) else { return }
        let turns = conversation.messages.count
        if !force, chiefOfStaff.lastSummary(of: id)?.turns == turns { return }
        chiefOfStaff.send(.branchSummary(card: card, branch: id, text: text, turns: turns))
    }

    /// Do it ran on card `id`: the branch that made it merges back.
    func chiefOfStaffCardDone(_ id: String) {
        let owner = ([currentConversation].compactMap { $0 } + history)
            .first { $0.cosCard != nil && $0.messages.contains { $0.cosTell?.card == id } }
        if let owner { mergeBranch(owner.id, force: true) }
    }
}
