import Foundation

enum FuzzyMatcher {
    /// Case- and diacritic-insensitive form used for every comparison.
    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func score(query: String, candidate: String) -> Int? {
        score(foldedQuery: fold(query), foldedCandidate: fold(candidate))
    }

    /// Scores strings that were already passed through `fold`, so callers
    /// that compare one query against many candidates fold each side once.
    static func score(foldedQuery: String, foldedCandidate: String) -> Int? {
        let needle = Array(foldedQuery)
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(foldedCandidate)
        var needleIndex = 0
        var score = 0
        var previousMatch: Int?

        for index in haystack.indices where needleIndex < needle.count {
            guard haystack[index] == needle[needleIndex] else { continue }
            score += 10
            if index == haystack.startIndex || !haystack[haystack.index(before: index)].isLetter {
                score += 8
            }
            if let previousMatch, index == previousMatch + 1 { score += 5 }
            score -= min(index, 12)
            previousMatch = index
            needleIndex += 1
        }
        return needleIndex == needle.count ? score : nil
    }
}
