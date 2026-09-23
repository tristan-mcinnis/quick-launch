import Foundation

/// No Chief of Staff notification from 23:00 to 07:00 local, the window the
/// CLI keeps for its own banners. A card that lands then still waits in the
/// pinned conversation.
struct QuietHours: Sendable, Equatable {
    var startHour = 23
    var endHour = 7

    static let standard = QuietHours()

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if startHour > endHour { return hour >= startHour || hour < endHour }
        return hour >= startHour && hour < endHour
    }
}

/// How loudly one notification may interrupt.
enum ChiefOfStaffUrgency: Sendable, Equatable {
    /// Passes a Focus: a client email whose text names a date within 48 h.
    case timeSensitive
    /// A normal banner.
    case active
}

/// What Quick Launch posts for the cards that arrived since the last read.
enum ChiefOfStaffNotice: Sendable, Equatable {
    /// One card: its own banner, grouped by project, with Do it, Skip, Open
    /// and Reply.
    case card(Proposal, ChiefOfStaffUrgency)
    /// Three or more at once: one summary, "3 new: Globex, Acme, Slack".
    case summary(count: Int, sources: [String], urgency: ChiefOfStaffUrgency)
}

/// The notification rules, pure so they are tested without a notification
/// center: quiet hours, the digest threshold, and urgency.
enum ChiefOfStaffNotificationRules {
    /// This many new cards in one read become one summary.
    static let summaryThreshold = 3
    /// A date this close makes a client email time sensitive.
    static let urgentWindow: TimeInterval = 48 * 60 * 60

    /// The notices for `fresh` (cards new since the last read), none in
    /// quiet hours.
    static func notices(
        for fresh: [Proposal],
        now: Date,
        quietHours: QuietHours = .standard,
        calendar: Calendar = .current
    ) -> [ChiefOfStaffNotice] {
        guard !fresh.isEmpty, !quietHours.contains(now, calendar: calendar) else { return [] }
        let urgencies = fresh.map { urgency(of: $0, now: now, calendar: calendar) }
        if fresh.count >= summaryThreshold {
            var sources: [String] = []
            for source in fresh.map(\.source) where !source.isEmpty && !sources.contains(source) {
                sources.append(source)
            }
            let urgency: ChiefOfStaffUrgency = urgencies.contains(.timeSensitive) ? .timeSensitive : .active
            return [.summary(count: fresh.count, sources: sources, urgency: urgency)]
        }
        return zip(fresh, urgencies).map { .card($0, $1) }
    }

    /// Time sensitive only for a client email card whose due date or text
    /// names a date from now to 48 h ahead.
    static func urgency(of proposal: Proposal, now: Date, calendar: Calendar = .current) -> ChiefOfStaffUrgency {
        guard proposal.eventKind == "email", proposal.importance == "client" else { return .active }
        let window = now.addingTimeInterval(-60 * 60)...now.addingTimeInterval(urgentWindow)
        if let due = proposal.due, let date = day(from: due, calendar: calendar) {
            // A due day counts from its start, so "due today" is inside.
            let end = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            if window.overlaps(date...end) { return .timeSensitive }
        }
        let text = [proposal.headline, proposal.message].joined(separator: "\n")
        return datesNamed(in: text).contains(where: window.contains) ? .timeSensitive : .active
    }

    /// The summary line: "3 new: Globex, Acme, Slack".
    static func summaryBody(count: Int, sources: [String]) -> String {
        sources.isEmpty ? "\(count) new cards" : "\(count) new: \(sources.joined(separator: ", "))"
    }

    private static func day(from text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Every date the text names ("Friday", "tomorrow at 3", "25 Sep").
    /// Relative words resolve against the clock, as the detector reads them.
    static func datesNamed(in text: String) -> [Date] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, options: [], range: range).compactMap(\.date)
    }
}
