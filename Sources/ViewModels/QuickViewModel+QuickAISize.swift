import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

/// Quick AI window size.
///
/// Moved out of QuickViewModel.swift unchanged.
extension QuickViewModel {

    // MARK: - Quick AI size

    /// The Quick AI surface's size: the one the user dragged it to, never
    /// below the standard 750 × 475. The AppDelegate clamps it to the
    /// display (`PanelSizing.quickAIPlacedSize`) before it compares or
    /// applies the frame; the stored value keeps the user's choice for a
    /// larger display.
    var quickAISize: CGSize { settings.quickAISize.atLeastStandard.cgSize }

    /// True while Quick AI is up at a size the user dragged: a programmatic
    /// resize then keeps the window's centre where the drag left it. Root
    /// search, and Quick AI back at 750 × 475 (Reset), centre on the
    /// launcher's anchor, so a one-edge drag never moves the search field.
    var keepsUserSizedFrame: Bool {
        isQuickAIPresented && !settings.quickAISize.isStandard
    }

    /// Remembers the size the user dragged the panel to, once the drag
    /// ends. Only while the Quick AI surface is up: root search is never
    /// user-sized. Returns true when a new size was stored.
    @discardableResult
    func rememberQuickAISize(_ size: CGSize) -> Bool {
        guard isQuickAIPresented else { return false }
        let remembered = QuickAISize(size).atLeastStandard
        let current = settings.quickAISize.atLeastStandard
        guard abs(remembered.width - current.width) >= 1
            || abs(remembered.height - current.height) >= 1
        else { return false }
        updateSettings { $0.quickAISize = remembered }
        return true
    }

    /// ⌘K › Reset Quick AI Size: back to 750 × 475. The window follows on
    /// the next resize pass.
    func resetQuickAISize() {
        guard !settings.quickAISize.isStandard else { return }
        updateSettings { $0.quickAISize = .standard }
    }

    struct GridSection: Equatable {
        let title: String
        let range: Range<Int>
    }

    /// Section headers over `launcherMatches` in the emoji grid.
    var gridSections: [GridSection] {
        guard isGridCatalog, catalogScope == .emoji else { return [] }
        let count = launcherMatches.count
        guard count > 0 else { return [] }
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty, emojiFavouriteCount > 0 {
            let favourites = min(emojiFavouriteCount, count)
            var sections = [GridSection(title: "Frequently Used", range: 0..<favourites)]
            if favourites < count { sections.append(GridSection(title: "All", range: favourites..<count)) }
            return sections
        }
        return [GridSection(title: query.isEmpty ? "All" : "Results", range: 0..<count)]
    }

    private var emojiFavouriteCount: Int {
        guard settings.launcherLearningEnabled else { return 0 }
        return min(18, launcherUsage.topItemIDs(scope: LauncherCatalogScope.emoji.rawValue, limit: 18).count)
    }

    static func maxRows(for scope: LauncherCatalogScope?) -> Int {
        scope == .emoji ? maxGridCells : maxLauncherRows
    }

    func screenshotText(for item: LauncherCatalogItem) -> String? {
        screenshotTextIndex.text(for: item)
    }
    /// Learned favourites shown above the catalog roots when nothing is typed.
    static let emptyQueryFavouriteRows = 2

    var catalogMatches: [LauncherCatalogItem] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // The Chats catalog is Recent Chats' list: the same order (pinned,
        // then newest), the same search (title and message text), every
        // chat. Learned favourites never reorder it. `chatItems` already
        // drops hidden chats.
        if catalogScope == .chats { return chatItems(matching: query) }
        // Hidden rows leave before ranking, so row caps, learned favourites,
        // and pins all see the same visible set.
        let items = visibleLauncherItems(catalogItems)
        let scope = catalogScope?.rawValue ?? LauncherUsageStore.rootScope
        let rows = effectiveRowLimit
        // Clipboard grammar (`source:`/`tag:`/`kind:`/`pin:`) narrows the list
        // and is stripped from the free-text needle, so the visible hint and
        // the results agree. The segmented control's filter still applies
        // underneath through `catalogItems`.
        if catalogScope == .clipboard, !query.isEmpty {
            let parsed = ClipboardFilterQuery.parse(query)
            var filter = clipboardCatalogFilter
            if let source = parsed.source { filter.sourceName = source }
            if let tag = parsed.tag { filter.tag = tag }
            if !parsed.kinds.isEmpty { filter.kinds = parsed.kinds }
            if parsed.pinnedOnly { filter.pinnedOnly = true }
            let narrowed = items.filter(filter.matches)
            guard !parsed.needle.isEmpty else { return Array(narrowed.prefix(rows)) }
            let foldedNeedle = FuzzyMatcher.fold(parsed.needle)
            return Array(narrowed.compactMap { item -> (LauncherCatalogItem, Int)? in
                guard let score = matchScore(
                    foldedQuery: foldedNeedle,
                    title: item.title,
                    alias: launcherItemAlias(for: item),
                    keywords: item.keywords
                ) else { return nil }
                return (item, score)
            }
            .sorted { lhs, rhs in
                lhs.1 == rhs.1
                    ? lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
                    : lhs.1 > rhs.1
            }
            .prefix(rows)
            .map(\.0))
        }
        guard !query.isEmpty else {
            // Time-ordered catalogs stay chronological: the clipboard store
            // and the screenshots list already put pins first, and learned
            // favourites must never shuffle a dated list.
            guard catalogScope != .clipboard, catalogScope != .screenshots,
                  settings.launcherLearningEnabled else {
                return Array(items.prefix(rows))
            }
            let favouriteLimit = catalogScope == .emoji ? 18 : rows
            let favourites = launcherUsage.topItemIDs(scope: scope, limit: favouriteLimit)
            let pinned = items.filter(\.isPinned)
            let ordered = pinned + favourites.compactMap { id in items.first { $0.id == id && !$0.isPinned } }
            let rest = items.filter { item in !ordered.contains { $0.id == item.id } }
            return Array((ordered + rest).prefix(rows))
        }
        let signals = learnedSignals(query: query, scope: scope)
        if catalogScope == .screenshots {
            let parsed = ScreenshotQuery.parse(query)
            let windowed = items.filter { item in
                guard let interval = parsed.interval else { return true }
                guard let capturedAt = item.capturedAt else { return parsed.needle.isEmpty ? false : true }
                return interval.contains(capturedAt)
            }
            guard !parsed.needle.isEmpty else { return Array(windowed.prefix(rows)) }
            let variants = Self.searchVariants(for: parsed.needle)
            // One normalized form per variant for OCR containment.
            let literals = variants.map(ScreenshotTextIndex.normalize)
            return Array(windowed.compactMap { item -> (LauncherCatalogItem, Int)? in
                var best: Int?
                var titleHit = false
                for (index, variant) in variants.enumerated() {
                    if let score = matchScore(foldedQuery: variant, title: item.title, alias: launcherItemAlias(for: item), keywords: item.keywords) {
                        best = max(best ?? 0, score + 1_000)
                        titleHit = true
                    }
                    // Text inside the image: literal, whitespace-flattened,
                    // all words present, tried per plural variant.
                    if item.kind == .screenshot, settings.screenshotTextSearch,
                       let text = screenshotTextIndex.normalizedText(for: item) {
                        let literal = literals[index]
                        let words = literal.split(separator: " ").map(String.init)
                        if !literal.isEmpty,
                           text.contains(literal) || (words.count > 1 && words.allSatisfy { text.contains($0) }) {
                            best = max(best ?? 0, 500)
                        }
                    }
                }
                guard let score = best else { return nil }
                var matched = item
                if !titleHit, !(matched.title.lowercased().contains(literals[0])), matched.kind == .screenshot {
                    matched.detail = "Text match · " + matched.detail
                }
                return (matched, score + LauncherRanker.boost(for: signals[item.id]) + pinBoost(item))
            }
            .sorted { $0.1 == $1.1 ? ($0.0.capturedAt ?? .distantPast) > ($1.0.capturedAt ?? .distantPast) : $0.1 > $1.1 }
            .prefix(rows)
            .map(\.0))
        }
        let foldedQuery = FuzzyMatcher.fold(query)
        return Array(items.compactMap { item -> (LauncherCatalogItem, Int)? in
            guard let score = matchScore(
                foldedQuery: foldedQuery,
                title: item.title,
                alias: launcherItemAlias(for: item),
                keywords: item.keywords
            ) else { return nil }
            return (item, score + LauncherRanker.boost(for: signals[item.id]) + pinBoost(item))
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1
                ? lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
                : lhs.1 > rhs.1
        }
        .prefix(rows)
        .map(\.0))
    }

    /// Everything the root launcher can reach in one keystroke, ranked in one
    /// list: apps, commands, catalog roots, snippets, and quick links. Learned
    /// choices outrank fuzzy text matches.
    ///
    /// The view, the footer, and the panel sizer all read this several times
    /// per keystroke, so one ranking pass is cached until any input changes.
    var launcherMatches: [LauncherSearchResult] {
        let key = launcherMatchesCacheKey
        if let cached = launcherMatchesCache, cached.key == key { return cached.value }
        let value = rankLauncherMatches()
        launcherMatchesCache = (key, value)
        return value
    }

    private var launcherMatchesCacheKey: String {
        var parts: [String] = []
        parts.append(input)
        parts.append(catalogScope?.rawValue ?? "")
        parts.append(pendingQuickLinkID ?? "")
        parts.append(hasPendingAttachment ? "1" : "0")
        parts.append(isAnswerActive ? "1" : "0")
        parts.append(rootAnswer == nil ? "" : "local")
        parts.append(inlineTranslation.map { "\($0.status)\u{0}\($0.text)" } ?? "")
        parts.append(inputMode == nil ? "" : "mode")
        parts.append(pendingHouseChoice?.row.id ?? "")
        parts.append(houseCommandRows.map(\.id).joined(separator: ","))
        parts.append(String(snippets.count))
        parts.append(String(quickLinks.count))
        parts.append(String(clipboardHistory?.revision ?? 0))
        parts.append(String(history.count))
        let pinnedChats = history.filter { $0.isPinned }.count
        parts.append(String(pinnedChats))
        // The Chats catalog follows every chat's time and name, which the
        // other view can change without changing the count.
        if catalogScope == .chats {
            parts.append(history.map { "\($0.id)\($0.updatedAt.timeIntervalSinceReferenceDate)\($0.customTitle ?? "")" }.joined())
        }
        parts.append(isCaffeinating ? "1" : "0")
        // The status row shows minutes left, so the cache turns over with them.
        parts.append(caffeinateEndsAt.map { String(Int($0.timeIntervalSince(now()) / 60)) } ?? "-")
        parts.append(caffeinateReason ?? "")
        parts.append(settings.launcherLearningEnabled ? "1" : "0")
        parts.append(settings.savedPromptPrefix)
        parts.append(String(settings.launcherItemConfigurations.hashValue))
        parts.append(String(launcherRankingVersion))
        parts.append(String(applicationCatalog?.version ?? 0))
        parts.append(activeModelDisplay)
        // The Ask AI row carries the Tab hint and, when the first Fallback
        // Command is not Ask AI, that command's name: both change the row.
        parts.append(settings.tabShortcutHintVisible ? "hint" : "nohint")
        parts.append(settings.fallbackCommandIDs.joined(separator: ","))
        return parts.joined(separator: "\u{1F}")
    }

    /// The Quick AI surface owns the panel: no launcher rows, typing asks
    /// the model. A thread kept behind root search is not active.
    var isAnswerActive: Bool { isQuickAIPresented }

    private func rankLauncherMatches() -> [LauncherSearchResult] {
        // A local answer under the input row stands in for the rows until
        // the next keystroke, as v1.3.0's answer block did.
        if pendingHouseChoice != nil, !hasPendingAttachment, !isAnswerActive, inputMode == nil {
            return houseChoiceItems.map(LauncherSearchResult.item)
        }
        guard !hasPendingAttachment, !isAnswerActive, inputMode == nil, rootAnswer == nil else { return [] }
        if catalogScope != nil {
            return catalogMatches.map(LauncherSearchResult.item)
        }
        guard pendingQuickLinkID == nil else { return [] }
        let roots = LauncherCatalogScope.allCases.map { scope in
            LauncherSearchResult.catalog(scope, count: catalogCount(scope))
        }
        guard let query = rootLauncherQuery else {
            guard input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let favourites = emptyQueryFavourites
            let ask = LauncherSearchResult.item(askAIItem(query: ""))
            let ordered = favourites.contains { $0.id == ask.id } ? favourites + roots : favourites + [ask] + roots
            return Array(ordered.prefix(Self.maxLauncherRows))
        }
        let signals = learnedSignals(query: query, scope: LauncherUsageStore.rootScope)
        let hidden = hiddenLauncherItemIDs()
        let foldedQuery = FuzzyMatcher.fold(query)
        var scored: [(LauncherSearchResult, Int)] = []

        // Ask AI is always in the list. Its base score follows the shape of
        // the text; pins, aliases, and learning add to it like any other row.
        let ask = askAIItem(query: query)
        var askScore = AskAIRanker.baseScore(for: query)
        let askAlias = launcherItemAlias(for: ask)
        if !askAlias.isEmpty, FuzzyMatcher.fold(askAlias) == foldedQuery { askScore += 12_000 }
        askScore += LauncherRanker.boost(for: signals[ask.id]) + pinBoost(ask)
        scored.append((.item(ask), askScore))

        for root in roots {
            guard case .catalog(let scope, _) = root else { continue }
            let best = scope.aliases.compactMap { alias in
                matchScore(foldedQuery: foldedQuery, title: scope.title, alias: alias)
            }.max()
            guard let best else { continue }
            scored.append((root, best + LauncherRanker.boost(for: signals[root.id])))
        }
        for (application, score) in scoredApplications(
            foldedQuery: foldedQuery,
            signals: signals,
            hiddenIDs: hidden
        ) {
            scored.append((.application(application), score))
        }
        for item in systemCommands + folderItems + snippets + quickLinks + settingsDestinationItems {
            // A hidden row is gone from search even when an alias, pin, or
            // learned abbreviation still points at it.
            guard !hidden.contains(item.id) else { continue }
            guard let score = matchScore(
                foldedQuery: foldedQuery,
                title: item.title,
                alias: launcherItemAlias(for: item),
                keywords: item.kind == .command || item.kind == .folder ? item.keywords : ""
            ) else { continue }
            scored.append((.item(item), score + LauncherRanker.boost(for: signals[item.id]) + pinBoost(item)))
        }
        // A web address typed in full opens in the Quick Link browser. The
        // item id carries a stable content digest, not the address itself, so
        // nothing that records identifiers — learned ranking, the interaction
        // journal — ever sees what was typed.
        if let url = TypedURLDetector.url(from: query) {
            let item = LauncherCatalogItem(
                kind: .quickLink,
                itemID: "typed:" + StableIdentifier.make(url.absoluteString),
                title: "Open " + (url.host ?? url.absoluteString),
                detail: url.absoluteString,
                value: url.absoluteString
            )
            scored.append((.item(item), 13_000))
        }
        // Math, conversions, dates, and system facts answer inline, above everything.
        if let answer = localAnswer(for: query) {
            scored.append((.item(Self.answerItem(RootAnswer(question: query, answer: answer))), 14_000))
        } else if let translation = inlineTranslation, InlineTranslationQuery.parse(query) == translation.query {
            // A whole language name reads as a request to translate; a
            // prefix ("time in japan") sits just under Ask AI.
            let score = translation.query.namesLanguageExactly ? 13_500 : AskAIRanker.promptScore - 50
            scored.append((.item(Self.inlineTranslationItem(translation)), score))
        }
        var ranked = scored
            .sorted { lhs, rhs in
                lhs.1 == rhs.1
                    ? Self.displayTitle(lhs.0).localizedCaseInsensitiveCompare(Self.displayTitle(rhs.0)) == .orderedAscending
                    : lhs.1 > rhs.1
            }
            .map(\.0)
        let askID = LauncherSearchResult.item(ask).id
        let unboostedSingleWord = AskAIRanker.baseScore(for: query) == AskAIRanker.wordScore
            && askScore == AskAIRanker.wordScore
        if unboostedSingleWord {
            ranked.removeAll { $0.id == askID }
            ranked = Array(ranked.prefix(Self.maxLauncherRows - 1))
            ranked.append(.item(ask))
        } else if ranked.count > Self.maxLauncherRows {
            if let position = ranked.firstIndex(where: { $0.id == askID }), position >= Self.maxLauncherRows {
                // Keep the row reachable: it takes the last visible slot.
                ranked.remove(at: position)
                ranked.insert(.item(ask), at: Self.maxLauncherRows - 1)
            }
            ranked = Array(ranked.prefix(Self.maxLauncherRows))
        }
        return ranked
    }

    /// The inline answer row, and what Return on a root answer does: the
    /// answer as the title, the question as the detail; Return copies.
    static func answerItem(_ answer: RootAnswer) -> LauncherCatalogItem {
        LauncherCatalogItem(
            kind: .answer,
            itemID: "answer",
            title: answer.answer,
            detail: answer.question,
            value: answer.answer,
            keywords: "answer result"
        )
    }

    static func inlineTranslationItem(_ translation: InlineTranslation) -> LauncherCatalogItem {
        let title = switch translation.status {
        case .translating: translation.text.isEmpty ? "Translating…" : translation.text
        case .ready: translation.text
        case .failed: "Translation unavailable"
        }
        return LauncherCatalogItem(
            kind: .answer,
            itemID: LauncherCatalogItem.inlineTranslationItemID,
            title: title,
            detail: "\(translation.query.target.title) · \(translation.query.phrase)",
            value: translation.status == .ready ? translation.text : "",
            keywords: "translate translation"
        )
    }

    /// The footer's context while a local answer is on root search.
    static let rootAnswerContext = "Local answer"

    /// Deterministic answers computed as you type. None of these touch a model.
    func localAnswer(for query: String, allowConversions: Bool = true) -> String? {
        if MathExpressionDetector.isMathExpression(query),
           let value = try? MathCalculator.evaluate(query) {
            return MathCalculator.format(value)
        }
        if allowConversions, let converted = LocalConversionResolver.answer(query) { return converted }
        return SystemFactsResolver.answer(query)
    }

    private func pinBoost(_ item: LauncherCatalogItem) -> Int {
        item.isPinned ? LauncherRanker.pinnedBoost : 0
    }

    /// Most-used root results, shown before the catalog roots on an empty query.
    private var emptyQueryFavourites: [LauncherSearchResult] {
        guard settings.launcherLearningEnabled else { return [] }
        let ids = launcherUsage.topItemIDs(
            scope: LauncherUsageStore.rootScope,
            limit: Self.emptyQueryFavouriteRows * 3
        )
        var favourites: [LauncherSearchResult] = []
        for id in ids where favourites.count < Self.emptyQueryFavouriteRows {
            if let result = rootResult(id: id) { favourites.append(result) }
        }
        return favourites
    }

    private func rootResult(id: String) -> LauncherSearchResult? {
        // A hidden row is never a favourite: an alias, pin, or use count
        // must not resurface it on the empty query.
        let hidden = hiddenLauncherItemIDs()
        guard !hidden.contains(id) else { return nil }
        if id == LauncherCatalogItem(kind: .askAI, itemID: Self.askAIItemID, title: "", detail: "", value: "").id {
            return .item(askAIItem(query: ""))
        }
        if let application = applications.first(where: {
            LauncherSearchResult.application($0).id == id
        }) {
            return .application(application)
        }
        if let item = (systemCommands + folderItems + snippets + quickLinks + settingsDestinationItems).first(where: { $0.id == id }) {
            return .item(item)
        }
        return nil
    }

    static func displayTitle(_ result: LauncherSearchResult) -> String {
        switch result {
        case .application(let application): application.name
        case .catalog(let scope, _): scope.title
        case .item(let item): item.title
        }
    }

    static func displayDetail(_ result: LauncherSearchResult) -> String {
        switch result {
        case .application: "Application"
        case .catalog(let scope, let count):
            count > 0 ? "\(scope.title), \(catalogCountDetail(count))" : scope.title
        case .item(let item): item.detail
        }
    }

    /// "1 item", "12 items"; a zero count is left off by the caller.
    static func catalogCountDetail(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// The trailing type label tells rows apart; when every visible row is
    /// the same kind it only repeats itself.
    var showsRowTypeLabels: Bool {
        Set(launcherMatches.map { LauncherResultRow.typeLabel(for: $0) }).count != 1
    }
}
