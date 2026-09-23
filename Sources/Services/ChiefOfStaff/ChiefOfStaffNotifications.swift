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
    /// Passes a Focus: a DECIDE card.
    case timeSensitive
    /// A normal banner: a job that just turned red.
    case active
    /// Notification Centre only, no banner: TODAY and FYI cards.
    case passive
}

/// What Quick Launch posts for what changed since the last read.
enum ChiefOfStaffNotice: Sendable, Equatable {
    /// One card: its own notification, grouped by project, with Do it, No,
    /// Open and Reply.
    case card(Proposal, ChiefOfStaffUrgency)
    /// Three or more quiet cards at once: one summary, "3 new: Globex, Acme".
    case summary(count: Int, sources: [String], urgency: ChiefOfStaffUrgency)
    /// Background jobs that just turned red, named.
    case health(newlyRed: [String], headline: String)
    /// A meeting card: an active banner ten minutes before it starts (at
    /// once when that is already past).
    case meeting(Proposal, deliverAt: Date?)
}

/// The notification rules, pure so they are tested without a notification
/// center: quiet hours, tiers, the digest, and new red jobs.
enum ChiefOfStaffNotificationRules {
    /// This many quiet cards in one read become one summary.
    static let summaryThreshold = 3
    /// A meeting card's banner comes this long before the meeting.
    static let meetingLead: TimeInterval = 10 * 60

    /// The notices for `fresh` (cards new since the last read) and the jobs
    /// that turned red since then; none in quiet hours. DECIDE interrupts
    /// (time sensitive); TODAY and FYI go to Notification Centre only;
    /// WAITING never notifies; a health card is not a card, only a job that
    /// newly turned red is. A card a rung ran never notifies; a meeting card
    /// is an active banner ten minutes before; the morning brief is quiet.
    static func notices(
        for fresh: [Proposal],
        newlyRed: [String] = [],
        healthHeadline: String = "",
        now: Date,
        quietHours: QuietHours = .standard,
        calendar: Calendar = .current
    ) -> [ChiefOfStaffNotice] {
        guard !quietHours.contains(now, calendar: calendar) else { return [] }
        var notices: [ChiefOfStaffNotice] = []
        if !newlyRed.isEmpty {
            notices.append(.health(newlyRed: newlyRed, headline: healthHeadline))
        }
        let fresh = fresh.filter { !$0.auto }
        for meeting in fresh where meeting.isMeeting {
            let at = meeting.starts.map { $0.addingTimeInterval(-meetingLead) }
            notices.append(.meeting(meeting, deliverAt: at.flatMap { $0 > now ? $0 : nil }))
        }
        let cards = fresh.filter { !$0.isMeeting }
        let decide = cards.filter { $0.tierKind == .decide && !$0.isMorning }
        notices += decide.map { .card($0, .timeSensitive) }
        let quiet = cards.filter { $0.tierKind == .today || $0.tierKind == .fyi || $0.isMorning }
        if quiet.count >= summaryThreshold {
            var sources: [String] = []
            for source in quiet.map(\.source) where !source.isEmpty && !sources.contains(source) {
                sources.append(source)
            }
            notices.append(.summary(count: quiet.count, sources: sources, urgency: .passive))
        } else {
            notices += quiet.map { .card($0, .passive) }
        }
        return notices
    }

    /// The summary line: "3 new: Globex, Acme, Slack".
    static func summaryBody(count: Int, sources: [String]) -> String {
        sources.isEmpty ? "\(count) new cards" : "\(count) new: \(sources.joined(separator: ", "))"
    }
}
