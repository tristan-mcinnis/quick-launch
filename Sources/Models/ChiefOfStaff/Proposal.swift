import Foundation
import HouseChatCore

/// One Chief of Staff proposal: what it saw, what it proposes, and what
/// Tristan answered. Read from an assistant turn of the `cos` thread whose
/// `appPayload` is in the `chief-of-staff` namespace with `kind: proposal`.
/// The `cos` CLI writes every field; Quick Launch only reads them.
struct Proposal: Sendable, Equatable, Identifiable {
    enum Status: String, Sendable {
        case pending
        case done
        /// Older threads: `cos skip` before it became No.
        case skipped
        /// No: `cos no` / `cos skip`.
        case dismissed
        /// Hidden until a time, then it comes back as pending.
        case later
        /// Closed on its own (the proof arrived, or a health card cleared).
        case handled
        case expired
        case unknown
    }

    /// How much of Tristan's attention a card asks for. Old cards without a
    /// tier are `today`; a health card is `system`.
    enum Tier: String, Sendable, CaseIterable {
        /// Needs his decision or answer: a client waiting, or due within 48 h.
        case decide
        /// A quick one-tap action: log it, close it, add a task.
        case today
        /// Someone else owes the next move.
        case waiting
        case fyi
        /// Health of the background jobs: the header's status line, not a card.
        case system
    }

    /// What the reviewer (a second model) said before the card showed.
    struct Review: Sendable, Equatable {
        /// `ok`, `block`, or `escalate`.
        var verdict: String
        var reason: String
        var model: String

        var isEscalation: Bool { verdict == "escalate" }
    }

    /// One line of what running the actions did, as `cos` recorded it.
    struct Result: Sendable, Equatable, Hashable {
        var type: String
        var ok: Bool
        var detail: String
    }

    var id: String
    var status: Status
    var project: String
    /// The project's human name from `cos projects`, set by the model;
    /// nil shows the slug.
    var projectName: String?
    var eventKind: String
    var title: String
    var sender: String
    var paths: [String]
    var reason: String
    var message: String
    /// The brain's one-line summary; the first message line when absent.
    var cardHeadline: String
    /// `decide`, `today`, `waiting`, `fyi`, or `system` as written.
    var tier: String
    /// One line on why it matters; may be empty.
    var why: String
    /// When a Later card comes back.
    var snoozedUntil: Date?
    /// A health card's failing job labels.
    var red: [String]
    /// `client`, `team`, `admin`, or `system`.
    var importance: String
    var due: String?
    var actions: [ProposalAction]
    var created: Date?
    /// When the verdict was given.
    var decided: Date?
    var verdict: String?
    var results: [Result]
    var review: Review?
    /// A consent rung ran it without a tap: FYI, "I did this".
    var auto: Bool
    /// Undo steps were recorded when its actions ran (`cos undo`).
    var hasUndo: Bool
    /// Prepared files, relative to `artifacts/<id>/`.
    var artifacts: [String]
    /// `more` or `less` once given.
    var feedback: String?
    /// A meeting card's start, where, and who is in it.
    var starts: Date?
    var location: String?
    var attendees: [String]

    init(
        id: String,
        status: Status = .pending,
        project: String = "",
        eventKind: String = "",
        title: String = "",
        sender: String = "",
        paths: [String] = [],
        reason: String = "",
        message: String,
        headline: String = "",
        tier: String = "",
        why: String = "",
        snoozedUntil: Date? = nil,
        red: [String] = [],
        importance: String = "",
        due: String? = nil,
        actions: [ProposalAction] = [],
        created: Date? = nil,
        decided: Date? = nil,
        verdict: String? = nil,
        results: [Result] = [],
        review: Review? = nil,
        auto: Bool = false,
        hasUndo: Bool = false,
        artifacts: [String] = [],
        feedback: String? = nil,
        starts: Date? = nil,
        location: String? = nil,
        attendees: [String] = []
    ) {
        self.id = id
        self.status = status
        self.project = project
        projectName = nil
        self.eventKind = eventKind
        self.title = title
        self.sender = sender
        self.paths = paths
        self.reason = reason
        self.message = message
        self.cardHeadline = headline
        self.tier = tier
        self.why = why
        self.snoozedUntil = snoozedUntil
        self.red = red
        self.importance = importance
        self.due = due
        self.actions = actions
        self.created = created
        self.decided = decided
        self.verdict = verdict
        self.results = results
        self.review = review
        self.auto = auto
        self.hasUndo = hasUndo
        self.artifacts = artifacts
        self.feedback = feedback
        self.starts = starts
        self.location = location
        self.attendees = attendees
    }

    /// Nil when the values are not a proposal or have no id.
    init?(values: ExtraFields, fallbackText: String, fallbackDate: Date?) {
        guard values["kind"]?.stringValue == "proposal",
              let id = values["id"]?.stringValue, !id.isEmpty
        else { return nil }
        self.init(
            id: id,
            status: Status(rawValue: values["status"]?.stringValue ?? "") ?? .unknown,
            project: values["project"]?.stringValue ?? "",
            eventKind: values["event_kind"]?.stringValue ?? "",
            title: values["title"]?.stringValue ?? "",
            sender: values["sender"]?.stringValue ?? "",
            paths: values["paths"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            reason: values["reason"]?.stringValue ?? "",
            message: values["message"]?.stringValue ?? fallbackText,
            headline: values["headline"]?.stringValue ?? "",
            tier: values["tier"]?.stringValue ?? "",
            why: values["why"]?.stringValue ?? "",
            snoozedUntil: values["snoozed_until"]?.stringValue.flatMap(HouseChatCoding.date(from:)),
            red: values["red"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            importance: values["importance"]?.stringValue ?? "",
            due: values["due"]?.stringValue,
            actions: values["actions"]?.arrayValue?.compactMap(ProposalAction.init(json:)) ?? [],
            created: values["created"]?.stringValue.flatMap(HouseChatCoding.date(from:)) ?? fallbackDate,
            decided: values["decided"]?.stringValue.flatMap(HouseChatCoding.date(from:)),
            verdict: values["verdict"]?.stringValue,
            results: values["results"]?.arrayValue?.compactMap(Self.result(from:)) ?? [],
            review: values["review"]?.objectValue.map {
                Review(
                    verdict: $0["verdict"]?.stringValue ?? "",
                    reason: $0["reason"]?.stringValue ?? "",
                    model: $0["model"]?.stringValue ?? ""
                )
            },
            auto: values["auto"]?.boolValue ?? false,
            hasUndo: !(values["undo"]?.arrayValue?.isEmpty ?? true),
            artifacts: values["artifacts"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            feedback: values["feedback"]?.stringValue,
            // `meeting: {subject, start, end, location, online}` (contract v1).
            starts: (values["meeting"]?.objectValue?["start"]?.stringValue ?? values["starts"]?.stringValue)
                .flatMap(CosDate.parse),
            location: values["meeting"]?.objectValue?["location"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            attendees: values["attendees"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }

    private static func result(from json: JSONValue) -> Result? {
        guard let object = json.objectValue else { return nil }
        return Result(
            type: object["type"]?.stringValue ?? "",
            ok: object["ok"]?.boolValue ?? false,
            detail: object["detail"]?.stringValue ?? ""
        )
    }

    var isWaiting: Bool { status == .pending }

    /// The reviewer has not checked it yet: faces hide it and `cos do`
    /// refuses it (contract v1, section 3).
    var awaitsReview: Bool { review?.verdict == "pending" }

    /// The tier the face sorts by: a health card is always `system`, and a
    /// card from before tiers is `today`.
    var tierKind: Tier {
        if eventKind == "health" { return .system }
        return Tier(rawValue: tier) ?? .today
    }

    /// The action types a consent rung may cover (contract section 4).
    static let autoEligibleTypes: Set<String> = ["status_note", "task_add", "task_close"]

    /// After a Do it, "Always do this for <project>?" is offered: every
    /// action is auto-eligible, it is not DECIDE, and a rung did not run it.
    var offersRung: Bool {
        !actions.isEmpty && actions.allSatisfy { Self.autoEligibleTypes.contains($0.type) }
            && tierKind != .decide && !auto && eventKind != "morning" && eventKind != "meeting"
    }

    /// Done (by a tap or a rung) with undo steps recorded: ⌘Z undoes it.
    var canUndo: Bool { status == .done && hasUndo }

    var isMorning: Bool { eventKind == "morning" }
    var isMeeting: Bool { eventKind == "meeting" }

    /// Later, No, handled or expired: `cos reopen` can bring it back.
    var canBringBack: Bool {
        switch status {
        case .later, .dismissed, .skipped, .handled, .expired: true
        case .pending, .done, .unknown: false
        }
    }

    /// What a card names it by: the project's name (or slug), else the
    /// sender, else the event title (a health card has only a title).
    var source: String {
        [projectName ?? "", project, sender, title].first { !$0.isEmpty } ?? ""
    }

    /// One line: the brain's headline, else the message's first sentence,
    /// cut at a semicolon.
    var headline: String {
        if !cardHeadline.isEmpty {
            // A long headline from before the 12-word rule: its first clause.
            let words = cardHeadline.split(separator: " ").count
            return words > Self.headlineWords ? Self.firstSentence(of: cardHeadline) ?? cardHeadline : cardHeadline
        }
        return Self.firstSentence(of: message) ?? title
    }

    /// The brain keeps a headline to this many words.
    static let headlineWords = 12

    static func firstSentence(of text: String) -> String? {
        guard var line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) else { return nil }
        if let semicolon = line.firstIndex(of: ";") { line = String(line[..<semicolon]) }
        if let stop = line.range(of: ". ") { line = String(line[..<stop.lowerBound]) + "." }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A row's second line: the first action's text, and how many follow
    /// ("Finalise stimulus photos, +2 more"). Nil when nothing runs.
    var actionSummary: String? {
        guard let first = actions.first(where: { !$0.text.isEmpty }) else { return nil }
        var text = Self.firstSentence(of: first.text) ?? first.text
        if text.hasSuffix(".") { text.removeLast() }
        return actions.count > 1 ? "\(text), +\(actions.count - 1) more" : text
    }

    /// A health card has nothing to run: its one button is Got it.
    var isNotice: Bool { actions.isEmpty }

    /// The word a card shows beside its dot.
    var statusWord: String {
        switch status {
        case .pending: "Waiting"
        case .done: auto ? "I did this" : verdict == "edit" ? "Done after edit" : "Done"
        case .skipped, .dismissed:
            switch verdict {
            case "undone": "Undone"
            case "blocked": "Blocked"
            default: "No"
            }
        case .later: "Later"
        case .handled: "Handled"
        case .expired: "Expired"
        case .unknown: "Unknown"
        }
    }
}
