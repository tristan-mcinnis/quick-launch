import Foundation

/// One input to the Type to Click search.
///
/// - `id`: a stable identifier, preserved through ranking for callers that need
///   to map a rank back to a specific element or command.
/// - `label`: what the user actually sees.
/// - `searchText`: broader aggregate text such as accessibility descriptions,
///   extra keywords, and submenu trails.
/// - `role`: the element or command role, e.g. "button" or "menu item".
struct TypeToClickSearchCandidate: Sendable, Equatable {
    let id: String
    let label: String
    let searchText: String
    let role: String
}

/// Pure, AppKit-free fuzzy ranking for the Type to Click search.
///
/// Matching rules:
/// - Every query token must match the candidate's label, role, or search text
///   through an exact word, a word prefix, a substring, or a fuzzy
///   subsequence.
/// - Case, diacritics, and punctuation are normalized before comparing, so
///   "SUBMIT", "Submít", and "submit!" are all the same.
/// - Small synonym / type aliases are substituted before matching
///   (btn ↔ button, check ↔ checkbox, input ↔ field ↔ textfield,
///   delete ↔ remove ↔ clear ↔ destroy, menu / link / radio families).
///
/// Ranking rules (best first):
/// 1. Exact label and word matches outrank substring and fuzzy matches.
/// 2. Shorter labels break ties.
/// 3. Stable original candidate order breaks the remaining ties.
///
/// An empty query returns no candidates because Type to Click is search-only.
enum TypeToClickSearch {

    /// Pre-normalized candidate data reused across keystrokes. Building this
    /// once per AX scan avoids thousands of Unicode folds on the main actor for
    /// every character in a large browser or Electron window.
    struct Index: Sendable {
        private let prepared: [Prepared]

        init(candidates: [TypeToClickSearchCandidate]) {
            prepared = TypeToClickSearch.prepare(candidates)
        }

        func rankedIndices(query: String) -> [Int] {
            TypeToClickSearch.rankIndices(prepared: prepared, query: query)
        }
    }

    // MARK: - Public API

    /// Returns the indices of `candidates`, sorted best-first for `query`.
    static func rankedIndices(
        in candidates: [TypeToClickSearchCandidate],
        query: String
    ) -> [Int] {
        Index(candidates: candidates).rankedIndices(query: query)
    }

    /// Returns the candidates themselves, sorted best-first for `query`.
    static func rankedCandidates(
        _ candidates: [TypeToClickSearchCandidate],
        query: String
    ) -> [TypeToClickSearchCandidate] {
        rankedIndices(in: candidates, query: query).map { candidates[$0] }
    }

    /// Normalized form of any searchable string: case- and diacritic-folded,
    /// punctuation turned into whitespace, whitespace collapsed.
    ///
    /// Public so callers can preview how a value will be searched, and so the
    /// tests can pin the normalization behavior directly.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US")
        )
        let mapped = folded.map { character -> Character in
            (character.isLetter || character.isNumber) ? character : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    // MARK: - Ranking pipeline

    /// Returns the ranked indices. The implementation never mutates
    /// `candidates`; original indices are used to preserve stable order.
    private static func rankIndices(
        prepared: [Prepared],
        query: String
    ) -> [Int] {
        let normalizedQuery = normalize(query)
        let tokens = normalizedQuery.split(separator: " ").map(String.init)

        guard !tokens.isEmpty else { return [] }

        let expandedTokens = tokens.map(aliasExpansion)

        var scored: [Scored] = []
        scored.reserveCapacity(prepared.count)

        for candidate in prepared {
            guard tokenGate(candidate, expandedTokens: expandedTokens) else { continue }

            let textScore = textMatchScore(candidate, expandedTokens: expandedTokens)
            scored.append(Scored(
                index: candidate.index,
                textScore: textScore,
                labelLength: candidate.originalLabelLength
            ))
        }

        return scored.sorted(by: Self.precedes).map(\.index)
    }

    /// Pre-normalizes every field once so the per-token matcher never re-folds.
    private static func prepare(
        _ candidates: [TypeToClickSearchCandidate]
    ) -> [Prepared] {
        candidates.enumerated().map { index, candidate in
            Prepared(
                index: index,
                label: normalize(candidate.label),
                originalLabelLength: candidate.label.count,
                role: normalize(candidate.role),
                searchText: normalize(candidate.searchText)
            )
        }
    }

    // MARK: - Token gate and text score

    /// Returns true only when every expanded query token matches the candidate's
    /// label, role, or aggregate search text.
    private static func tokenGate(_ candidate: Prepared, expandedTokens: [[String]]) -> Bool {
        for variants in expandedTokens {
            var matched = false
            for variant in variants {
                if matchQuality(token: variant, text: candidate.label) != .none
                    || matchQuality(token: variant, text: candidate.role) != .none
                    || matchQuality(token: variant, text: candidate.searchText) != .none {
                    matched = true
                    break
                }
            }
            if !matched { return false }
        }
        return true
    }

    /// Sum of the best per-token match quality across label / role / search
    /// text. Exact word (4) > word prefix (3) > substring (2) > fuzzy (1).
    private static func textMatchScore(_ candidate: Prepared, expandedTokens: [[String]]) -> Int {
        let surfaces = [candidate.label, candidate.role, candidate.searchText]
        var total = 0
        for variants in expandedTokens {
            var best = 0
            for variant in variants {
                for surface in surfaces {
                    best = max(best, matchQuality(token: variant, text: surface).rawValue)
                }
            }
            total += best
        }
        return total
    }

    // MARK: - Per-token match quality

    private enum MatchQuality: Int, Sendable {
        case none = 0
        case fuzzy = 1
        case substring = 2
        case wordPrefix = 3
        case exactWord = 4
    }

    /// Best match kind of `token` inside `text`, evaluated from strongest to
    /// weakest. `token` and `text` are already normalized (folded, no punct).
    private static func matchQuality(token: String, text: String) -> MatchQuality {
        guard !token.isEmpty else { return .none }
        let words = text.split(separator: " ").map(String.init)
        if words.contains(where: { $0 == token }) { return .exactWord }
        if words.contains(where: { $0.hasPrefix(token) }) { return .wordPrefix }
        if text.contains(token) { return .substring }
        if isSubsequence(token, in: text) { return .fuzzy }
        return .none
    }

    /// True when every character of `needle` appears in `haystack` in order.
    /// Spaces in `haystack` are passed over, so fuzzy matching works across
    /// word boundaries (e.g. "tc" inside "type to click").
    private static func isSubsequence(_ needle: String, in haystack: String) -> Bool {
        var needleIndex = needle.startIndex
        for character in haystack {
            if needleIndex < needle.endIndex, character == needle[needleIndex] {
                needleIndex = needle.index(after: needleIndex)
            }
        }
        return needleIndex == needle.endIndex
    }

    // MARK: - Synonym / type aliases

    /// Mutually-substitutable token families. A query token that belongs to a
    /// family matches any label / role / search text that contains any member.
    private static let aliasFamilies: [[String]] = [
        ["btn", "button"],
        ["check", "checkbox"],
        ["input", "field", "textfield"],
        ["delete", "remove", "clear", "destroy"],
        ["menu", "menubar", "menuitem"],
        ["link", "hyperlink"],
        ["radio", "radiobutton"],
    ]

    private static func aliasExpansion(_ token: String) -> [String] {
        for family in aliasFamilies where family.contains(token) {
            return family
        }
        return [token]
    }

    // MARK: - Sort

    private struct Scored {
        let index: Int
        let textScore: Int
        let labelLength: Int
    }

    /// Best-first comparator: text quality, then shorter label, then original
    /// index. Indices are unique so the ordering is total
    /// and therefore deterministic regardless of `sort(by:)` stability.
    private static func precedes(_ a: Scored, _ b: Scored) -> Bool {
        if a.textScore != b.textScore { return a.textScore > b.textScore }
        if a.labelLength != b.labelLength { return a.labelLength < b.labelLength }
        return a.index < b.index
    }

    // MARK: - Prepared candidate

    fileprivate struct Prepared: Sendable {
        let index: Int
        let label: String
        let originalLabelLength: Int
        let role: String
        let searchText: String
    }
}
