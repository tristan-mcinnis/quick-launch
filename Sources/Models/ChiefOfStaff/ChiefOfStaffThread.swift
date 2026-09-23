import Foundation
import HouseChatCore

/// One turn of the Chief of Staff thread, as Quick Launch draws it.
enum ChiefOfStaffThreadItem: Sendable, Equatable, Identifiable {
    /// A proposal card, with the id of the turn that carries it.
    case proposal(turnID: String, Proposal)
    /// The system note `cos` writes when a proposal is decided.
    case verdict(turnID: String, proposalID: String, verdict: String, text: String, date: Date?)
    /// A chat turn. `surface` names who recorded it: `quick-launch` for a
    /// turn this app appended, nil for `cos ask` and older turns.
    case chat(turnID: String, fromUser: Bool, text: String, date: Date?, surface: String?)

    var id: String {
        switch self {
        case .proposal(let turnID, _): turnID
        case .verdict(let turnID, _, _, _, _): turnID
        case .chat(let turnID, _, _, _, _): turnID
        }
    }

    var proposal: Proposal? {
        if case .proposal(_, let proposal) = self { return proposal }
        return nil
    }
}

/// Turns the one `cos` thread file into what the app draws. Pure: no file
/// I/O. The thread is a HouseChatCore `ConversationRecord` that only `cos`
/// writes.
enum ChiefOfStaffThread {
    /// The `appPayload` namespace `cos` writes under.
    static let namespace = "chief-of-staff"
    /// The `surface` this app writes on the chat turns it appends.
    static let surface = "quick-launch"

    static func decode(_ data: Data) throws -> ConversationRecord {
        try HouseChatCoding.makeDecoder().decode(ConversationRecord.self, from: data)
    }

    /// Every turn the app knows how to draw, in thread order. A turn from
    /// another namespace, or a kind this build does not know, is left out
    /// rather than drawn as something it is not.
    static func items(in record: ConversationRecord) -> [ChiefOfStaffThreadItem] {
        record.turns.compactMap(item(for:))
    }

    /// The proposals still waiting for a verdict, newest first.
    static func waiting(in items: [ChiefOfStaffThreadItem]) -> [Proposal] {
        items.compactMap(\.proposal)
            .enumerated()
            .filter { $0.element.isWaiting && !$0.element.awaitsReview }
            .sorted { lhs, rhs in
                switch (lhs.element.created, rhs.element.created) {
                case let (left?, right?) where left != right: left > right
                // Same time or no time: the later turn is the newer card.
                default: lhs.offset > rhs.offset
                }
            }
            .map(\.element)
    }

    /// The last `limit` proposals in thread order, whatever their status:
    /// the chat's memory of what it proposed and what was answered.
    static func recentProposals(in items: [ChiefOfStaffThreadItem], limit: Int = 12) -> [Proposal] {
        Array(items.compactMap(\.proposal).suffix(limit))
    }

    /// The history under the tiers: decided cards and chat turns
    /// another surface recorded. Waiting cards live above it, and the chat
    /// turns this app appended are drawn by the chat's own thread.
    static func history(in items: [ChiefOfStaffThreadItem]) -> [ChiefOfStaffThreadItem] {
        items.filter { item in
            switch item {
            // Later cards have their own section until they come back.
            // A card a rung ran shows under FYI as "I did this".
            case .proposal(_, let proposal): !proposal.isWaiting && proposal.status != .later && !proposal.auto
            case .verdict: false
            case .chat(_, _, _, _, let surface): surface != Self.surface
            }
        }
    }

    /// One line of EARLIER: a history item, or the cards that closed on
    /// their own, folded into one line.
    enum EarlierEntry: Sendable, Equatable, Identifiable {
        case item(ChiefOfStaffThreadItem)
        case closedOnTheirOwn([Proposal])

        var id: String {
            switch self {
            case .item(let item): item.id
            case .closedOnTheirOwn: "closed-on-their-own"
            }
        }
    }

    /// The note `cos` writes when it merges cards into one digest.
    static let mergedNote = "Merged into one digest"

    /// EARLIER without the bookkeeping: cards merged into a digest are left
    /// out, other cards that closed on their own fold into one first line,
    /// and the rest keep thread order.
    static func earlier(_ history: [ChiefOfStaffThreadItem], in items: [ChiefOfStaffThreadItem]) -> [EarlierEntry] {
        var autoNotes: [String: String] = [:]
        for item in items {
            if case .verdict(_, let proposalID, "auto", let text, _) = item { autoNotes[proposalID] = text }
        }
        var closed: [Proposal] = []
        var entries: [EarlierEntry] = []
        for item in history {
            guard let proposal = item.proposal, proposal.verdict == "auto" else {
                entries.append(.item(item))
                continue
            }
            if autoNotes[proposal.id]?.hasPrefix(mergedNote) == true { continue }
            closed.append(proposal)
        }
        return closed.isEmpty ? entries : [.closedOnTheirOwn(closed)] + entries
    }

    static func item(for turn: TurnRecord) -> ChiefOfStaffThreadItem? {
        let payload = turn.appPayload
        guard payload == nil || payload?.namespace == namespace else { return nil }
        let values = payload?.values ?? ExtraFields()
        switch values["kind"]?.stringValue {
        case "proposal":
            return Proposal(values: values, fallbackText: turn.text, fallbackDate: turn.createdAt)
                .map { .proposal(turnID: turn.id, $0) }
        case "verdict":
            return .verdict(
                turnID: turn.id,
                proposalID: values["proposal"]?.stringValue ?? "",
                verdict: values["verdict"]?.stringValue ?? "",
                text: turn.text,
                date: turn.createdAt
            )
        case "chat", nil:
            let surface = values["surface"]?.stringValue
            switch turn.role {
            case .user: return .chat(turnID: turn.id, fromUser: true, text: turn.text, date: turn.createdAt, surface: surface)
            case .assistant: return .chat(turnID: turn.id, fromUser: false, text: turn.text, date: turn.createdAt, surface: surface)
            default: return nil
            }
        default:
            return nil
        }
    }
}
