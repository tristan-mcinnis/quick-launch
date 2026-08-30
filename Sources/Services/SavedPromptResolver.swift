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

    static func prompt(for action: SavedPrompt, source: String) -> String {
        if action.prompt.contains("{selection}") {
            return action.prompt.replacingOccurrences(of: "{selection}", with: source)
        }
        guard !source.isEmpty else { return action.prompt }
        return "\(action.prompt)\n\n\(source)"
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
