import Foundation

/// Answers small, trusted system questions without involving an AI provider.
enum SystemFactsResolver {
    enum Fact {
        case dateAndTime
        case date
        case time
        case day
        case timeZone
    }

    static func answer(
        _ input: String,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard let fact = classify(input) else { return nil }

        switch fact {
        case .dateAndTime:
            return "\(format(now, dateStyle: .full, timeStyle: .short, locale: locale, timeZone: timeZone)) (\(timeZoneLabel(timeZone, now: now, locale: locale)))"
        case .date:
            return format(now, dateStyle: .full, timeStyle: .none, locale: locale, timeZone: timeZone)
        case .time:
            return "\(format(now, dateStyle: .none, timeStyle: .short, locale: locale, timeZone: timeZone)) (\(timeZoneLabel(timeZone, now: now, locale: locale)))"
        case .day:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
            return formatter.string(from: now)
        case .timeZone:
            return timeZoneLabel(timeZone, now: now, locale: locale)
        }
    }

    static func classify(_ input: String) -> Fact? {
        let query = normalized(input)
        guard !query.isEmpty else { return nil }

        if query.contains("date and time") || query.contains("date time") {
            return .dateAndTime
        }
        if matches(query, phrases: [
            "what time zone am i in", "what timezone am i in",
            "what is my time zone", "what is my timezone",
            "current time zone", "current timezone",
        ]) {
            return .timeZone
        }
        if matches(query, phrases: [
            "what day is it", "what day is today", "day of the week", "current day",
        ]) {
            return .day
        }
        if matches(query, phrases: [
            "what is the date", "whats the date", "todays date", "date today", "current date",
        ]) {
            return .date
        }
        if matches(query, phrases: [
            "what time is it", "what is the time", "whats the time", "time now", "current time",
        ]) {
            return .time
        }
        return nil
    }

    private static func matches(_ query: String, phrases: [String]) -> Bool {
        phrases.contains { query == $0 || query.hasPrefix($0 + " ") }
    }

    private static func normalized(_ input: String) -> String {
        let folded = input
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func format(
        _ date: Date,
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style,
        locale: Locale,
        timeZone: TimeZone
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }

    private static func timeZoneLabel(_ timeZone: TimeZone, now: Date, locale: Locale) -> String {
        let daylight = timeZone.isDaylightSavingTime(for: now)
        let style: TimeZone.NameStyle = daylight ? .daylightSaving : .standard
        let name = timeZone.localizedName(for: style, locale: locale) ?? timeZone.identifier
        let seconds = timeZone.secondsFromGMT(for: now)
        let sign = seconds >= 0 ? "+" : "−"
        let totalMinutes = abs(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let offset = minutes == 0
            ? "UTC\(sign)\(hours)"
            : String(format: "UTC%@%d:%02d", sign, hours, minutes)
        return "\(name), \(offset)"
    }
}
