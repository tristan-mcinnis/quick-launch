import Testing
@testable import QuickLaunch

// MARK: - Helpers

private func candidate(
    _ id: String,
    hint: String? = nil,
    label: String,
    searchText: String = "",
    role: String = "",
    isSpatial: Bool = true
) -> TypeToClickSearchCandidate {
    TypeToClickSearchCandidate(
        id: id,
        hint: hint,
        label: label,
        searchText: searchText,
        role: role,
        isSpatial: isSpatial
    )
}

private func ids(_ candidates: [TypeToClickSearchCandidate], _ indices: [Int]) -> [String] {
    indices.map { candidates[$0].id }
}

private func rank(
    _ candidates: [TypeToClickSearchCandidate],
    _ query: String
) -> [String] {
    ids(candidates, TypeToClickSearch.rankedIndices(in: candidates, query: query))
}

@Suite("Type to Click hybrid search")
struct TypeToClickSearchTests {

    // MARK: - Empty query

    @Test func emptyQueryReturnsOnlySpatialHintTargetsInOriginalOrder() {
        let candidates = [
            candidate("save", hint: "a", label: "Save", role: "button"),
            candidate("cancel", hint: nil, label: "Cancel", role: "button"),
            candidate("open", hint: "b", label: "Open", role: "button", isSpatial: false),
            candidate("delete", hint: "c", label: "Delete", role: "button"),
        ]
        // Only on-screen elements that carry a hint, in original order. The
        // app-menu command with a hint and the hintless element are dropped.
        #expect(rank(candidates, "") == ["save", "delete"])
    }

    @Test func emptyQueryWhitespaceBehavesLikeEmpty() {
        let candidates = [
            candidate("save", hint: "a", label: "Save"),
            candidate("open", hint: "b", label: "Open"),
        ]
        #expect(rank(candidates, "   ") == ["save", "open"])
    }

    // MARK: - Hint ranking

    @Test func exactHintRanksHighestForCompactQuery() {
        let candidates = [
            candidate("apple", hint: nil, label: "Apple"),
            candidate("save", hint: "a", label: "Save"),
            candidate("delete", hint: "b", label: "Delete"),
        ]
        // "a" exactly matches the hint of "save", which must beat the label
        // prefix match on "Apple".
        #expect(rank(candidates, "a") == ["save", "apple"])
    }

    @Test func hintPrefixOutranksNoHintAndExactHintTopsIt() {
        let candidates = [
            candidate("saveAs", hint: "sad", label: "Save", role: "button"),
            candidate("save", hint: "sa", label: "Save", role: "button"),
            candidate("open", hint: nil, label: "Search", role: "button"),
        ]
        // Query "sa": "save" has the exact hint (2), "saveAs" has the prefix
        // hint (1), "open" has no hint match but does match the label word.
        #expect(rank(candidates, "sa") == ["save", "saveAs", "open"])
    }

    @Test func stableOrderAmongEqualHintMatches() {
        let candidates = [
            candidate("first", hint: "sad", label: "Save", role: "button"),
            candidate("second", hint: "sap", label: "Save", role: "button"),
        ]
        // Both are prefix hints with identical text scores and label lengths;
        // original order must resolve the tie.
        #expect(rank(candidates, "sa") == ["first", "second"])
    }

    // MARK: - Normalization

    @Test func normalizePinsCanonicalForm() {
        #expect(TypeToClickSearch.normalize("SUBMIT") == "submit")
        #expect(TypeToClickSearch.normalize("Café") == "cafe")
        #expect(TypeToClickSearch.normalize("Type-to-Click!") == "type to click")
        #expect(TypeToClickSearch.normalize("  a   b  ") == "a b")
        #expect(TypeToClickSearch.normalize("") == "")
    }

    @Test func searchIgnoresCase() {
        let candidates = [
            candidate("save", label: "SAVE", role: "button"),
            candidate("cancel", label: "Cancel", role: "button"),
        ]
        #expect(rank(candidates, "save") == ["save"])
    }

    @Test func searchIgnoresDiacritics() {
        let candidates = [
            candidate("cafe", label: "Café", role: "button"),
            candidate("tea", label: "Thé", role: "button"),
        ]
        #expect(rank(candidates, "cafe") == ["cafe"])
    }

    @Test func searchIgnoresPunctuation() {
        let candidates = [
            candidate("split", label: "Type-to-Click", role: "link"),
            candidate("other", label: "Something else", role: "link"),
        ]
        // Query normalizes to "type to click", three tokens, all of which must
        // match the first candidate.
        #expect(rank(candidates, "type-to-click") == ["split"])
    }

    // MARK: - Token gate

    @Test func everyQueryTokenMustMatch() {
        let candidates = [
            candidate("both", label: "Save File", role: "menu"),
            candidate("partial", label: "Save", role: "menu"),
            candidate("neither", label: "Close", role: "menu"),
        ]
        // "save file" requires both "save" and "file". Only "both" satisfies it.
        #expect(rank(candidates, "save file") == ["both"])
    }

    @Test func hintCountsAsARegularMatchSurfaceForTheGate() {
        let candidates = [
            candidate("save", hint: "sa", label: "Persist", role: "button"),
            candidate("other", hint: "zz", label: "Persist", role: "button"),
        ]
        // "sa" is not a word in "Persist", but it is the exact hint code, so
        // it must still be reachable. "other" has the wrong hint and no text
        // match, so it is dropped.
        #expect(rank(candidates, "sa") == ["save"])
    }

    // MARK: - Alias families

    @Test func aliasBtnMatchesButtonRole() {
        let candidates = [
            candidate("submit", label: "Submit", role: "button"),
            candidate("cancel", label: "Cancel", role: "button"),
            candidate("text", label: "A paragraph", role: "static text"),
        ]
        // "btn" must match elements whose role is button; the static text is
        // not matched and is dropped.
        #expect(rank(candidates, "btn") == ["submit", "cancel"])
    }

    @Test func aliasButtonMatchesBtnAbbreviation() {
        let candidates = [
            candidate("submit", label: "Submit", role: "button"),
            candidate("text", label: "A paragraph", role: "static text"),
        ]
        #expect(rank(candidates, "button") == ["submit"])
    }

    @Test func aliasCheckMatchesCheckbox() {
        let candidates = [
            candidate("agree", label: "I agree", role: "checkbox"),
            candidate("cancel", label: "Not now", role: "button"),
        ]
        #expect(rank(candidates, "check") == ["agree"])
    }

    @Test func aliasInputFieldTextfieldAreEquivalent() {
        let candidates = [
            candidate("name", label: "Full name", role: "textfield"),
            candidate("email", label: "Email", role: "textfield"),
            candidate("button", label: "Send", role: "button"),
        ]
        // "input" maps onto the role "textfield"; both match, so the shorter
        // label "Email" breaks the tie.
        #expect(rank(candidates, "input") == ["email", "name"])
    }

    @Test func aliasDeleteRemoveClearDestroyAreEquivalent() {
        let candidates = [
            candidate("trash", label: "Remove", role: "button"),
            candidate("clear", label: "Clear all", role: "button"),
            candidate("keep", label: "Dismiss", role: "button"),
        ]
        // All family members are mutually substitutable.
        #expect(rank(candidates, "delete") == ["trash", "clear"])
        #expect(rank(candidates, "destroy") == ["trash", "clear"])
    }

    @Test func aliasMenuLinkRadioMatchTheirFamilies() {
        let candidates = [
            candidate("bar", label: "File", role: "menubar"),
            candidate("btn", label: "Website", role: "hyperlink"),
            candidate("opt", label: "Pick one", role: "radiobutton"),
            candidate("text", label: "Body", role: "static text"),
        ]
        #expect(rank(candidates, "menu") == ["bar"])
        #expect(rank(candidates, "link") == ["btn"])
        #expect(rank(candidates, "radio") == ["opt"])
    }

    // MARK: - Match-quality ordering

    @Test func exactLabelMatchesOutrankWordPrefixWhichOutranksSubstring() {
        let candidates = [
            candidate("exactLong", label: "Open the dialog", role: ""),
            candidate("exact", label: "Open", role: "button"),
            candidate("prefix", label: "Opened documents", role: ""),
            candidate("substring", label: "Hopener", role: ""),
        ]
        let order = rank(candidates, "open")
        // Exact-word matches (quality 4) come before the word-prefix (3), which
        // comes before the substring-only (2).
        #expect(order == ["exact", "exactLong", "prefix", "substring"])
    }

    @Test func exactLabelOutranksFuzzySubsequence() {
        let candidates = [
            candidate("exact", label: "Save", role: "button"),
            candidate("fuzzy", label: "Server Async View Engine", role: ""),
            candidate("other", label: "Render", role: "button"),
        ]
        // "save" is an exact word for the first, but only a fuzzy subsequence
        // (s…a…v…e across "server async view engine") for the second.
        #expect(rank(candidates, "save") == ["exact", "fuzzy"])
    }

    @Test func wordPrefixOutranksSubstringAndFuzzy() {
        let candidates = [
            candidate("prefix", label: "Windowed", role: ""),
            candidate("substring", label: "Twin beds", role: ""),
            candidate("fuzzy", label: "Wife in Need", role: ""),
        ]
        // "win": "Windowed" is a word prefix (3), "Twin beds" is a substring
        // (2), "Wife in Need" is only a fuzzy subsequence (w…i…n).
        #expect(rank(candidates, "win") == ["prefix", "substring", "fuzzy"])
    }

    @Test func roleAndSearchTextAreMatchSurfaces() {
        let roleOnly = candidate("role", label: "X", role: "button")
        let textOnly = candidate("text", label: "Y", searchText: "click to select", role: "")
        let irrelevant = candidate("no", label: "Z", role: "button")
        // "button" matches roleOnly via its role; "click" matches textOnly via
        // its aggregate search text.
        #expect(rank([roleOnly], "button") == ["role"])
        #expect(rank([textOnly], "click") == ["text"])
        #expect(TypeToClickSearch.rankedIndices(in: [irrelevant], query: "click").isEmpty)
    }

    // MARK: - Tie-breaking

    @Test func shorterLabelsBreakTies() {
        let candidates = [
            candidate("long", label: "Save As"),
            candidate("short", label: "Save"),
        ]
        #expect(rank(candidates, "save") == ["short", "long"])
    }

    @Test func stableOriginalOrderBreaksRemainingTies() {
        let candidates = [
            candidate("first", label: "Open"),
            candidate("second", label: "Open"),
        ]
        #expect(rank(candidates, "open") == ["first", "second"])
    }

    @Test func originalOrderIsPreservedEvenWhenScoresAreIdentical() {
        let candidates = [
            candidate("a", label: "Open", role: "button"),
            candidate("b", label: "Open", role: "button"),
            candidate("c", label: "Open", role: "button"),
        ]
        #expect(rank(candidates, "open") == ["a", "b", "c"])
    }

    // MARK: - Fuzzy / app-menu reachability

    @Test func fuzzySubsequenceStillQualifies() {
        let candidates = [
            candidate("redButton", label: "Red Button", role: ""),
            candidate("glass", label: "Glass", role: ""),
        ]
        // "rb" matches "Red Button" only as a fuzzy subsequence (r…b), yet must
        // still be returned.
        #expect(rank(candidates, "rb") == ["redButton"])
    }

    @Test func nonSpatialCommandIsReachableByTextQuery() {
        let candidates = [
            candidate("saveDoc", label: "Save Document", role: "menu", isSpatial: false),
            candidate("closeDoc", label: "Close Document", role: "menu", isSpatial: false),
        ]
        #expect(rank(candidates, "save") == ["saveDoc"])
    }

    // MARK: - Convenience / Sendable

    @Test func rankedCandidatesReturnsTheCandidatesInRankOrder() {
        let candidates = [
            candidate("save", hint: "a", label: "Save", role: "button"),
            candidate("apple", label: "Apple", role: "button"),
        ]
        let result = TypeToClickSearch.rankedCandidates(candidates, query: "a")
        #expect(result.map(\.id) == ["save", "apple"])
    }

    @Test func preparedIndexCanBeReusedAcrossQueries() {
        let candidates = [
            candidate("save", hint: "sa", label: "Save", role: "button"),
            candidate("open", hint: "op", label: "File › Open", role: "menu", isSpatial: false),
        ]
        let index = TypeToClickSearch.Index(candidates: candidates)
        #expect(ids(candidates, index.rankedIndices(query: "sa")) == ["save"])
        #expect(ids(candidates, index.rankedIndices(query: "file open")) == ["open"])
    }

    @Test func candidateIsSendable() {
        let value = candidate("x", hint: "a", label: "Save", role: "button")
        func requireSendable<T: Sendable>(_ item: T) -> Bool { true }
        #expect(requireSendable(value))
        #expect(requireSendable([value]))
    }
}
