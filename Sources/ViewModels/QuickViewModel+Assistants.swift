import Foundation

/// One row of Change Assistant: an assistant, or the plain chat (`nil`).
struct AssistantChooserOption: Identifiable, Equatable, Sendable {
    let assistantID: UUID?
    let title: String
    let detail: String

    var id: String { assistantID?.uuidString ?? "plain-chat" }
}

/// The context skills one assistant chat loaded, kept so the chat reads its
/// skill files once. A different chat, assistant, or skill list reloads.
struct AssistantSkillCache: Sendable, Equatable {
    let conversationID: UUID
    let assistantID: UUID
    let refs: [String]
    let skills: [AssistantSkill]
}

/// Assistants: saved prompts with instructions and no command
/// (`SavedPrompt.isAssistant`). Picking one (its `/alias` alone, ⌘K › Change
/// Assistant, or its hotkey) starts or switches the Quick AI chat to it and
/// sends nothing. The chat records the assistant and its tool set; each
/// request then carries the assistant's system message.
extension QuickViewModel {

    /// What Return does in Change Assistant, in its header and the composer.
    static let assistantChooserConfirmTitle = "Use Assistant"

    /// Every assistant among the saved prompts, in their order.
    var assistants: [SavedPrompt] { settings.savedPrompts.filter(\.isAssistant) }

    /// The assistant a chat runs as, while it is still an assistant in the
    /// saved prompts. A deleted one, or one whose instructions were cleared,
    /// leaves a plain chat.
    func assistant(for conversation: QuickConversation) -> SavedPrompt? {
        guard let id = conversation.assistantID else { return nil }
        return settings.savedPrompts.first { $0.id == id && $0.isAssistant }
    }

    /// The assistant of the open chat; the header names it.
    var activeAssistant: SavedPrompt? { currentConversation.flatMap(assistant(for:)) }

    /// Starts or switches the Quick AI chat to `assistant`, or back to a
    /// plain chat for `nil`. Its pinned provider and model become the active
    /// ones (as Change Model does), its tools become the chat's tool set,
    /// and its instructions and skills go with every request from here on.
    /// Nothing is sent. An open chat that has gone stale is replaced by a
    /// new one first, as the next question would replace it.
    func selectAssistant(_ assistant: SavedPrompt?) {
        isAssistantChooserPresented = false
        isActionPalettePresented = false
        actionQuery = ""
        if isStreaming { cancel() }
        if shouldStartNewConversation {
            let typed = input
            startNewConversation()
            input = typed
        }
        // The model is per chat: the assistant's goes on the chat it runs in
        // (or on the one the next question starts), never on a stale chat
        // the line above replaced.
        if let assistant,
           let providerID = assistant.providerID,
           let provider = settings.providers.first(where: { $0.id == providerID }) {
            let model = assistant.model.flatMap { $0.isEmpty ? nil : $0 } ?? provider.selectedModel
            if !model.isEmpty { setActiveModel(providerID: provider.id, model: model) }
        }
        if currentConversation == nil {
            guard let provider = activeProvider, let model = activeModelID, !model.isEmpty else {
                openQuickAI()
                errorMessage = "Choose a provider and model in Settings."
                return
            }
            currentConversation = QuickConversation(providerID: provider.id, model: model)
            pendingModelChoice = nil
        }
        currentConversation?.assistantID = assistant?.id
        currentConversation?.enabledTools = assistant?.enabledTools
        // Tools picked on the empty surface give way to the assistant's.
        pendingChatTools = nil
        currentConversation?.updatedAt = Date()
        if currentConversation?.messages.isEmpty == false { persistCurrentConversation() }
        openQuickAI()
        noteInteraction()
    }

    // MARK: - Change Assistant chooser

    /// The chooser's rows: a plain chat, then every assistant.
    var assistantChooserOptions: [AssistantChooserOption] {
        [AssistantChooserOption(assistantID: nil, title: "No Assistant", detail: "Plain chat")]
            + assistants.map { assistant in
                AssistantChooserOption(
                    assistantID: assistant.id,
                    title: assistant.name,
                    detail: "\(settings.savedPromptPrefix)\(assistant.alias) · \(Self.toolSummary(assistant.enabledTools))"
                )
            }
    }

    /// The tools of an assistant in a few words, for the chooser row.
    static func toolSummary(_ tools: Set<ChatToolKind>?) -> String {
        // Nil is Chat defaults, the name the editor and the Chat card use.
        guard let tools else { return "Chat defaults" }
        let names = ChatToolKind.allCases.filter(tools.contains).map(\.displayName)
        return names.isEmpty ? "No tools" : names.joined(separator: ", ")
    }

    func openAssistantChooser() {
        // The question card owns ↑↓ and Return while it waits.
        guard !isAskQuestionActive, !assistants.isEmpty else { return }
        let options = assistantChooserOptions
        assistantChooserIndex = options.firstIndex { $0.assistantID == activeAssistant?.id } ?? 0
        isAssistantChooserPresented = true
        isModelChooserPresented = false
        isAddContextMenuPresented = false
        isTransformChooserPresented = false
        isActionPalettePresented = false
        closeItemActionPane()
        actionQuery = ""
        errorMessage = nil
        requestInputFocus()
    }

    func closeAssistantChooser() {
        guard isAssistantChooserPresented else { return }
        isAssistantChooserPresented = false
        requestInputFocus()
    }

    /// `⌥⌘A` and the header's assistant name: open or close the chooser.
    func toggleAssistantChooser() {
        if isAssistantChooserPresented { closeAssistantChooser() } else { openAssistantChooser() }
    }

    func moveAssistantChooserSelection(_ delta: Int) {
        let count = assistantChooserOptions.count
        guard count > 0 else { return }
        assistantChooserIndex = ListSelection.wrappedIndex(assistantChooserIndex, by: delta, count: count)
    }

    /// Return in the chooser: pick the highlighted row.
    func runAssistantChooserSelection() {
        let options = assistantChooserOptions
        guard options.indices.contains(assistantChooserIndex) else { return }
        let pick = options[assistantChooserIndex].assistantID
        selectAssistant(pick.flatMap { id in assistants.first { $0.id == id } })
        requestInputFocus()
    }

    // MARK: - System message

    /// The system message a request in `conversation` carries. Nil for a
    /// plain chat.
    func assistantSystemMessage(for conversation: QuickConversation?) async -> String? {
        guard let conversation, let assistant = assistant(for: conversation) else { return nil }
        return await assistantSystemMessage(assistant, conversationID: conversation.id)
    }

    /// The system message `assistant` sends in the chat `conversationID`:
    /// its instructions, then its context skills. The skill files are read
    /// once per chat, off the main actor, and read again only when the chat,
    /// its assistant, or the assistant's skill list changes. With no skill
    /// library, the instructions go alone.
    func assistantSystemMessage(_ assistant: SavedPrompt, conversationID: UUID) async -> String? {
        let refs = assistant.contextRefs
        let skills: [AssistantSkill]
        if let cache = assistantSkillCache,
           cache.conversationID == conversationID,
           cache.assistantID == assistant.id,
           cache.refs == refs {
            skills = cache.skills
        } else if refs.isEmpty {
            skills = []
        } else if let skillLibrary {
            skills = await AssistantContext.loadSkills(refs, library: skillLibrary)
            assistantSkillCache = AssistantSkillCache(
                conversationID: conversationID,
                assistantID: assistant.id,
                refs: refs,
                skills: skills
            )
        } else {
            skills = []
        }
        return AssistantContext.systemMessage(
            instructions: assistant.systemPrompt ?? "",
            skills: skills
        )
    }
}
