import Foundation

/// A calendar read as a worklist, like the plate: every event row gets a
/// number ("2 move to 16:00", "2 open" has no link, "2" asks about it), each
/// day's date line becomes a heading, and an event that has ended says so,
/// so the model never calls a finished meeting "next".
///
/// `calendar-ops.py` prints an event as
/// `  2026-11-18 15:00-16:00  Subject   @Room  [3 attendees]  org:Name`;
/// any other line (a day heading, a free slot) passes through.
enum CalendarListing {
    static func numbered(_ text: String, now: Date) -> (text: String, items: [PlateItem]) {
        var items: [PlateItem] = []
        var lines: [String] = []
        let ended = minute(now)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let match = line.wholeMatch(of: /(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})-(\d{2}:\d{2})\s+(.+)/) {
                let date = String(match.output.1)
                let start = String(match.output.2)
                let end = String(match.output.3)
                let rest = String(match.output.4)
                let subject = rest.components(separatedBy: "   ").first?.trimmingCharacters(in: .whitespaces) ?? rest
                let over = "\(date) \(end)" <= ended
                let item = PlateItem(
                    number: items.count + 1,
                    section: "Calendar",
                    text: subject,
                    note: "\(date) \(start)-\(end)" + (over ? ", over" : ""),
                    key: "e:\(date) \(start) \(subject)",
                    url: nil
                )
                items.append(item)
                if lines.last.map({ !$0.isEmpty && $0.first?.isNumber != true }) == true { lines.append("") }
                lines.append("\(item.number). \(start)-\(end) \(rest.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))" + (over ? " · over" : ""))
            } else if line.wholeMatch(of: /[A-Z][a-z]{2} \d{4}-\d{2}-\d{2}/) != nil {
                if !lines.isEmpty { lines.append("") }
                lines.append("### \(line)")
                lines.append("")
            } else if !line.isEmpty {
                lines.append(line)
            }
        }
        guard !items.isEmpty else { return (text, []) }
        return (lines.joined(separator: "\n"), items)
    }

    /// `yyyy-MM-dd HH:mm` in the calendar's own zone, China Standard Time.
    static func minute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
