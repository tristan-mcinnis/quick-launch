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

    /// One line of what running the actions did, as `cos` recorded it.
    struct Result: Sendable, Equatable, Hashable {
        var type: String
        var ok: Bool
        var detail: String
    }

    var id: String
    var status: Status
    var project: String
    var eventKind: String
    var title: String
    var sender: String
    var paths: [String]
    var reason: String
    var message: String
    /// The brain's one-line summary; the first message line when absent.
    var cardHeadline: String
    /// `decide`, `today`, `waiting`, `fyi`, or `system`.
    var tier: String
    /// `client`, `team`, `admin`, or `system`.
    var importance: String
    var due: String?
    var actions: [ProposalAction]
    var created: Date?
    var verdict: String?
    var results: [Result]

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
        importance: String = "",
        due: String? = nil,
        actions: [ProposalAction] = [],
        created: Date? = nil,
        verdict: String? = nil,
        results: [Result] = []
    ) {
        self.id = id
        self.status = status
        self.project = project
        self.eventKind = eventKind
        self.title = title
        self.sender = sender
        self.paths = paths
        self.reason = reason
        self.message = message
        self.cardHeadline = headline
        self.tier = tier
        self.importance = importance
        self.due = due
        self.actions = actions
        self.created = created
        self.verdict = verdict
        self.results = results
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
            importance: values["importance"]?.stringValue ?? "",
            due: values["due"]?.stringValue,
            actions: values["actions"]?.arrayValue?.compactMap(ProposalAction.init(json:)) ?? [],
            created: values["created"]?.stringValue.flatMap(HouseChatCoding.date(from:)) ?? fallbackDate,
            verdict: values["verdict"]?.stringValue,
            results: values["results"]?.arrayValue?.compactMap(Self.result(from:)) ?? []
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

    /// What a card names it by: the project, else the sender, else the
    /// event title (a health card has only a title).
    var source: String {
        [project, sender, title].first { !$0.isEmpty } ?? ""
    }

    /// One line: the brain's headline, else the message's first line.
    var headline: String {
        if !cardHeadline.isEmpty { return cardHeadline }
        return message.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? title
    }

    /// A health card has nothing to run: its one button is Got it.
    var isNotice: Bool { actions.isEmpty }

    /// The word a card shows beside its dot.
    var statusWord: String {
        switch status {
        case .pending: "Waiting"
        case .done: verdict == "edit" ? "Done after edit" : "Done"
        case .skipped, .dismissed: "No"
        case .later: "Later"
        case .handled: "Handled"
        case .expired: "Expired"
        case .unknown: "Unknown"
        }
    }
}
