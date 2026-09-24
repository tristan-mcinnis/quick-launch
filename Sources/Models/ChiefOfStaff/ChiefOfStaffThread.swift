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
    /// A branch opened on a card (`kind: branch`), or its merge-back line
    /// (`kind: branch_summary`): "Discussed: … · N actions done".
    case branch(turnID: String, link: ChiefOfStaffThread.BranchLink, summary: String?)

    var id: String {
        switch self {
        case .proposal(let turnID, _): turnID
        case .verdict(let turnID, _, _, _, _): turnID
        case .chat(let turnID, _, _, _, _): turnID
        case .branch(let turnID, _, _): turnID
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
    /// The `surface` of a branch's `cos tell` turns; they stay in the branch.
    static let branchSurface = "branch"

    /// A branch of the pinned conversation: an AI Chat conversation about
    /// one card.
    struct BranchLink: Sendable, Equatable, Hashable {
        var card: String
        var branch: UUID
        /// The branch's message count when this line was written, so a close
        /// with nothing new writes no second line.
        var turns: Int?
    }

    /// Every branch the thread records, card by card, newest last.
    static func branches(in items: [ChiefOfStaffThreadItem]) -> [String: [UUID]] {
        var result: [String: [UUID]] = [:]
        for case .branch(_, let link, _) in items where result[link.card]?.contains(link.branch) != true {
            result[link.card, default: []].append(link.branch)
        }
        return result
    }

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
            // A branch's own turns stay in the branch; its summary line shows.
            case .chat(_, _, _, _, let surface): surface != Self.surface && surface != Self.branchSurface
            case .branch(_, _, let summary): summary != nil
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
        // A branch's summary sits under its card when the card is here.
        var placed: [EarlierEntry] = []
        let summaries = entries.filter { if case .item(.branch) = $0 { true } else { false } }
        let cards = Set(entries.compactMap { entry -> String? in
            if case .item(.proposal(_, let proposal)) = entry { return proposal.id }
            return nil
        })
        for entry in entries {
            if case .item(.branch(_, let link, _)) = entry, cards.contains(link.card) { continue }
            placed.append(entry)
            if case .item(.proposal(_, let proposal)) = entry {
                placed += summaries.filter { if case .item(.branch(_, let link, _)) = $0 { link.card == proposal.id } else { false } }
            }
        }
        return closed.isEmpty ? placed : [.closedOnTheirOwn(closed)] + placed
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
        case "branch", "branch_summary":
            guard let card = values["card"]?.stringValue,
                  let branch = values["branch"]?.stringValue.flatMap(UUID.init(uuidString:)) else { return nil }
            let turns = values["turns"]?.stringValue.flatMap { Int($0) }
            let link = BranchLink(card: card, branch: branch, turns: turns)
            let isSummary = values["kind"]?.stringValue == "branch_summary"
            return .branch(turnID: turn.id, link: link, summary: isSummary ? turn.text : nil)
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
