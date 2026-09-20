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
        // A skill named in the draft is a command this build answers to
        // (`runSlashSkill`), so it must not reach the unknown-command
        // refusal. Only the one name in front of us is checked: listing the
        // whole skills folder here would read the disk on every keystroke.
        if let skill = slashSkillName(in: input) { names.insert("/" + skill) }
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

    // The composer's scope pill is gone (2026-09-20). It read "Standard
    // chat" in an ordinary chat, where every tool was already allowed, so
    // the only thing a click could do was withhold them; and because the
    // label was decided before the override was consulted, it went on
    // reading "Standard chat" while it did. The tools are always offered
    // now (`ChatContextGate.gatedTools`), so there is nothing to widen and
    // no control to draw. `composerContextEvaluation` stays: the send path
    // and the per-turn receipt still use it.

    /// Whether a conversation carries any attachment reference.
    static func conversationHasSources(_ conversation: QuickConversation?) -> Bool {
        (conversation?.messages ?? []).contains { !$0.attachmentRefs.isEmpty }
    }
}
