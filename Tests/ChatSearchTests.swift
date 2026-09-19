// ChatSearchTests — the one chat search (spec
// docs/attachments-and-search-spec-20260911.md, section 4): folding (NFKC,
// case, accents, width, no locale), CJK as a substring, AND of terms,
// phrases, the two-character rule, ranking and the pinned rule, snippets
// for Latin and CJK text with the ranges found on the shown text, the
// index's incremental and background builds, and the 200-chat benchmark.

import Foundation
import Testing
@testable import QuickLaunch

@Suite("Chat search")
@MainActor
struct ChatSearchTests {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let provider = UUID()

    private func chat(
        _ question: String,
        answer: String = "An answer.",
        title: String? = nil,
        pinned: Bool = false,
        followUps: [(String, String)] = [],
        days: Double = 0
    ) -> QuickConversation {
        var messages = [
            QuickMessage(role: .user, content: question),
            QuickMessage(role: .assistant, content: answer),
        ]
        for (question, answer) in followUps {
            messages.append(QuickMessage(role: .user, content: question))
            messages.append(QuickMessage(role: .assistant, content: answer))
        }
        return QuickConversation(
            updatedAt: Self.now.addingTimeInterval(-days * 86_400),
            providerID: Self.provider,
            model: "model",
            messages: messages,
            customTitle: title,
            isPinned: pinned
        )
    }

    private func search(_ chats: [QuickConversation], _ query: String) -> [QuickConversation] {
        QuickHistoryStore.matching(chats, query: query, title: { $0.title }, now: Self.now)
    }

    private func titles(_ chats: [QuickConversation], _ query: String) -> [String] {
        search(chats, query).map(\.title)
    }

    // MARK: - Folding (4.3)

    @Test func foldingMapsCompatibilityFormsCaseAccentsAndWidth() {
        #expect(SearchText.fold("ＡＢＣ１２３") == "abc123")
        #expect(SearchText.fold("Café RÉSUMÉ").contains("resume"))
        #expect(SearchText.fold("Straße").contains("strasse"))
        #expect(SearchText.fold("ﬁle") == "file", "a ligature")
        #expect(SearchText.fold("⼈") == "人", "a Kangxi radical")
        #expect(SearchText.fold("İstanbul") == "istanbul", "no locale: the dotted capital folds the same everywhere")
        #expect(SearchText.fold("  two\n\n lines\tand\u{00A0}more  ") == "two lines and more")
    }

    @Test func aChatMatchesWhateverTheCaseAccentsOrWidth() {
        let chats = [
            chat("Café résumé tips"),
            chat("Die Straße"),
            chat("Order ＡＢＣ１２３"),
            chat("Unrelated"),
        ]
        #expect(titles(chats, "CAFE RESUME") == ["Café résumé tips"])
        #expect(titles(chats, "strasse") == ["Die Straße"])
        #expect(titles(chats, "abc123") == ["Order ＡＢＣ１２３"])
        #expect(titles(chats, "ＡＢＣ") == ["Order ＡＢＣ１２３"], "a full-width query too")
    }

    @Test func cjkIsASubstringAndOneCJKCharacterIsAQuery() {
        let chats = [
            chat("季度报告收入增长"),
            chat("去年的计划"),
        ]
        #expect(titles(chats, "收入") == ["季度报告收入增长"])
        #expect(titles(chats, "报告收入增长") == ["季度报告收入增长"], "a query with no spaces is one term")
        #expect(titles(chats, "划") == ["去年的计划"], "one CJK character is a valid query")
        // Simplified and Traditional are not folded into each other in v1.
        #expect(titles(chats, "報告").isEmpty)
    }

    // MARK: - Terms (4.4)

    @Test func everyTermMustMatchSomewhere() {
        let chats = [
            chat("Pricing notes", answer: "The quarterly revenue includes the rebate."),
            chat("Revenue plan", answer: "Nothing about rebates."),
            chat("Other"),
        ]
        #expect(titles(chats, "revenue rebate").sorted() == ["Pricing notes", "Revenue plan"])
        #expect(titles(chats, "revenue quarterly") == ["Pricing notes"], "a term may match any field")
        #expect(titles(chats, "revenue nowhere").isEmpty)
    }

    @Test func doubleQuotesMakeOnePhrase() {
        let chats = [
            chat("A", answer: "the quarterly revenue grew"),
            chat("B", answer: "revenue fell, quarterly numbers too"),
        ]
        #expect(titles(chats, "quarterly revenue").sorted() == ["A", "B"])
        #expect(titles(chats, "\"quarterly revenue\"") == ["A"])
        #expect(titles(chats, "\u{201C}quarterly revenue\u{201D}") == ["A"], "curly quotes too")
        #expect(ChatSearchQuery("\"quarterly   revenue\" grew").terms.map(\.foldedText) == ["quarterly revenue", "grew"])
    }

    @Test func aOneLetterTermIsIgnoredUnlessItIsTheWholeCJKQuery() {
        #expect(ChatSearchQuery("a").isEmpty, "one Latin letter is not a search")
        #expect(ChatSearchQuery("q plan").terms.map(\.foldedText) == ["plan"])
        #expect(ChatSearchQuery("收").terms.map(\.foldedText) == ["收"])
        #expect(ChatSearchQuery("收 plan").terms.map(\.foldedText) == ["plan"], "only a whole query")
        #expect(ChatSearchQuery("Plan plan PLAN").terms.count == 1, "repeats count once")
        let chats = [chat("Beta"), chat("Alpha", days: 1)]
        #expect(titles(chats, "a") == ["Beta", "Alpha"], "an ignored query keeps the full list")
    }

    // MARK: - Ranking (4.5)

    @Test func aTitleHitBeatsABodyHitAndAWordStartBeatsTheMiddle() {
        let chats = [
            chat("Weekly sync", answer: "We talked about the budget.", days: 0),
            chat("Budget review", days: 3),
            chat("Rebudgeting", days: 3),
            chat("Planning", followUps: [("what budget is left?", "Some.")], days: 0),
        ]
        #expect(titles(chats, "budget") == ["Budget review", "Rebudgeting", "Planning", "Weekly sync"])
    }

    @Test func aRecentHitBeatsTheSameHitInAnOlderChatAndTiesGoToTheNewest() {
        let chats = [
            chat("Lima trip", days: 20),
            chat("Lima office", days: 1),
            chat("Lima food", days: 5),
        ]
        #expect(titles(chats, "lima") == ["Lima office", "Lima food", "Lima trip"])
        let score = { (days: Double) -> Double in
            let document = ChatSearchDocument(ChatSearchSource(chats[0], title: "Lima"))
            return ChatSearch.score(
                document,
                query: ChatSearchQuery("lima"),
                isPinned: false,
                updatedAt: Self.now.addingTimeInterval(-days * 86_400),
                now: Self.now
            )?.score ?? 0
        }
        #expect(abs(score(0) - 150) < 0.001, "title word start 120 + recency 30")
        #expect(abs(score(14) - (120 + 30 * exp(-1))) < 0.001, "recency decays over two weeks")
    }

    @Test func pinnedChatsAreNotFloatedAboveBetterMatches() {
        let chats = [
            chat("Old pinned", answer: "the budget, briefly", pinned: true, days: 0),
            chat("Budget plan", days: 10),
            chat("Two", answer: "budget", days: 0),
        ]
        // With a query: one flat ranked list, the pin only a small boost.
        #expect(titles(chats, "budget") == ["Budget plan", "Old pinned", "Two"])
        // With none: today's order, pinned first.
        #expect(titles(chats, "") == ["Old pinned", "Two", "Budget plan"])
    }

    @Test func attachmentNamesWeighBetweenTitleAndQuestion() {
        let withFile = chat("Numbers", days: 0)
        let withQuestion = chat("Other", followUps: [("the q3 report again", "Sure.")], days: 0)
        let sources = [
            ChatSearchSource(withFile, title: "Numbers", attachments: [.init(kind: .file, name: "Q3 report.pdf")]),
            ChatSearchSource(withQuestion, title: "Other"),
        ]
        let query = ChatSearchQuery("report")
        let ranked = ChatSearch.rank(
            [withQuestion, withFile],
            query: query,
            document: { conversation in ChatSearchDocument(sources.first { $0.id == conversation.id }!) },
            now: Self.now
        )
        #expect(ranked.map(\.conversation.id) == [withFile.id, withQuestion.id])
        #expect(ranked.first?.hit.firstTermField == .attachment)
        let snippet = ChatSearch.snippet(
            document: ChatSearchDocument(sources[0]), source: sources[0], query: query
        )
        #expect(snippet?.label == "Attachment:")
        #expect(snippet?.text == "Q3 report.pdf")
        let link = ChatSearchSource(withFile, title: "Numbers", attachments: [.init(kind: .link, name: "Report · example.com")])
        #expect(ChatSearch.snippet(document: ChatSearchDocument(link), source: link, query: query)?.label == "Link:")
    }

    @Test func aFuzzyTitleMatchIsTheFallbackWhenNothingMatchesAsWritten() {
        let chats = [
            chat("Quarterly plan", days: 3),
            chat("Other", answer: "quarterly numbers", days: 0),
        ]
        #expect(titles(chats, "qrtly") == ["Quarterly plan"], "the letters in order")
        #expect(titles(chats, "quarterly") == ["Quarterly plan", "Other"], "a literal hit is never a fuzzy one")
        #expect(titles(chats, "qr").isEmpty, "too short to guess")
    }

    // MARK: - Snippets (4.6)

    @Test func aSnippetShowsTheHitInItsFieldWithAWindowCutAtWords() throws {
        let question = "Before we start, I need to know whether the quarterly revenue include the rebate or whether it is shown on its own line in the report"
        let conversation = chat("Pricing notes", followUps: [(question, "Yes.")])
        let source = ChatSearchSource(conversation, title: "Pricing notes")
        let snippet = try #require(ChatSearch.snippet(
            document: ChatSearchDocument(source), source: source, query: ChatSearchQuery("REVENUE rebate")
        ))
        #expect(snippet.label == "You:")
        #expect(snippet.text.hasPrefix("\u{2026}"))
        #expect(snippet.text.hasSuffix("\u{2026}"))
        #expect(snippet.text.contains("quarterly revenue include the rebate"))
        // Cut at a word: no half word after the ellipsis.
        let firstWord = try #require(snippet.text.dropFirst().split(separator: " ").first)
        #expect(question.split(separator: " ").contains(firstWord))
        // Every term is marked, as written in the text.
        #expect(snippet.runs.filter(\.isMatch).map(\.text) == ["revenue", "rebate"])
        #expect(snippet.plainText.hasPrefix("You: "))
        // A title hit has no snippet: the title shows it.
        #expect(ChatSearch.snippet(
            document: ChatSearchDocument(source), source: source, query: ChatSearchQuery("pricing")
        ) == nil)
    }

    @Test func aSnippetFromAnAnswerSaysAnswer() throws {
        let conversation = chat("Question", answer: "Line one.\n\nThe **revenue** grew.")
        let source = ChatSearchSource(conversation, title: "Question")
        let snippet = try #require(ChatSearch.snippet(
            document: ChatSearchDocument(source), source: source, query: ChatSearchQuery("revenue")
        ))
        #expect(snippet.label == "Answer:")
        // One line: white space runs become one space, and no Markdown marks.
        #expect(snippet.text == "Line one. The revenue grew.")
        #expect(snippet.runs.filter(\.isMatch).map(\.text) == ["revenue"])
    }

    @Test func aCJKSnippetIsCutAtCharacters() throws {
        let text = String(repeating: "这是一个很长的句子", count: 8) + "季度报告收入增长" + String(repeating: "后面还有很多文字", count: 8)
        let snippet = try #require(ChatSnippet.make(label: "You:", text: text, query: ChatSearchQuery("收入")))
        let matches = snippet.runs.filter(\.isMatch).map(\.text)
        #expect(matches == ["收入"])
        let lead = try #require(snippet.runs.first?.text)
        // 40 characters of context, cut at a character, after the ellipsis.
        #expect(lead.hasPrefix("\u{2026}"))
        #expect(lead.count == ChatSnippet.context + 1)
        #expect(snippet.text.hasSuffix("\u{2026}"))
    }

    @Test func snippetRangesAreFoundOnTheShownTextNotTheFoldedCopy() throws {
        // "ß" folds to "ss", so an offset in the folded copy would be one
        // off after it; the marked run must be the shown "Straße".
        let text = "Größe, Maße und die Straße nach Köln"
        let snippet = try #require(ChatSnippet.make(label: "You:", text: text, query: ChatSearchQuery("strasse")))
        #expect(snippet.runs.filter(\.isMatch).map(\.text) == ["Straße"])
        #expect(snippet.text == text)
        // Find in Chat uses the same rule: UTF-16 ranges on the shown text.
        let ranges = SearchText.ranges(of: "strasse", in: text)
        #expect(ranges.count == 1)
        #expect((text as NSString).substring(with: ranges[0].nsRange) == "Straße")
        #expect(SearchText.ranges(of: "resume", in: "Résumé, résumé").count == 2)
        #expect(SearchText.ranges(of: "abc", in: "ＡＢＣ abc").count == 2, "full width too")
    }

    @Test func aNarrowRowKeepsAShortLead() throws {
        let text = "Before we start, I need to know whether the quarterly revenue include the rebate"
        let snippet = try #require(ChatSnippet.make(label: "You:", text: text, query: ChatSearchQuery("revenue")))
        let short = snippet.keepingLead(12)
        let lead = try #require(short.runs.first?.text)
        #expect(lead.hasPrefix("\u{2026}"))
        #expect(lead.count <= 13)
        #expect(short.runs.filter(\.isMatch).map(\.text) == ["revenue"])
        #expect(short.label == "You:")
    }

    // MARK: - The view model's rows

    @Test func theRowsCarryASnippetOnlyForATextHitAndSearchOncePerQuery() {
        var settings = QuickSettings()
        settings.historyEnabled = true
        let vm = QuickViewModel(settings: settings, service: MockQuickService())
        vm.history = [
            chat("Pricing notes", answer: "The quarterly revenue includes the rebate.", days: 1),
            chat("Revenue plan", days: 2),
        ]
        let rows = vm.chatItems(matching: "revenue")
        #expect(rows.map(\.title) == ["Revenue plan", "Pricing notes"], "the title hit first")
        #expect(rows[0].chatSnippet == nil)
        #expect(rows[1].chatSnippet?.label == "Answer:")
        #expect(rows[1].detail.hasPrefix("1 question · "), "the count and time stay on the row")
        #expect(vm.chatItems(matching: "") .allSatisfy { $0.chatSnippet == nil })
        // Read again: the same rows, from the cache.
        #expect(vm.chatItems(matching: "revenue") == rows)
        // A new turn changes the rows.
        vm.history[1].messages.append(QuickMessage(role: .user, content: "and revenue?"))
        vm.history[1].updatedAt = Self.now
        #expect(vm.chatItems(matching: "revenue").map(\.title) == ["Revenue plan", "Pricing notes"])
        #expect(vm.chatItems(matching: "and revenue").first?.title == "Revenue plan")
    }

    // MARK: - The index (4.7)

    @Test func theIndexRebuildsOnlyChatsWhoseStampMoved() {
        let index = ChatSearchIndex(backgroundThreshold: nil)
        var chats = [chat("Alpha"), chat("Beta")]
        let sources = { chats.map { ChatSearchSource($0, title: $0.title) } }
        index.update(sources())
        #expect(index.documentCount == 2)
        let before = index.document(id: chats[1].id)?.stamp
        chats[0].messages.append(QuickMessage(role: .user, content: "kyoto"))
        index.update(sources())
        #expect(index.document(id: chats[1].id)?.stamp == before, "the other chat is untouched")
        #expect(index.document(id: chats[0].id)?.stamp.messageCount == 3)
        #expect(QuickHistoryStore.matching(chats, query: "kyoto", title: { $0.title }, index: index).map(\.title) == ["Alpha"])
        // A rename is a new stamp too; a delete drops the document.
        chats[1].customTitle = "Gamma"
        chats.remove(at: 0)
        index.update(sources())
        #expect(index.documentCount == 1)
        #expect(index.document(id: chats[0].id)?.titleText == "gamma")
    }

    @Test func aLargeFirstBuildRunsInTheBackgroundAndTitlesMatchUntilItLands() async {
        let index = ChatSearchIndex(backgroundThreshold: 10)
        let chats = [
            chat("Trip plan", answer: "Kyoto in spring, then Osaka."),
            chat("Kyoto notes", answer: "Temples."),
        ]
        let revision = index.revision
        index.update(chats.map { ChatSearchSource($0, title: $0.title) })
        #expect(index.isBuilding)
        // Until it lands, only titles are searched.
        #expect(QuickHistoryStore.matching(chats, query: "kyoto", title: { $0.title }, index: index).map(\.title)
            == ["Kyoto notes"])
        await index.waitForBuild()
        #expect(!index.isBuilding)
        #expect(index.revision != revision, "the lists read again when it lands")
        #expect(Set(QuickHistoryStore.matching(chats, query: "kyoto", title: { $0.title }, index: index).map(\.title))
            == ["Kyoto notes", "Trip plan"])
    }

    @Test func aLargeBatchDuringABuildIsParkedNotFoldedOnTheMainActor() async {
        let index = ChatSearchIndex(backgroundThreshold: 10)
        let first = chat("First build", answer: String(repeating: "Kyoto temple. ", count: 40))
        index.update([ChatSearchSource(first, title: first.title)])
        #expect(index.isBuilding)

        let second = chat("Second batch", answer: "Osaka in spring, then Nara.")
        index.update([ChatSearchSource(second, title: second.title)])
        // The batch is parked for the next background build, so its body text
        // is not folded inline while the first build is in flight.
        #expect(QuickHistoryStore.matching(
            [first, second], query: "osaka", title: { $0.title }, index: index
        ).isEmpty)

        await index.waitForBuild()
        #expect(!index.isBuilding)
        #expect(QuickHistoryStore.matching(
            [first, second], query: "osaka", title: { $0.title }, index: index
        ).map(\.title) == ["Second batch"])
    }

    /// The spec's worst case: 200 chats × 12 messages, 300-character
    /// questions and 4,500-character answers (about 6.5 MB). A query must
    /// stay under 10 ms once the index is built.
    @Test func twoHundredLongChatsAnswerAQueryInUnderTenMilliseconds() {
        let words = ["release", "budget", "kyoto", "temple", "garden", "quarterly", "revenue", "rebate", "notes",
                     "plan", "design", "window", "search", "answer", "question", "model", "token", "context"]
        func text(_ length: Int, seed: Int) -> String {
            var output = ""
            var index = UInt(seed)
            while output.utf8.count < length {
                output += words[Int(index % UInt(words.count))] + (index % 7 == 0 ? ". " : " ")
                index = index &* 31 &+ 7
            }
            return output
        }
        var chats: [QuickConversation] = []
        for number in 0..<200 {
            var messages: [QuickMessage] = []
            for turn in 0..<6 {
                let seed = number * 12 + turn
                messages.append(QuickMessage(role: .user, content: text(300, seed: seed)))
                messages.append(QuickMessage(role: .assistant, content: text(4_500, seed: seed + 1)))
            }
            let updatedAt: Date = Self.now.addingTimeInterval(-Double(number) * 3_600)
            chats.append(QuickConversation(
                updatedAt: updatedAt,
                providerID: Self.provider,
                model: "model",
                messages: messages,
                isPinned: number % 50 == 0
            ))
        }
        var size = 0
        for chat in chats { for message in chat.messages { size += message.content.utf8.count } }
        #expect(size > 5_500_000, "about 6.5 MB once saved as JSON")
        let index = ChatSearchIndex(backgroundThreshold: nil)
        index.update(chats.map { ChatSearchSource($0, title: $0.title) })
        #expect(index.documentCount == 200)

        let clock = ContinuousClock()
        for query in ["nothing matches this", "kyoto revenue", "\"quarterly revenue\"", "zzqx", "release"] {
            // Best of five, so a busy test run never fails the guard; the
            // debug build answers in about 1 to 5 ms.
            var best = Duration.seconds(1)
            for _ in 0..<5 {
                let elapsed = clock.measure {
                    _ = QuickHistoryStore.matching(chats, query: query, title: { $0.title }, index: index, now: Self.now)
                }
                best = min(best, elapsed)
            }
            #expect(best < .milliseconds(10), "\(query): \(best)")
        }
    }
}
