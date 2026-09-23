import Foundation

/// The dates the Chief of Staff shows and reads: a due day as a relative
/// phrase ("by tomorrow"), when a Later card comes back, and a typed day
/// ("fri", "tomorrow", "2026-09-30") as the `YYYY-MM-DD` `cos` takes.
enum ChiefOfStaffDates {
    /// A `YYYY-MM-DD` day at the start of that day, in `calendar`.
    static func day(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "by today", "by tomorrow", "by Friday", "by 30 Sep", "1 day late",
    /// "3 days late". Nil for a day that does not parse.
    static func relativeDue(_ text: String, now: Date = .now, calendar: Calendar = .current) -> String? {
        guard let due = day(text, calendar: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: due).day ?? 0
        switch days {
        case ..<(-1): return "\(-days) days late"
        case -1: return "1 day late"
        case 0: return "by today"
        case 1: return "by tomorrow"
        case 2...6: return "by " + weekday(due, calendar: calendar)
        default: return "by " + dayMonth(due, calendar: calendar)
        }
    }

    // Built from the calendar's own parts, so a phrase reads the same on
    // every Mac: "Friday", "9 Oct", "09:00".
    private static func weekday(_ date: Date, calendar: Calendar, short: Bool = false) -> String {
        let symbols = short ? calendar.shortWeekdaySymbols : calendar.weekdaySymbols
        return symbols[calendar.component(.weekday, from: date) - 1]
    }

    private static func dayMonth(_ date: Date, calendar: Calendar) -> String {
        "\(calendar.component(.day, from: date)) \(calendar.shortMonthSymbols[calendar.component(.month, from: date) - 1])"
    }

    private static func clock(_ date: Date, calendar: Calendar) -> String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }

    /// When a Later card comes back: "back tonight at 20:00", "back tomorrow
    /// at 09:00", "back Mon 28 Sep at 09:00".
    static func returnPhrase(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = clock(date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) {
            return calendar.component(.hour, from: date) >= 17 ? "back tonight at \(time)" : "back today at \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "back tomorrow at \(time)"
        }
        return "back \(weekday(date, calendar: calendar, short: true)) \(dayMonth(date, calendar: calendar)) at \(time)"
    }

    /// A typed day as `YYYY-MM-DD`: `today`, `tomorrow` (`tmr`), a weekday
    /// or its first three letters (the next one after today), `next week`
    /// (next Monday), `+3` or `3d` (in three days), `2026-09-30`, `9/30`, or
    /// `30 Sep`. Nil when it is not one of those.
    static func parseDay(_ text: String, now: Date = .now, calendar: Calendar = .current) -> String? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty else { return nil }
        let today = calendar.startOfDay(for: now)
        func inDays(_ n: Int) -> String? {
            calendar.date(byAdding: .day, value: n, to: today).map { string($0, calendar: calendar) }
        }
        switch input {
        case "today", "tod": return inDays(0)
        case "tomorrow", "tmr", "tom", "tmrw": return inDays(1)
        case "next week", "nextweek": return nextWeekday(2, after: today, calendar: calendar).map { string($0, calendar: calendar) }
        default: break
        }
        if let weekday = weekdayNumber(input) {
            return nextWeekday(weekday, after: today, calendar: calendar).map { string($0, calendar: calendar) }
        }
        let digits = input.hasPrefix("+") ? String(input.dropFirst()) : (input.hasSuffix("d") ? String(input.dropLast()) : "")
        if !digits.isEmpty, let n = Int(digits), (0...365).contains(n) { return inDays(n) }
        if let date = day(input, calendar: calendar), input.count == 10 { return string(date, calendar: calendar) }
        let slash = input.split(separator: "/").compactMap { Int($0) }
        if slash.count == 2, (1...12).contains(slash[0]), (1...31).contains(slash[1]) {
            return upcoming(month: slash[0], day: slash[1], today: today, calendar: calendar)
        }
        let words = input.split(separator: " ")
        if words.count == 2 {
            if let dayNumber = Int(words[0]), let month = monthNumber(String(words[1])) {
                return upcoming(month: month, day: dayNumber, today: today, calendar: calendar)
            }
            if let month = monthNumber(String(words[0])), let dayNumber = Int(words[1]) {
                return upcoming(month: month, day: dayNumber, today: today, calendar: calendar)
            }
        }
        return nil
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// 1 is Sunday, as `Calendar` counts.
    private static func weekdayNumber(_ text: String) -> Int? {
        guard text.count >= 3 else { return nil }
        return weekdays.firstIndex { $0.hasPrefix(text) }.map { $0 + 1 }
    }

    private static func monthNumber(_ text: String) -> Int? {
        guard text.count >= 3 else { return nil }
        return months.firstIndex { text.hasPrefix($0) }.map { $0 + 1 }
    }

    private static func nextWeekday(_ weekday: Int, after today: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: today, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime)
    }

    /// That month and day this year, or next year once it has passed.
    private static func upcoming(month: Int, day: Int, today: Date, calendar: Calendar) -> String? {
        let year = calendar.component(.year, from: today)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        if date >= today { return string(date, calendar: calendar) }
        return calendar.date(from: DateComponents(year: year + 1, month: month, day: day)).map { string($0, calendar: calendar) }
    }
}

/// The Later menu's choices (⌘L on a card).
enum LaterChoice: Int, CaseIterable, Identifiable, Sendable {
    case tonight
    case tomorrow
    case nextWeek
    case pickDate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .tonight: "Tonight"
        case .tomorrow: "Tomorrow 9:00"
        case .nextWeek: "Next week"
        case .pickDate: "Pick date"
        }
    }

    /// The `--until` value `cos later` takes; `pickDate` needs a typed day.
    func until(picked: String?) -> String? {
        switch self {
        case .tonight: "tonight"
        case .tomorrow: "tomorrow"
        case .nextWeek: "nextweek"
        case .pickDate: picked
        }
    }
}
