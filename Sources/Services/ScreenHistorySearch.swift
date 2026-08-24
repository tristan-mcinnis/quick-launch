import Foundation

enum ScreenHistoryQueryDecision: Equatable, Sendable {
    case search(ScreenHistoryParsedQuery)
    case refuseFuture
    case routeVaultSearch
}

struct ScreenHistoryParsedQuery: Equatable, Sendable {
    let raw: String
    let text: String
    let application: String?
    let domain: String?
    let from: Date?
    let through: Date?
    let hasFilters: Bool

    var storageQuery: ScreenHistorySearchQuery {
        ScreenHistorySearchQuery(
            text: text,
            from: from,
            through: through,
            application: application,
            domain: domain,
            limit: 50
        )
    }
}

enum ScreenHistoryQueryParser {
    static func parse(
        _ raw: String,
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) -> ScreenHistoryQueryDecision {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased()

        if asksForFutureScreen(folded) { return .refuseFuture }
        if asksForCurrentProjectTruth(folded) { return .routeVaultSearch }

        var calendar = inputCalendar
        if calendar.timeZone.identifier.isEmpty { calendar.timeZone = .current }
        var words: [String] = []
        var application: String?
        var domain: String?
        var from: Date?
        var through: Date?
        var hasFilters = false

        for token in trimmed.split(whereSeparator: \.isWhitespace).map(String.init) {
            let lower = token.lowercased()
            if lower.hasPrefix("app:"), token.count > 4 {
                application = cleanFilter(String(token.dropFirst(4)))
                hasFilters = true
            } else if lower.hasPrefix("site:"), token.count > 5 {
                domain = cleanFilter(String(token.dropFirst(5)))?.lowercased()
                hasFilters = true
            } else if lower.hasPrefix("after:"), token.count > 6,
                      let date = isoDate(String(token.dropFirst(6)), calendar: calendar) {
                from = date
                hasFilters = true
            } else if lower.hasPrefix("before:"), token.count > 7,
                      let date = isoDate(String(token.dropFirst(7)), calendar: calendar) {
                // A date-only before filter includes that full local day.
                through = calendar.date(byAdding: .day, value: 1, to: date)?.addingTimeInterval(-0.001)
                hasFilters = true
            } else if lower == "yesterday" {
                let today = calendar.startOfDay(for: now)
                from = calendar.date(byAdding: .day, value: -1, to: today)
                through = today.addingTimeInterval(-0.001)
                hasFilters = true
            } else if lower == "today" {
                let today = calendar.startOfDay(for: now)
                from = today
                through = calendar.date(byAdding: .day, value: 1, to: today)?.addingTimeInterval(-0.001)
                hasFilters = true
            } else {
                words.append(token)
            }
        }

        return .search(ScreenHistoryParsedQuery(
            raw: trimmed,
            text: words.joined(separator: " "),
            application: application,
            domain: domain,
            from: from,
            through: through,
            hasFilters: hasFilters
        ))
    }

    private static func cleanFilter(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")
            .union(.whitespacesAndNewlines))
        return result.isEmpty ? nil : String(result.prefix(200))
    }

    private static func isoDate(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components).map { calendar.startOfDay(for: $0) }
    }

    private static func asksForFutureScreen(_ value: String) -> Bool {
        let future = value.contains("tomorrow") || value.contains("next week")
            || value.contains("will be on my screen") || value.contains("will i see")
        return future && (value.contains("screen") || value.contains("see"))
    }

    private static func asksForCurrentProjectTruth(_ value: String) -> Bool {
        let current = value.contains("stand now") || value.contains("status now")
            || value.contains("current status") || value.contains("where does")
        let work = value.contains("project") || value.contains("deliverable")
            || value.contains("client") || value.contains("work")
        return current && work
    }
}

enum ScreenHistoryTimeline {
    /// Reconstructs a local activity sequence without inventing a second
    /// navigation model. A sequence continues while adjacent moments are no
    /// more than five minutes apart.
    static func sequence(
        around anchor: ScreenHistoryFrame,
        in frames: [ScreenHistoryFrame],
        maximumGap: TimeInterval = 5 * 60
    ) -> [ScreenHistoryFrame] {
        let scoped: [ScreenHistoryFrame]
        if let sequenceIdentifier = anchor.sequenceIdentifier, !sequenceIdentifier.isEmpty {
            scoped = frames.filter { $0.sequenceIdentifier == sequenceIdentifier }
        } else {
            scoped = frames
        }
        let unique = Dictionary(grouping: scoped, by: {
            "\($0.source.rawValue):\($0.sourceIdentifier)"
        }).compactMap { $0.value.first }
        let sorted = unique.sorted {
            if $0.capturedAt == $1.capturedAt { return $0.sourceIdentifier < $1.sourceIdentifier }
            return $0.capturedAt < $1.capturedAt
        }
        guard let index = sorted.firstIndex(where: {
            $0.source == anchor.source && $0.sourceIdentifier == anchor.sourceIdentifier
        }) else { return [anchor] }

        var lower = index
        while lower > 0,
              sorted[lower].capturedAt.timeIntervalSince(sorted[lower - 1].capturedAt) <= maximumGap {
            lower -= 1
        }
        var upper = index
        while upper + 1 < sorted.count,
              sorted[upper + 1].capturedAt.timeIntervalSince(sorted[upper].capturedAt) <= maximumGap {
            upper += 1
        }
        return Array(sorted[lower...upper])
    }
}

enum ScreenHistoryPrivacyPolicy {
    /// Browser private-window state is not available with enough certainty to
    /// make a safe per-page decision. Keep the URL/domain preflight below for
    /// a future explicit browser opt-in, but fail closed for this release.
    private static let allowsBrowserCapture = false
    private static let protectedTitleTerms = [
        "private browsing", "incognito", "password", "recovery code",
        "authentication", "security code", "one-time code", "touch id",
        "payment", "credit card", "sign in", "log in", "bank", "banking",
        "billing", "checkout", "finance", "financial", "wallet",
    ]
    private static let protectedDomainLabels: Set<String> = [
        "auth", "authentication", "bank", "banking", "billing", "checkout",
        "finance", "financial", "login", "payment", "payments", "signin",
        "wallet", "wallets",
    ]
    private static let knownBrowserBundlePrefixes = [
        "com.kagi.kagimacos",
        "com.operasoftware.opera",
        "com.apple.safari",
        "com.brave.browser",
        "com.google.chrome",
        "com.microsoft.edgemac",
        "com.vivaldi.vivaldi",
        "company.thebrowser.browser",
        "company.thebrowser.dia",
        "net.imput.helium",
        "org.mozilla.firefox",
    ]
    private static let knownBrowserBundleIdentifiers: Set<String> = [
        "com.apple.safaritechnologypreview",
        "com.operasoftware.operagx",
        "org.mozilla.firefoxbeta",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
    ]

    static func isKnownBrowser(bundleIdentifier: String) -> Bool {
        let normalized = bundleIdentifier.lowercased()
        return knownBrowserBundleIdentifiers.contains(normalized)
            || knownBrowserBundlePrefixes.contains { prefix in
                normalized == prefix || normalized.hasPrefix("\(prefix).")
            }
    }

    static func captureSkipReason(
        target: ScreenHistoryCaptureTarget,
        bundleIdentifier: String,
        excludedDomains: Set<String>
    ) -> ScreenHistoryCaptureSkipReason? {
        let titles = [target.windowTitle, target.pageTitle]
            .compactMap { $0?.lowercased() }
        if titles.contains(where: { title in protectedTitleTerms.contains(where: title.contains) }) {
            return .protectedSurface
        }
        guard isKnownBrowser(bundleIdentifier: bundleIdentifier)
                || target.declaresWebURLHandling
        else { return nil }
        guard allowsBrowserCapture else { return .protectedSurface }
        guard let pageURL = target.pageURL,
              let scheme = pageURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = pageURL.host,
              let pageDomain = ScreenHistoryCaptureConfiguration.normalizedDomain(host),
              let targetDomain = target.domain.flatMap(ScreenHistoryCaptureConfiguration.normalizedDomain),
              pageDomain == targetDomain
        else { return .protectedSurface }
        if isProtected(domain: pageDomain)
            || ScreenHistoryCaptureConfiguration.matches(domain: pageDomain, rules: excludedDomains) {
            return .protectedSurface
        }
        return nil
    }

    static func allowsSearchResult(
        _ frame: ScreenHistoryFrame,
        excludedBundleIdentifiers: Set<String> = [],
        excludedDomains: Set<String> = []
    ) -> Bool {
        allowsStoredContent(
            bundleIdentifier: frame.bundleIdentifier,
            windowTitle: frame.windowTitle,
            domain: frame.domain,
            excludedBundleIdentifiers: excludedBundleIdentifiers,
            excludedDomains: excludedDomains
        )
    }

    static func allowsStoredContent(
        bundleIdentifier: String?,
        windowTitle: String?,
        domain: String?,
        excludedBundleIdentifiers: Set<String> = [],
        excludedDomains: Set<String> = []
    ) -> Bool {
        guard let bundle = bundleIdentifier else { return false }
        let normalizedBundle = bundle.lowercased()
        let bundleRules = ScreenHistoryCaptureConfiguration.safeDefaultExcludedBundleIdentifiers
            .union(ScreenHistoryCaptureConfiguration.safeDefaultCaptureOnlyExcludedBundleIdentifiers)
            .union(excludedBundleIdentifiers.compactMap(
                ScreenHistoryCaptureConfiguration.normalizedBundleIdentifier
            ))
        guard !bundleRules.contains(normalizedBundle)
        else { return false }
        let title = windowTitle?.lowercased() ?? ""
        guard !protectedTitleTerms.contains(where: title.contains) else { return false }
        guard let domain else { return !isKnownBrowser(bundleIdentifier: bundle) }
        let domainRules = ScreenHistoryCaptureConfiguration.safeDefaultExcludedDomains
            .union(excludedDomains.compactMap(ScreenHistoryCaptureConfiguration.normalizedDomain))
        return !isProtected(domain: domain)
            && !ScreenHistoryCaptureConfiguration.matches(domain: domain, rules: domainRules)
    }

    private static func isProtected(domain: String) -> Bool {
        guard let normalized = ScreenHistoryCaptureConfiguration.normalizedDomain(domain) else {
            return true
        }
        return normalized.split(separator: ".").contains { label in
            label.split(whereSeparator: { $0 == "-" || $0 == "_" }).contains {
                protectedDomainLabels.contains(String($0))
            }
        }
    }
}
