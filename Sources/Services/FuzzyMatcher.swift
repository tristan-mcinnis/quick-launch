import Foundation

enum FuzzyMatcher {
    static func score(query: String, candidate: String) -> Int? {
        let needle = Array(query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ))
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ))
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
