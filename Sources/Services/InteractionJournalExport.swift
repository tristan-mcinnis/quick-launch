import Foundation

/// Review formats for the local interaction journal.
enum InteractionJournalExportFormat: String, CaseIterable, Identifiable, Sendable {
    /// One JSON object per line — easy to filter with `jq` or a spreadsheet.
    case jsonLines
    /// A readable summary grouped by outcome, for reading end to end.
    case markdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jsonLines: "JSON Lines"
        case .markdown: "Markdown"
        }
    }

    var fileExtension: String {
        switch self {
        case .jsonLines: "jsonl"
        case .markdown: "md"
        }
    }
}

/// Renders journal events for review and writes them owner-only.
///
/// Rendering is pure, so it is testable without a save panel. Nothing here
/// adds content: the renderer can only emit what the store stored, which is
/// sanitized identifiers, category codes, coarse size bands, and keyed digests.
/// A row whose digest was retired by a migration has none, and renders `—`.
enum InteractionJournalExporter {

    static func render(
        _ events: [InteractionJournalEvent],
        as format: InteractionJournalExportFormat
    ) -> String {
        switch format {
        case .jsonLines: jsonLines(events)
        case .markdown: markdown(events)
        }
    }

    // MARK: - JSON Lines

    static func jsonLines(_ events: [InteractionJournalEvent]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var lines: [String] = []
        for event in events.sorted(by: { $0.date < $1.date }) {
            guard let data = try? encoder.encode(event),
                  let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Markdown

    static func markdown(_ events: [InteractionJournalEvent]) -> String {
        var out = "# Quick Launch interaction journal\n\n"
        out += "Local only. Events record outcomes (identifiers, category codes, "
        out += "a coarse query-size band, and a keyed one-way digest of the query) — "
        out += "never clipboard, snippet, chat, selection, file, query, or AI "
        out += "response contents. The digest is keyed with a random per-install "
        out += "key, so repeats correlate on this Mac and mean nothing elsewhere.\n\n"

        guard !events.isEmpty else { return out + "_No events recorded._\n" }

        let sorted = events.sorted { $0.date < $1.date }
        out += "**\(sorted.count) events**"
        if let first = sorted.first?.date, let last = sorted.last?.date {
            out += " from \(stamp(first)) to \(stamp(last))"
        }
        out += ".\n\n"

        let accidents = sorted.filter(\.markedAccidental)
        if !accidents.isEmpty {
            out += "**Marked accidental (\(accidents.count))**\n\n"
            for event in accidents {
                out += "- \(stamp(event.date)) — \(event.kind.shortTitle)\(context(event))\n"
            }
            out += "\n"
        }

        for kind in InteractionJournalEventKind.allCases {
            let group = sorted.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            out += "## \(kind.reviewTitle) (\(group.count))\n\n"
            out += "| When | Scope | Item | Query | Detail | Marked |\n"
            out += "| --- | --- | --- | --- | --- | --- |\n"
            for event in group {
                let row = [
                    stamp(event.date),
                    escape(event.scope),
                    escape(event.itemID ?? "—"),
                    queryColumn(event),
                    escape(event.detail ?? "—"),
                    event.markedAccidental ? "yes" : "",
                ]
                out += "| " + row.joined(separator: " | ") + " |\n"
            }
            out += "\n"
        }
        return out
    }

    // MARK: - Writing

    /// Writes `contents` atomically with `0600` permissions.
    static func write(_ contents: String, to url: URL) throws {
        let data = Data(contents.utf8)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    /// Suggested file name for the save panel.
    static func suggestedFileName(
        for format: InteractionJournalExportFormat,
        now: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "quick-launch-journal-\(formatter.string(from: now)).\(format.fileExtension)"
    }

    // MARK: - Helpers

    private static func queryColumn(_ event: InteractionJournalEvent) -> String {
        guard let fingerprint = event.queryFingerprint else { return "—" }
        guard let bucket = event.queryLengthBucket else { return "`\(fingerprint)`" }
        return "`\(fingerprint)` (\(bucket) chars)"
    }

    private static func context(_ event: InteractionJournalEvent) -> String {
        var parts: [String] = []
        if event.scope != LauncherUsageStore.rootScope { parts.append(event.scope) }
        if let itemID = event.itemID { parts.append(itemID) }
        return parts.isEmpty ? "" : " — \(parts.joined(separator: " · "))"
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }
}
