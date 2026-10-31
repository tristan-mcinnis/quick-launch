import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    // MARK: - Result actions

    /// Actions available on the answer on screen.
    var resultActions: [ResultAction] {
        // While an answer streams, Continue in pi is the one action: it stops
        // the answer, keeps it, and hands the chat over.
        guard !isStreaming else {
            return piHandoff != nil && !conversationMessages.isEmpty ? [.continueInPi] : []
        }
        let hasAnswer = !output.isEmpty
        // A question the thread holds without an answer (stopped before any
        // text, or a provider error) still offers ⌘R, and the chat actions.
        guard hasAnswer || hasUnansweredTurn else { return [] }
        // Replace Selection is the precise action after a selection transform:
        // it writes back to the originally captured selection (retained across
        // the request). Paste into Previous App is the broader fallback. Both
        // fail safe to Copy with a truthful error when the target is gone.
        var actions: [ResultAction] = []
        if hasAnswer {
            if replaceableSelectionContext != nil { actions.append(.replaceSelection) }
            actions.append(contentsOf: [.pasteBack, .copy])
        }
        if !conversationMessages.isEmpty {
            actions.append(.copyChat)
            if piHandoff != nil { actions.append(.continueInPi) }
        }
        if offersContinueInAIChat { actions.append(.continueInAIChat) }
        if fileOpener != nil, !answerSources.isEmpty { actions.append(.openSource) }
        if hasAnswer {
            actions.append(.saveSnippet)
            if memoryCapture != nil { actions.append(.captureToMemory) }
            actions.append(contentsOf: [.searchWeb, .pasteFormatted])
        }
        actions.append(contentsOf: [.regenerate, .regenerateWithModel, .changeModel])
        if !assistants.isEmpty { actions.append(.changeAssistant) }
        if isQuickAIPresented { actions.append(.tools) }
        actions.append(.newChat)
        if canOpenRecentChats { actions.append(.recentChats) }
        if currentConversation != nil {
            actions += [.renameChat, .pinChat, .deleteChat]
        }
        if history.count > 1 { actions += [.previousChat, .nextChat] }
        // The window reads and copies; it has no app behind it to paste
        // into, and its chat list is the rail, not Recent Chats.
        if isAIChatWindow { actions.removeAll { Self.launcherOnlyResultActions.contains($0) } }
        return actions
    }

    /// Answer actions the AI Chat window leaves out.
    static let launcherOnlyResultActions: Set<ResultAction> = [
        .replaceSelection, .pasteBack, .pasteFormatted, .recentChats, .continueInAIChat,
    ]

    /// `⌘J` hands the chat to the AI Chat window: on the Quick AI surface,
    /// when the app can open the window.
    var offersContinueInAIChat: Bool {
        aiChatOpener != nil && !isAIChatWindow && isQuickAIPresented
    }

    /// Display, search, and VoiceOver use the same state-dependent action.
    func resultActionTitle(_ action: ResultAction) -> String {
        if action == .pinChat, currentConversation?.isPinned == true { return "Unpin Chat" }
        return action.title
    }

    func resultActionSystemImage(_ action: ResultAction) -> String {
        if action == .pinChat, currentConversation?.isPinned == true { return "pin.slash" }
        return action.systemImage
    }

    /// The palette row's second line: the app a destination answer action
    /// targets (so the user never guesses which app receives the output),
    /// the model or tools in use, or what a chat action does to the chat.
    /// Nil falls back to the action's group, "Answer" or "Chat".
    func resultActionDetail(_ action: ResultAction) -> String? {
        switch action {
        case .replaceSelection:
            replaceableSelectionContext.map { "Replace in \($0.target.applicationName)" }
        case .pasteBack:
            selectionTarget.map { "Paste into \($0.applicationName)" }
        case .pasteFormatted:
            selectionTarget.map { "Formatted, into \($0.applicationName)" }
                ?? "Keep headings, lists and links"
        case .changeModel:
            "Using \(activeModelDisplay)"
        case .changeAssistant:
            activeAssistant.map { "Using \($0.name)" } ?? "No assistant"
        case .regenerateWithModel:
            "Run this question again on another model"
        case .openSource:
            answerSources.count == 1
                ? answerSources[0].title
                : "\(answerSources.count) sources"
        case .captureToMemory:
            "Send this answer to recall"
        case .tools:
            chatToolsSummary
        case .continueInPi:
            isStreaming ? "Stop the answer, then open pi" : "New tmux session in Ghostty"
        case .continueInAIChat:
            "Open this chat in its own window"
        // Chat actions say what they do to the chat; one with nothing to
        // add reads "Chat" (`paletteGroup`), never "Answer".
        case .copyChat:
            "The whole chat as text"
        case .newChat:
            "Start over on an empty chat"
        case .recentChats:
            "Pinned and recent chats"
        case .previousChat:
            "The chat before this one"
        case .nextChat:
            "The chat after this one"
        case .renameChat:
            "Give this chat a name"
        case .pinChat:
            currentConversation?.isPinned == true ? "Unpin this chat" : "Keep this chat at the top"
        case .deleteChat:
            "Remove this chat from history"
        default:
            nil
        }
    }

    func performResultAction(_ action: ResultAction) async {
        switch action {
        case .replaceSelection:
            _ = await replaceOutputInCapturedSelection()
        case .pasteBack:
            _ = await pasteOutputToPreviousApp()
        case .pasteFormatted:
            _ = await pasteFormattedOutputToPreviousApp()
        case .copy:
            // The surface stays open; the composer shows the checkmark.
            isActionPalettePresented = false
            copyAnswerOnSurface()
        case .copyChat:
            isActionPalettePresented = false
            copyChatTranscript()
        case .continueInPi:
            await continueInPi()
        case .continueInAIChat:
            isActionPalettePresented = false
            continueInAIChat()
        case .saveSnippet:
            saveOutputAsSnippet()
        case .searchWeb:
            await searchWebForOutput()
        case .regenerate:
            isActionPalettePresented = false
            await regenerateLastAnswer()
        case .regenerateWithModel:
            // `⇧⌘R`: choose first, then answer the same question again.
            openModelChooser(.regenerate)
        case .changeModel:
            // Switching model mid-conversation sends nothing: the next
            // question simply goes to the new model.
            openModelChooser(.change)
        case .changeAssistant:
            // Nothing is sent either: the next question goes to the chat
            // as the picked assistant.
            openAssistantChooser()
        case .newChat:
            isActionPalettePresented = false
            startNewConversation()
        case .recentChats:
            isActionPalettePresented = false
            openRecentChats()
        case .previousChat:
            // History is ordered newest first, so going back in time means
            // moving forward through the array.
            isActionPalettePresented = false
            browseConversations(1)
        case .nextChat:
            isActionPalettePresented = false
            browseConversations(-1)
        case .renameChat:
            guard let id = currentConversation?.id else { return }
            isActionPalettePresented = false
            // The AI Chat window renames in its chat list; the launcher's
            // field becomes the rename field.
            if let chatWindowHost {
                chatWindowHost.beginRenamingChat(id: id)
            } else {
                enterInputMode(.renameChat(id))
            }
        case .pinChat:
            guard let id = currentConversation?.id else { return }
            isActionPalettePresented = false
            togglePinConversation(id: id)
        case .deleteChat:
            guard let id = currentConversation?.id else { return }
            isActionPalettePresented = false
            deleteConversation(id: id)
        case .openSource:
            let sources = answerSources
            if sources.count == 1 {
                await openSource(sources[0])
            } else {
                openActionPaletteSubmenu(.sources)
            }
        case .captureToMemory:
            isActionPalettePresented = false
            await captureAnswerToMemory()
        case .tools:
            openActionPaletteSubmenu(.tools)
        }
    }
}
