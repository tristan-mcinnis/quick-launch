import Foundation
import HouseChatCore

/// Built-in slash commands and the composer's context-scope seam.
///
/// `/new` and `/clear` are the shared core's reserved commands. Quick Launch
/// has no app commands of its own today, so the router only keeps every other
/// slash line local: an unknown command is an error, never prompt text. A
/// refused line is sent only by the explicit `sendRefusedCommandAsText`
/// action; ordinary Return and ⌘Return never bypass the refusal.
///
/// The context-scope bindings below are the UI worker's contract. Every one
/// is computed from the real `ChatContextGate` decision for what is in the
/// composer, never from the override alone.
extension QuickViewModel {
    /// App commands this build knows. Empty: the router is ready for RTI's
    /// `/meeting` style commands, but Quick Launch has none.
    static var knownChatCommands: Set<String> { [] }

    /// The command a line is, or nil for ordinary prompt text.
    func quickCommandOutcome(for input: String) -> QuickChatCommandOutcome? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
        guard Self.looksLikeCommand(first) else { return nil }
        let outcome = QuickChatCommandRouter(knownCommands: knownChatCommandNames).route(input)
        return outcome == .notACommand ? nil : outcome
    }

    /// A command name is `/` plus letters, digits, hyphen, or underscore. A
    /// path question (`/etc/hosts is not updating`) or a bare `/` is ordinary
    /// text, not a command, so only a real command can be refused locally.
    static func looksLikeCommand(_ token: String) -> Bool {
        guard token.hasPrefix("/"), token.count > 1 else { return false }
        return token.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// The slash names this build recognizes: its own app commands plus every
    /// saved-prompt alias for the current prefix. Passing the aliases as
    /// known commands keeps `/clean`, `/vault`, and the rest off the
    /// unknown-command path, so they still expand through
    /// `SavedPromptResolver` exactly as before. The built-ins still win.
    var knownChatCommandNames: Set<String> {
        var names = Self.knownChatCommands
        guard settings.savedPromptPrefix == "/" else { return names }
        names.formUnion(settings.savedPrompts.map { "/" + $0.alias })
        return names
    }

    // MARK: - Built-in commands

    /// `/new`: save the open chat (a stream still running stops and keeps
    /// what arrived), then start a fresh chat with no draft context and no
    /// context override. Saved chats and the archived sources are untouched.
    func performNewChatCommand() {
        if isStreaming { cancel() }
        persistCurrentConversation()
        startNewConversation()
        reset([.attachments])
        contextOverride = nil
        sendAsTextOnce = false
        clearRefusedCommand()
        threadNotice = "New chat"
        requestInputFocus()
    }

    /// `/clear`: clear the thread, the draft, the pending attachments, the
    /// model pick, and the context override without creating a new chat. The
    /// chat's already-saved copy, the archived sources, and the history stand.
    func performClearChatCommand() {
        if isStreaming { cancel() }
        startNewConversation()
        reset([.attachments])
        contextOverride = nil
        sendAsTextOnce = false
        clearRefusedCommand()
        threadNotice = "Chat cleared"
        requestInputFocus()
    }

    /// The explicit Send as Text action for a refused slash line: the exact
    /// refused line goes to the model once. Repeated Return and ⌘Return never
    /// set the bypass.
    func sendRefusedCommandAsText() {
        guard let refused = refusedCommandText else { return }
        input = refused
        sendAsTextOnce = true
        errorMessage = nil
        Task { await submit() }
    }

    // MARK: - Context scope seam

    /// The real gate for what is in the composer right now, with the user's
    /// override applied.
    var composerContextEvaluation: ChatContextEvaluation {
        ChatContextGate.standard.evaluate(
            enabledTools: chatTools,
            hasCurrentSource: hasPendingChatContext,
            currentSourceCount: attachmentTray.items.filter { $0.content != nil }.count,
            historyTurnCount: currentConversation?.messages.count ?? 0,
            historyHasSources: Self.conversationHasSources(currentConversation),
            question: input,
            override: contextOverride
        )
    }

    /// The gate the wording alone would give, ignoring the override. Used to
    /// decide what the control offers.
    var naturalContextEvaluation: ChatContextEvaluation {
        ChatContextGate.standard.evaluate(
            enabledTools: chatTools,
            hasCurrentSource: hasPendingChatContext,
            currentSourceCount: attachmentTray.items.filter { $0.content != nil }.count,
            historyTurnCount: currentConversation?.messages.count ?? 0,
            historyHasSources: Self.conversationHasSources(currentConversation),
            question: input
        )
    }

    /// "Standard chat", "Attached sources", or "Broader search", from the
    /// real decision. An ordinary chat with no sources permits the tools, so
    /// it is Standard chat; a grounded request whose tools are withheld is
    /// Attached sources; once widened it is Broader search.
    var contextScopeLabel: String {
        let hasAnySource = hasPendingChatContext || Self.conversationHasSources(currentConversation)
        guard hasAnySource else { return "Standard chat" }
        return composerContextEvaluation.allowsExternalRetrieval ? "Broader search" : "Attached sources"
    }

    /// One line explaining the effective route.
    var contextScopeDetail: String {
        let evaluation = composerContextEvaluation
        let hasAnySource = hasPendingChatContext || Self.conversationHasSources(currentConversation)
        guard hasAnySource else {
            return evaluation.allowsExternalRetrieval
                ? "No source attached; the tools may be used."
                : "No source attached; the tools are unavailable."
        }
        let reading: String
        switch evaluation.execution {
        case "currentSource": reading = "Reading the attached source"
        case "history": reading = "Reading earlier turns"
        case "currentSourceAndHistory": reading = "Reading the attached source and earlier turns"
        default: reading = "Reading the conversation"
        }
        return evaluation.allowsExternalRetrieval
            ? "\(reading); memory, vault, skills, and web are allowed."
            : "\(reading); memory, vault, skills, and web are withheld."
    }

    /// True when the control should offer widening: the request is grounded
    /// and its broad tools are currently withheld.
    var contextScopeOffersWidening: Bool { composerContextEvaluation.broaderSearchEnabled }

    /// A short summary of the attached sources, or nil when there are none.
    var attachedSourceSummary: String? {
        let pending = attachmentTray.items.compactMap { $0.content?.ref.name }
        let names = pending.isEmpty
            ? (currentConversation?.messages ?? []).flatMap(\.attachmentRefs).map(\.name)
            : pending
        guard !names.isEmpty else { return nil }
        if names.count == 1 { return names[0] }
        return "\(names.count) sources"
    }

    /// Toggle the context scope from the effective decision: widening when
    /// the tools are withheld, narrowing to source-only when they are not.
    /// Explicit wording may re-widen a request, so the toggle sets an
    /// explicit override rather than returning to nil.
    func toggleContextScope() {
        contextOverride = composerContextEvaluation.allowsExternalRetrieval ? .sourceOnly : .broader
        requestInputFocus()
    }

    /// Whether a conversation carries any attachment reference.
    static func conversationHasSources(_ conversation: QuickConversation?) -> Bool {
        (conversation?.messages ?? []).contains { !$0.attachmentRefs.isEmpty }
    }
}
