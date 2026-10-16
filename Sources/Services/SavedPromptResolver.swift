import Foundation

/// Maps `<prefix><alias>` inputs to full prompt expansions and surfaces
/// autocomplete matches while the user is still typing an alias.
enum SavedPromptResolver {

    struct Resolution: Sendable, Equatable {
        var actionID: UUID
        var prompt: String
        var providerID: UUID?
        var model: String?
        var outputBehavior: ActionOutputBehavior
        /// The raw text typed after the alias, whitespace-collapsed. Command
        /// actions substitute this for `{input}`; empty when the alias was
        /// invoked alone.
        var context: String = ""
    }

    /// Expand an input to its saved-prompt equivalent, or return `nil` when
    /// the input is not an alias invocation.
    ///
    /// Rules:
    /// - `<prefix><alias>` alone expands to the saved prompt verbatim.
    /// - `<prefix><alias> <context>` expands to `<saved prompt>\n\n<context>`.
    /// - Any trailing whitespace between the alias and the context collapses.
    /// - Aliases are case-sensitive.
    /// - An empty prefix never matches (guards against accidental expansion).
    static func resolve(
        input: String,
        prefix: String,
        savedPrompts: [SavedPrompt]
    ) -> String? {
        resolveAction(input: input, prefix: prefix, savedPrompts: savedPrompts)?.prompt
    }

    static func resolveAction(
        input: String,
        prefix: String,
        savedPrompts: [SavedPrompt]
    ) -> Resolution? {
        guard !prefix.isEmpty else { return nil }
        guard input.hasPrefix(prefix) else { return nil }
        let rest = String(input.dropFirst(prefix.count))
        guard !rest.isEmpty else { return nil }

        // Split on the first whitespace run.
        let (alias, context) = split(rest)
        guard let match = savedPrompts.first(where: { $0.alias == alias }) else {
            return nil
        }
        if context.isEmpty {
            return Resolution(
                actionID: match.id,
                prompt: match.prompt,
                providerID: match.providerID,
                model: match.model,
                outputBehavior: match.outputBehavior,
                context: ""
            )
        }
        return Resolution(
            actionID: match.id,
            prompt: prompt(for: match, source: context),
            providerID: match.providerID,
            model: match.model,
            outputBehavior: match.outputBehavior,
            context: context
        )
    }

    /// The assistant a bare `<prefix><alias>` names: nothing typed after the
    /// alias, and the saved prompt is an assistant. Nil for a transform
    /// (text after the alias), a command action, or any other input, which
    /// all keep `resolveAction`'s behaviour.
    static func assistant(
        input: String,
        prefix: String,
        savedPrompts: [SavedPrompt]
    ) -> SavedPrompt? {
        guard let resolution = resolveAction(input: input, prefix: prefix, savedPrompts: savedPrompts),
              resolution.context.isEmpty,
              let match = savedPrompts.first(where: { $0.id == resolution.actionID }),
              match.isAssistant
        else { return nil }
        return match
    }

    /// The `{argument}` slots a saved prompt asks the user to fill, in the
    /// order the template first names them. Empty for an ordinary prompt.
    static func argumentSlots(in prompt: String) -> [SnippetArgument] {
        SnippetPlaceholders.arguments(in: prompt)
    }

    /// True when the template reads the clipboard through an explicit
    /// `{clipboard}` placeholder (any case, modifiers allowed). Nothing reads
    /// the pasteboard on a saved prompt's behalf unless this says so.
    static func readsClipboard(_ prompt: String) -> Bool {
        SnippetPlaceholders.usesClipboard(prompt)
    }

    /// The full expansion of one saved action over `source`.
    ///
    /// Legacy behaviour is preserved exactly: `{selection}` is replaced
    /// inline, and a template with no `{selection}` gets the source appended
    /// after a blank line (an assistant may leave its prompt empty, so the
    /// source stands alone). On top of that, the shared placeholder grammar
    /// fills `{argument …}` from `arguments` (positional, matching
    /// `argumentSlots(in:)`), `{clipboard}` from `clipboard`, and
    /// `{date}`/`{time}`. `clipboard` is nil unless the caller chose to read
    /// it, so a template that never asks for it never sees it.
    static func prompt(
        for action: SavedPrompt,
        source: String,
        arguments: [String] = [],
        clipboard: String? = nil
    ) -> String {
        let template = action.prompt
        let usesSelection = template.contains("{selection}")
        // Expand the TEMPLATE first. The engine does not know `{selection}`,
        // so it stays literal; a sentinel replaces it so that a `{clipboard}`
        // or `{argument}` value the user supplies cannot later be mistaken
        // for the template's own selection slot.
        let sentinel = "\u{0}selection\u{0}"
        var prepared = usesSelection
            ? template.replacingOccurrences(of: "{selection}", with: sentinel)
            : template
        // `containsPlaceholders` is false for `{selection}` alone (the engine
        // does not know that name), so an ordinary prompt is left untouched.
        if SnippetPlaceholders.containsPlaceholders(prepared) {
            prepared = SnippetPlaceholders.expand(
                prepared,
                clipboard: clipboard,
                arguments: arguments
            ).text
        }
        // The SOURCE is literal data now: braces inside it are never executed
        // as template syntax (a selection that reads `{date}` stays `{date}`).
        if usesSelection {
            return prepared.replacingOccurrences(of: sentinel, with: source)
        }
        guard !source.isEmpty else { return prepared }
        // An assistant may leave its transform prompt empty: the text alone
        // is the question, with no blank lines in front of it.
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return source }
        return "\(prepared)\n\n\(source)"
    }

    /// Return saved prompts whose aliases or names fuzzy-match the fragment
    /// typed after the prefix. Returns `[]` once the user has typed
    /// a full alias followed by a space (they have committed to sending).
    static func matches(
        input: String,
        prefix: String,
        savedPrompts: [SavedPrompt]
    ) -> [SavedPrompt] {
        guard !prefix.isEmpty else { return [] }
        guard input.hasPrefix(prefix) else { return [] }
        let rest = String(input.dropFirst(prefix.count))

        // Once whitespace is typed, autocomplete no longer applies - the
        // user has moved on to providing context.
        if rest.contains(where: { $0.isWhitespace }) {
            return []
        }

        if rest.isEmpty {
            return savedPrompts.sorted { $0.alias < $1.alias }
        }

        return savedPrompts.enumerated().compactMap { ordinal, action -> (SavedPrompt, Int, Int)? in
            let score = [
                FuzzyMatcher.score(query: rest, candidate: action.alias),
                FuzzyMatcher.score(query: rest, candidate: action.name),
            ].compactMap { $0 }.max()
            guard let score else { return nil }
            return (action, score, ordinal)
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.2 < rhs.2 : lhs.1 > rhs.1
        }
        .map(\.0)
    }

    // MARK: - Helpers

    /// Split `"translate    hello   world"` into (`"translate"`, `"hello world"`).
    private static func split(_ rest: String) -> (alias: String, context: String) {
        guard let firstSpace = rest.firstIndex(where: { $0.isWhitespace }) else {
            return (rest, "")
        }
        let alias = String(rest[..<firstSpace])
        let tail = rest[firstSpace...]
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return (alias, tail)
    }
}
