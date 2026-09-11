import Foundation

/// A Quick AI thread written out for pi. Continue in pi attaches this file
/// to a fresh pi session (`pi @file`), so it is plain Markdown a model reads
/// as the first message: the chat title, one line saying where it came
/// from, then every turn under its speaker, "You:" for the user and the
/// model's display name for the answers, separated by rules. The tool lines
/// the thread showed ("Searched memory: 4 hits", "Search web: …") open the
/// answer they belong to; the sources its tools found follow it as a list,
/// with each local path, and links the answer wrote stay where it put them.
///
/// A question's attachments follow it: one line each (the file's path, the
/// link's URL), then the text Quick Launch read from each, in a fenced
/// block, so pi has it even when the file moved or the page changed. Images
/// are named and never carried. Nothing is written beside the thread file.
enum PiHandoffDocument {
    /// The speaker label on a user turn, as Copy Chat writes it.
    static let userLabel = "You"
    /// Used when the chat has no model id.
    static let fallbackModelLabel = "Assistant"
    /// File names keep at most this many slug characters.
    static let slugCharacterLimit = 40
    /// The slug when a title has no letters or digits to keep.
    static let fallbackSlug = "chat"

    /// - `toolLines`: extra lines keyed by the assistant message they open,
    ///   for a line the thread shows that is not yet saved on the answer
    ///   (the live search line). Saved lines come from
    ///   `QuickMessage.toolRecords`; a line saved there is not repeated.
    /// - `attachmentText`: an attachment's text as this session read it,
    ///   or nil when it is not loaded (the line then says so).
    static func markdown(
        title: String,
        modelName: String,
        messages: [QuickMessage],
        toolLines: [UUID: [String]] = [:],
        attachmentText: (ChatAttachmentRef) -> String? = { _ in nil },
        date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let answerLabel = modelName.isEmpty ? fallbackModelLabel : modelName
        var blocks = [
            "# \(title)",
            "A Quick AI chat from Quick Launch, \(displayDate(date, timeZone: timeZone)), with \(answerLabel).",
        ]
        for message in messages {
            var turn: [String] = []
            switch message.role {
            case .user:
                turn.append("\(userLabel):")
                turn.append(message.content.trimmingCharacters(in: .whitespacesAndNewlines))
                turn += attachmentBlocks(message.attachmentRefs, text: attachmentText)
            case .assistant:
                turn.append("\(answerLabel):")
                let saved = message.tools
                let above = saved.filter(\.drawsAboveAnswer).map(\.summary)
                let extra = (toolLines[message.id] ?? []).filter { !above.contains($0) }
                for line in above + extra {
                    turn.append("Tool: \(line)")
                }
                if let question = message.askUserQuestion {
                    // The card the model asked with; the pick follows as the
                    // user's next turn.
                    turn.append("Asked: \(question.question)")
                    turn.append("Options: " + question.options.map(\.label).joined(separator: " / "))
                } else {
                    turn.append(message.content.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let sources = message.sources
                if !sources.isEmpty {
                    turn.append("Sources:\n" + sources.map(sourceLine).joined(separator: "\n"))
                }
                // A line under the answer (Captured to memory) stays under it.
                for record in saved where !record.drawsAboveAnswer {
                    turn.append("Tool: \(record.summary)")
                }
            case .system:
                // Instructions ride one request only; a saved chat has none,
                // and pi gets its own.
                continue
            }
            blocks.append("---")
            blocks.append(turn.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The attachment list under a question, then each text read.
    static func attachmentBlocks(
        _ refs: [ChatAttachmentRef],
        text: (ChatAttachmentRef) -> String?
    ) -> [String] {
        guard !refs.isEmpty else { return [] }
        var texts: [(ChatAttachmentRef, String)] = []
        var lines: [String] = []
        for ref in refs {
            var line = "- \(ref.name) (\(description(of: ref)))"
            if ref.kind.isImage {
                line += ": not carried to pi"
            } else {
                if let path = ref.path {
                    line += ": `\(path)`"
                } else if let url = ref.url {
                    line += ": \(url.absoluteString)"
                }
                if let body = text(ref), !body.isEmpty {
                    texts.append((ref, body))
                } else {
                    line += ", text not loaded in this session"
                }
            }
            lines.append(line)
        }
        var blocks = ["Attachments:\n" + lines.joined(separator: "\n")]
        for (ref, body) in texts {
            let fence = fence(for: body)
            blocks.append("Text of \(ref.name):\n\n\(fence)text\n\(body)\n\(fence)")
        }
        return blocks
    }

    /// "PDF, 42 pages", "Web page", "Screenshot, 1944 × 1464".
    static func description(of ref: ChatAttachmentRef) -> String {
        var parts = [ref.kind.displayName]
        if let width = ref.pixelWidth, let height = ref.pixelHeight, ref.kind.isImage {
            parts.append("\(width) × \(height)")
        } else if let count = ref.pageCount {
            let unit: String
            switch ref.kind {
            case .powerpoint: unit = count == 1 ? "slide" : "slides"
            case .excel: unit = count == 1 ? "sheet" : "sheets"
            default: unit = count == 1 ? "page" : "pages"
            }
            parts.append("\(count) \(unit)")
        }
        return parts.joined(separator: ", ")
    }

    /// A code fence longer than any run of backticks in `body`, so the text
    /// cannot close it.
    static func fence(for body: String) -> String {
        var longest = 0
        var run = 0
        for character in body {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }

    /// One source as a Markdown list item: its title, its day, and the local
    /// file when it has one.
    static func sourceLine(_ source: ChatSource) -> String {
        var line = "- \(source.title)"
        if let day = source.day { line += ", \(day)" }
        if let path = source.path { line += " (`\(path)`)" }
        return line
    }

    /// `<timestamp>-<slug>.md`: a timestamp that sorts by name, so the
    /// newest files are the last names, then the title as a slug.
    static func fileName(date: Date, title: String, timeZone: TimeZone = .current) -> String {
        "\(fileTimestamp(date, timeZone: timeZone))-\(slug(for: title)).md"
    }

    /// Lowercase ASCII letters and digits, runs of anything else as one
    /// hyphen, no hyphen at either end, at most `slugCharacterLimit`
    /// characters.
    static func slug(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var slug = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            let isKept = scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
            if isKept {
                let hyphen = pendingHyphen && !slug.isEmpty
                if slug.count + (hyphen ? 2 : 1) > slugCharacterLimit { break }
                if hyphen { slug.append("-") }
                pendingHyphen = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }
        return slug.isEmpty ? fallbackSlug : slug.lowercased()
    }

    private static func fileTimestamp(_ date: Date, timeZone: TimeZone) -> String {
        formatter("yyyyMMdd-HHmmss", timeZone: timeZone).string(from: date)
    }

    private static func displayDate(_ date: Date, timeZone: TimeZone) -> String {
        formatter("yyyy-MM-dd HH:mm", timeZone: timeZone).string(from: date)
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
