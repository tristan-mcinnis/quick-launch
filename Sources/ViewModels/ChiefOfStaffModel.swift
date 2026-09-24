import AppKit
import Foundation
import HouseChatCore
import Observation

/// What one proposal card is doing in this session: showing, editing,
/// running, or showing what a verdict did. One per proposal id.
@MainActor
@Observable
final class ProposalCardState {
    var isEditing = false
    /// The Edit fields, one per action.
    var drafts: [ActionDraft] = []
    /// A `cos` call for this card is in flight.
    var isRunning = false
    /// What the last verdict did (OK / FAIL lines).
    var outcome: [OutcomeLine]?
}

/// The Chief of Staff inside Quick Launch: the `cos` thread as read, its
/// cards sorted into tiers, the projects strip, the keyboard's focus, the
/// Later menu, the New task sheet, and the notices. It reads files through
/// `CosFiles` and acts only through the `cos` CLI, so nothing here writes
/// the thread or blocks the main actor.
///
/// `run()` is the one root of its concurrency: the 2 s thread poll, the
/// 30 s liveness touch, and every command run as child tasks of its group,
/// and all of them end when it is cancelled.
@MainActor
@Observable
final class ChiefOfStaffModel {
    /// The backing Quick Launch chat of the pinned conversation: its turns
    /// give follow-ups their memory, and it never shows in a chat list.
    nonisolated static let conversationID = UUID(uuidString: "C0F5C0F5-0000-4000-8000-000000000C05")!
    nonisolated static let title = "Chief of Staff"
    /// The read-only tools its chat offers. No write tools: writes stay
    /// card actions.
    nonisolated static let tools: Set<ChatToolKind> = [.tasks, .vault, .memory, .web]
    /// The proposals the chat's system message recalls.
    nonisolated static let recentProposalLimit = 12
    /// DECIDE shows this many before "Show all".
    nonisolated static let decideVisibleLimit = 3

    static let pollInterval: Duration = .seconds(2)
    static let aliveInterval: Duration = .seconds(30)
    /// The projects strip is read again this often, and on every thread change.
    static let projectsInterval: Duration = .seconds(300)

    enum Command: Sendable, Equatable {
        case doIt(id: String)
        case runEdit(id: String)
        case no(id: String)
        case later(id: String, until: String)
        case reopen(id: String)
        case addTask(title: String, project: String, due: String?)
        case loadTasks(project: String)
        case more(id: String)
        case less(id: String, why: String?)
        case always(id: String)
        case never(rung: String)
        case undo(id: String)
        case rule(text: String, scope: String)
        case charterLine(text: String, section: String)
        case forget(key: String)
        case loadActivity(day: String?)
        case loadArtifacts
        case loadCharter
        /// Open a file in its default app (an explicit action only).
        case open(URL)
        case recordTurn(question: String, answer: String, attachmentNames: [String])
        /// A message in branch `chat` about `card`, to `cos tell`.
        case tell(text: String, card: String, chat: UUID)
        /// A branch opened on `card`: the card lists it (`cos append --meta`).
        case linkBranch(card: String, branch: UUID, title: String)
        /// A branch merges back: one line under its card.
        case branchSummary(card: String, branch: UUID, text: String, turns: Int)
        case refresh
    }

    /// ⌥⌘1 List (the tiers), ⌥⌘2 Board (columns), ⌥⌘3 Activity (what it
    /// did one day), ⌥⌘4 Artifacts (what Prepare made), ⌥⌘5 Charter.
    enum ViewMode: Int, CaseIterable, Sendable, Equatable {
        case list = 1
        case board
        case activity
        case artifacts
        case charter

        var title: String {
            switch self {
            case .list: "List"
            case .board: "Board"
            case .activity: "Activity"
            case .artifacts: "Artifacts"
            case .charter: "Charter"
            }
        }
    }

    /// ⌘- on a card: an optional one-line why, then `cos less`.
    struct LessPrompt: Sendable, Equatable {
        let proposalID: String
        var why = ""
    }

    /// After a Do it on an auto-eligible card: "Always do this for …?"
    struct RungOffer: Sendable, Equatable {
        let proposalID: String
        let project: String
        let types: [String]
    }

    /// ⌘N in the Charter: a new learning, Everywhere, for this project, or
    /// for this sender (the project and sender of the card or filter it was
    /// opened on).
    struct AddRule: Sendable, Equatable {
        enum Scope: String, CaseIterable, Sendable {
            case everywhere
            case project
            case sender
            /// A line of the charter's Voice section, not a learning.
            case voice

            var title: String {
                switch self {
                case .everywhere: "Everywhere"
                case .project: "This project"
                case .sender: "This sender"
                case .voice: "Voice"
                }
            }
        }

        var scope: Scope = .everywhere
        var text = ""
        /// The slug "This project" means, when there is one.
        var project: String?
        /// The name "This sender" means, when there is one.
        var sender: String?

        func isAvailable(_ scope: Scope) -> Bool {
            switch scope {
            case .everywhere, .voice: true
            case .project: project != nil
            case .sender: sender != nil
            }
        }

        /// The `--scope` value `cos rule` takes.
        var scopeArgument: String {
            switch scope {
            case .everywhere: "all"
            case .project: project.map { "project:\($0)" } ?? "all"
            case .sender: sender.map { "sender:\($0)" } ?? "all"
            case .voice: "all"
            }
        }
    }

    /// ⌘D: what Discuss opens in a new ordinary chat.
    struct Discussion: Sendable, Equatable {
        var title: String
        /// The card as text, attached as a selection chip.
        var cardText: String
        /// Its source files that exist on this Mac.
        var files: [URL]
        /// The card Tell Chief of Staff names (`cos tell --card`).
        var cardID: String?
    }

    /// The collapsible sections of the list.
    enum Section: Sendable, Hashable {
        case decide
        case waiting
        case later
        case fyi
    }

    /// The board's columns, left to right.
    enum Column: Int, CaseIterable, Sendable, Identifiable {
        case decide
        case today
        case waiting
        case later
        case done

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .decide: "Decide"
            case .today: "Today"
            case .waiting: "Waiting"
            case .later: "Later"
            case .done: "Done this week"
            }
        }
    }

    /// ⌘L on a card: where the menu's highlight is, and a typed day.
    struct LaterMenu: Sendable, Equatable {
        let proposalID: String
        var index = 0
        var isPicking = false
        var pickText = ""
    }

    /// ⌘N: a new canonical task, typed in a small sheet.
    struct NewTask: Sendable, Equatable {
        var title = ""
        var projectQuery = ""
        var projectSlug: String?
        var projectIndex = 0
        var due = ""
        var problem: String?
    }

    /// ⇧⌘P: the project filter's fuzzy picker.
    struct ProjectPicker: Sendable, Equatable {
        var query = ""
        var index = 0
    }

    // MARK: - State

    /// The thread's turns, in order.
    private(set) var items: [ChiefOfStaffThreadItem] = [] {
        didSet {
            pending = ChiefOfStaffThread.waiting(in: items)
            history = ChiefOfStaffThread.history(in: items)
        }
    }
    /// Every pending card, newest first, before tiers and the filter.
    private(set) var pending: [Proposal] = []
    /// Decided cards and other surfaces' chat turns, in thread order.
    private(set) var history: [ChiefOfStaffThreadItem] = []
    private(set) var status: CosStatus?
    private(set) var isPaused = false
    /// Why the thread or the CLI could not be read, in one sentence.
    private(set) var problem: String?
    /// The CLI is installed. False on a Mac without it: no row, no chat.
    private(set) var isAvailable: Bool
    private(set) var cards: [String: ProposalCardState] = [:]
    /// Active projects, from `cos projects --json`.
    private(set) var projects: [CosProject] = []
    /// The card the next pinned-chat message is about (`setSubject`).
    private(set) var subjectCardID: String?
    /// Branches with a `cos tell` running, and how many.
    private(set) var telling: [UUID: Int] = [:]
    /// The branch conversation about a card, from the chat's records.
    @ObservationIgnored var branchLookup: ((String) -> UUID?)?
    /// A Do it on card `id` ran: its branch, if any, merges back.
    @ObservationIgnored var onCardDone: ((String) -> Void)?
    /// Puts the window's keyboard on a card a reply just made.
    @ObservationIgnored var onFocusCard: ((String) -> Void)?
    /// A branch's `cos tell` finished: its reply, or why not.
    @ObservationIgnored var onTold: ((UUID, Result<CosTellReply, any Error>) -> Void)?
    /// The card the keyboard is on, or nil (the composer has it).
    var focusedCardID: String? {
        didSet { if let proposal = proposal(focusedCardID) { lastFocusedProposal = proposal } }
    }
    /// The last card the keyboard was on, for Add rule's "This project".
    @ObservationIgnored private var lastFocusedProposal: Proposal?
    /// Bumped to move the keyboard into the focused card's first field.
    private(set) var editFocusRequest = 0
    /// Why the last turn could not be recorded in the thread.
    private(set) var recordProblem: String?
    /// One short line after an action that leaves no card to show it on.
    private(set) var notice: String?

    var viewMode: ViewMode = .list {
        didSet {
            guard viewMode != oldValue else { return }
            refocus()
            switch viewMode {
            case .activity:
                send(.loadActivity(day: activityDay))
                // The model-call line is today's, read fresh.
                send(.refresh)
            case .artifacts: send(.loadArtifacts)
            case .charter: send(.loadCharter)
            case .list, .board: break
            }
        }
    }
    var lessPrompt: LessPrompt?
    private(set) var rungOffer: RungOffer?
    var addRule: AddRule?
    /// Activity: the day shown (nil is today) and what `cos` said of it.
    private(set) var activityDay: String?
    private(set) var activity: CosActivity?
    private(set) var artifacts: [CosArtifact] = []
    private(set) var charter: CosCharter?
    private(set) var rungs: [CosRung] = []
    /// Learnings, newest first (`cos learnings --json`).
    private(set) var learnings: [CosLearning] = []
    /// Why Activity, Artifacts or the Charter could not be read.
    private(set) var viewProblem: String?
    /// Cards run by ⇧⌘↩: no "Always" offer for a bulk run.
    @ObservationIgnored private var bulkIDs: Set<String> = []
    /// Discuss (⌘D): the window opens a new ordinary chat with it.
    @ObservationIgnored var onDiscuss: ((Discussion) -> Void)?
    /// Opens a file in its default app (`/usr/bin/open`), only on an
    /// explicit action. The app sets it.
    @ObservationIgnored var fileOpener: (any LocalFileOpening)?
    /// The data directory, for Prepare's files.
    @ObservationIgnored let paths: CosPaths?
    /// Only this project's cards, in both views.
    private(set) var projectFilter: String?
    var expanded: Set<Section> = []
    var isHealthDetailShown = false
    var laterMenu: LaterMenu?
    var newTask: NewTask?
    var projectPicker: ProjectPicker?
    /// ⇧⌘↩ pressed once: the TODAY rows it will run on the second press.
    private(set) var bulkArmed: [String]?
    /// Board: the canonical task tree of the filtered project is shown.
    private(set) var showsTasks = false
    private(set) var tasks: [CosTask] = []
    private(set) var tasksProblem: String?

    /// Open the pinned conversation (a notification's Open), on a card.
    @ObservationIgnored var onOpen: ((_ proposalID: String?) -> Void)?
    /// A notification's Reply: open the conversation and send the text.
    @ObservationIgnored var onReply: ((_ text: String) -> Void)?

    @ObservationIgnored private let files: CosFiles?
    @ObservationIgnored private let runner: (any CosRunning)?
    @ObservationIgnored private let notifier: (any ChiefOfStaffNotifying)?
    @ObservationIgnored private let quietHours: QuietHours
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let commands: AsyncStream<Command>
    @ObservationIgnored private let commandSink: AsyncStream<Command>.Continuation
    /// Pending ids already announced; nil until the first read, which only
    /// seeds it (those cards were announced before this launch).
    @ObservationIgnored private var announced: Set<String>?
    /// Jobs red at the last read; nil until the first read.
    @ObservationIgnored private var knownRed: Set<String>?

    init(
        paths: CosPaths?,
        runner: (any CosRunning)? = nil,
        notifier: (any ChiefOfStaffNotifying)? = nil,
        quietHours: QuietHours = .standard,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        files = paths.map(CosFiles.init(paths:))
        self.runner = runner ?? paths.map { CosCLI(executable: $0.executable) }
        self.notifier = notifier
        self.quietHours = quietHours
        self.clock = clock
        isAvailable = paths != nil
        (commands, commandSink) = AsyncStream.makeStream(of: Command.self)
        notifier?.onChoice = { [weak self] choice in self?.handle(choice) }
    }

    // MARK: - Tiers

    var now: Date { clock() }

    private func inFilter(_ proposal: Proposal) -> Bool {
        guard let projectFilter else { return true }
        return proposal.project == projectFilter
    }

    private func pending(_ tier: Proposal.Tier) -> [Proposal] {
        pending.filter { $0.tierKind == tier && inFilter($0) }
    }

    /// The live health card: the header's status line, never a card.
    var health: Proposal? { pending.first { $0.tierKind == .system } }

    /// DECIDE: needs his decision; the only tier that interrupts.
    var decide: [Proposal] { pending(.decide) }
    /// DECIDE as drawn: three until "Show all".
    var visibleDecide: [Proposal] {
        expanded.contains(.decide) ? decide : Array(decide.prefix(Self.decideVisibleLimit))
    }
    /// TODAY: quick one-tap actions, the morning brief pinned first.
    var today: [Proposal] {
        let cards = pending(.today)
        return cards.filter(\.isMorning) + cards.filter { !$0.isMorning }
    }
    /// WAITING ON OTHERS.
    var waitingOnOthers: [Proposal] { pending(.waiting) }
    /// FYI: waiting FYI cards, then what a rung ran by itself this week
    /// ("I did this").
    var fyi: [Proposal] {
        let since = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let ranByItself = items.compactMap(\.proposal)
            .filter { $0.auto && $0.status == .done && inFilter($0) && ($0.decided ?? $0.created ?? .distantPast) >= since }
            .reversed()
        return pending(.fyi) + ranByItself
    }

    /// LATER: hidden until a time, soonest back first.
    var later: [Proposal] {
        items.compactMap(\.proposal)
            .filter { $0.status == .later && inFilter($0) }
            .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
    }

    /// Done in the last seven days, newest first (the board's last column).
    var doneThisWeek: [Proposal] {
        let since = now.addingTimeInterval(-7 * 24 * 60 * 60)
        return items.compactMap(\.proposal)
            .filter { $0.status == .done && inFilter($0) && ($0.decided ?? $0.created ?? .distantPast) >= since }
            .sorted { ($0.decided ?? $0.created ?? .distantPast) > ($1.decided ?? $1.created ?? .distantPast) }
    }

    /// The history under the tiers, narrowed to the filtered project (whose
    /// cards only; chat is not per project).
    var filteredHistory: [ChiefOfStaffThreadItem] {
        guard projectFilter != nil else { return history }
        return history.filter { $0.proposal.map(inFilter) ?? false }
    }

    /// EARLIER as drawn: no digest bookkeeping, auto-closed cards folded.
    var earlier: [ChiefOfStaffThread.EarlierEntry] {
        ChiefOfStaffThread.earlier(filteredHistory, in: items)
    }

    /// The count on the rail row and the launcher: cards that want him now
    /// (DECIDE and TODAY), whatever the filter.
    var waitingCount: Int {
        pending.filter { $0.tierKind == .decide || $0.tierKind == .today }.count
    }

    /// "3 waiting", "Paused · 3 waiting", or "Nothing waiting".
    var summary: String {
        let count = waitingCount == 0 ? "Nothing waiting" : "\(waitingCount) waiting"
        return isPaused ? "Paused · \(count)" : count
    }

    /// The header's health line: the live health card's headline, or that
    /// the jobs are fine.
    var healthLine: String {
        guard let health else { return "Jobs running" }
        return health.headline
    }

    func column(_ column: Column) -> [Proposal] {
        switch column {
        case .decide: decide
        case .today: today
        case .waiting: waitingOnOthers
        case .later: later
        case .done: doneThisWeek
        }
    }

    var filteredProject: CosProject? {
        projectFilter.flatMap { slug in projects.first { $0.slug == slug } }
    }

    // MARK: - Cards

    func card(_ id: String) -> ProposalCardState {
        if let card = cards[id] { return card }
        let card = ProposalCardState()
        cards[id] = card
        return card
    }

    func proposal(_ id: String?) -> Proposal? {
        guard let id else { return nil }
        return items.compactMap(\.proposal).first { $0.id == id }
    }

    var focusedProposal: Proposal? { proposal(focusedCardID) }

    /// Whether the keyboard is inside a card's Edit fields.
    var isEditingFocusedCard: Bool {
        focusedCardID.flatMap { cards[$0]?.isEditing } == true
    }

    func apply(_ newItems: [ChiefOfStaffThreadItem]) {
        items = named(newItems)
        // Every card has its state before a view reads it, so a render
        // never writes the model.
        for proposal in newItems.compactMap(\.proposal) where cards[proposal.id] == nil {
            cards[proposal.id] = ProposalCardState()
        }
        refocus()
    }

    /// Each card's project name from the projects strip, so every surface
    /// (cards, rows, the board, notifications) says "Acme Amplify", not
    /// its slug.
    private func named(_ items: [ChiefOfStaffThreadItem]) -> [ChiefOfStaffThreadItem] {
        let names = Dictionary(projects.map { ($0.slug, $0.shortName) }, uniquingKeysWith: { first, _ in first })
        return items.map { item in
            guard case .proposal(let turn, var proposal) = item else { return item }
            proposal.projectName = names[proposal.project]
            return .proposal(turnID: turn, proposal)
        }
    }

    /// A focused card that left the view hands the focus on.
    private func refocus() {
        guard let focusedCardID, !focusOrder.contains(focusedCardID) else { return }
        self.focusedCardID = focusOrder.first
    }

    // MARK: - The pinned chat

    /// The system message for a request in chat `id`: the Chief of Staff
    /// instruction, the waiting cards and the last twelve proposals; in a
    /// Discuss chat (`discussing` names its card), the Discuss instruction.
    /// Nil for any other chat.
    func systemMessage(forChat id: UUID, discussing: String? = nil, made: [String] = []) -> String? {
        if id != Self.conversationID, let discussing {
            let card = proposal(discussing)
            return ChiefOfStaffPrompt.branchMessage(
                card: card,
                project: card.flatMap { $0.projectName ?? ($0.project.isEmpty ? nil : $0.project) },
                charter: charterCore,
                made: made.compactMap { proposal($0) }
            )
        }
        guard id == Self.conversationID else { return nil }
        return ChiefOfStaffPrompt.systemMessage(
            waiting: pending.filter { $0.tierKind != .system },
            recent: ChiefOfStaffThread.recentProposals(in: items, limit: Self.recentProposalLimit),
            paused: isPaused,
            now: clock()
        )
    }

    /// A question in chat `id` got its answer: both turns go to the thread.
    func chatDidAnswer(id: UUID, question: String, answer: String, attachmentNames: [String]) {
        guard id == Self.conversationID else { return }
        send(.recordTurn(question: question, answer: answer, attachmentNames: attachmentNames))
    }

    // MARK: - Tell

    /// The answerer of a question in chat `id`: in the pinned chat, one
    /// `cos tell` call, about the subject card when there is one (the
    /// subject is then used up). Nil in every other chat.
    func tellService(forChat id: UUID, text: String) -> (any QuickService)? {
        guard id == Self.conversationID, isAvailable, let runner else { return nil }
        let card = subjectCardID
        subjectCardID = nil
        return CosTellService(runner: runner, command: .tell(text: text, card: card, surface: .pinned)) { [weak self] _ in
            await self?.reload(force: true)
        }
    }

    /// A branch message to `cos tell` about `card`, then a fresh read so
    /// the card it made is there to draw, then the reply to `onTold` for
    /// branch `chat`. Messages run one after another per branch, in order.
    private func branchTell(_ text: String, about card: String, fromChat chat: UUID) async {
        guard let runner else { return }
        telling[chat, default: 0] += 1
        let outcome: Result<CosTellReply, any Error>
        do {
            outcome = .success(try CosTellReply.parse(try await runner.run(.tell(text: text, card: card, surface: .branch))))
            await reload(force: true)
        } catch {
            outcome = .failure(error)
        }
        telling[chat, default: 1] -= 1
        if telling[chat] == 0 { telling[chat] = nil }
        onTold?(chat, outcome)
    }

    // MARK: - Branches

    /// The branch conversation about `card`, newest first: the chat's own
    /// record, else the thread's link.
    func branch(for card: String) -> UUID? {
        branchLookup?(card) ?? ChiefOfStaffThread.branches(in: items)[card]?.last
    }

    /// The last merge-back line written for `branch`, with the branch's
    /// message count then.
    func lastSummary(of branch: UUID) -> ChiefOfStaffThread.BranchLink? {
        for case .branch(_, let link, let summary?) in items.reversed() where link.branch == branch && !summary.isEmpty {
            return link
        }
        return nil
    }

    /// The charter's policy core for a branch's system message: Voice,
    /// Watch, Ignore, Style and Quiet, within the budget `cos` uses.
    var charterCore: String? {
        guard let charter else { return nil }
        let keys = ["voice", "watch", "ignore", "style", "quiet"]
        let text = charter.sections
            .filter { keys.contains($0.key) }
            .map { section in
                let body = (section.prose + section.lines.map { "- \($0)" })
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                return body.isEmpty ? "" : "\(section.name.uppercased())\n\(body)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        return text.count > Self.charterCoreLimit ? String(text.prefix(Self.charterCoreLimit)) + "…" : text
    }

    nonisolated static let charterCoreLimit = 1500

    /// The card the next message in the pinned chat is about: typing on a
    /// card, ↩ on it, or a notification Reply names it.
    func setSubject(_ id: String?) {
        subjectCardID = id.flatMap { proposal($0) == nil ? nil : $0 }
    }

    var subject: Proposal? { proposal(subjectCardID) }

    /// A reply made card `id`: the keyboard goes onto it, in the List,
    /// when it waits there (a card still in review is not shown yet).
    /// False leaves the keyboard where it was.
    @discardableResult
    func focusTold(_ id: String) -> Bool {
        guard let card = proposal(id), card.isWaiting, !card.awaitsReview else { return false }
        if viewMode != .list { viewMode = .list }
        focusCard(id)
        guard focusedCardID == id else { return false }
        onFocusCard?(id)
        return true
    }

    // MARK: - Keyboard focus

    /// The cards the keyboard walks in the list, top to bottom: DECIDE as
    /// drawn, TODAY, then the open collapsed sections.
    var listFocusOrder: [String] {
        var ids = visibleDecide.map(\.id) + today.map(\.id)
        if expanded.contains(.waiting) { ids += waitingOnOthers.map(\.id) }
        if expanded.contains(.later) { ids += later.map(\.id) }
        if expanded.contains(.fyi) { ids += fyi.map(\.id) }
        return ids
    }

    var focusOrder: [String] {
        switch viewMode {
        case .list: listFocusOrder
        case .board: Column.allCases.flatMap { column($0).map(\.id) }
        case .activity: []
        case .artifacts: artifacts.map(\.id)
        case .charter: learnings.map { "learning:\($0.key)" } + rungs.map(\.id)
        }
    }

    /// The card that ↑ from the composer lands on, or nil.
    var firstFocusable: String? { focusOrder.first }

    /// Move the keyboard `delta` cards on. Past the last card of the list it
    /// goes back to the composer (nil); the board stops at a column's ends.
    @discardableResult
    func moveCardFocus(_ delta: Int) -> Bool {
        dismissTransient()
        switch viewMode {
        case .list:
            let order = focusOrder
            guard !order.isEmpty else {
                focusedCardID = nil
                return false
            }
            guard let current = focusedCardID, let index = order.firstIndex(of: current) else {
                focusedCardID = order.first
                return true
            }
            let next = index + delta
            if next < 0 { return true }
            focusedCardID = next < order.count ? order[next] : nil
            return true
        case .activity, .artifacts, .charter:
            let order = focusOrder
            guard !order.isEmpty else {
                focusedCardID = nil
                return false
            }
            let index = focusedCardID.flatMap { order.firstIndex(of: $0) }.map { $0 + delta } ?? 0
            if index < 0 { return true }
            focusedCardID = index < order.count ? order[index] : nil
            return true
        case .board:
            guard let (column, row) = boardPosition else {
                focusedCardID = firstFocusable
                return focusedCardID != nil
            }
            let cards = self.column(column)
            focusedCardID = cards[max(0, min(cards.count - 1, row + delta))].id
            return true
        }
    }

    /// Board ←→: the next column with a card, at the same row or its last.
    func moveColumnFocus(_ delta: Int) {
        dismissTransient()
        guard let (current, row) = boardPosition else {
            focusedCardID = firstFocusable
            return
        }
        var index = current.rawValue + delta
        while let column = Column(rawValue: index) {
            let cards = self.column(column)
            if !cards.isEmpty {
                focusedCardID = cards[min(row, cards.count - 1)].id
                return
            }
            index += delta
        }
    }

    private var boardPosition: (Column, Int)? {
        guard let focusedCardID else { return nil }
        for column in Column.allCases {
            if let row = self.column(column).firstIndex(where: { $0.id == focusedCardID }) { return (column, row) }
        }
        return nil
    }

    func focusCard(_ id: String?) {
        dismissTransient()
        if let id, let proposal = proposal(id), viewMode == .list {
            // A card behind a collapsed section opens it.
            if proposal.status == .later {
                expanded.insert(.later)
            } else if proposal.tierKind == .waiting {
                expanded.insert(.waiting)
            } else if proposal.tierKind == .fyi {
                expanded.insert(.fyi)
            } else if proposal.tierKind == .decide, !visibleDecide.contains(where: { $0.id == id }) {
                expanded.insert(.decide)
            }
        }
        focusedCardID = id.flatMap { focusOrder.contains($0) ? $0 : nil } ?? focusOrder.first
    }

    func releaseCardFocus() {
        if let focusedCardID { cards[focusedCardID]?.isEditing = false }
        focusedCardID = nil
        dismissTransient()
    }

    /// Esc on a card: the Later menu, a bulk confirm, then an open Edit.
    private func dismissTransient() {
        laterMenu = nil
        bulkArmed = nil
        lessPrompt = nil
    }

    // MARK: - Feedback, rungs, undo, Discuss

    /// ⌘= on a card: More like this.
    func moreFocused() {
        guard let proposal = focusedProposal else { return }
        send(.more(id: proposal.id))
    }

    /// ⌘- on a card: Less like this, with an optional why.
    func lessFocused() {
        guard let proposal = focusedProposal else { return }
        laterMenu = nil
        lessPrompt = LessPrompt(proposalID: proposal.id)
    }

    /// Return in the Less prompt: `cos less`, with the why when one is typed.
    func submitLess() {
        guard let prompt = lessPrompt else { return }
        lessPrompt = nil
        let why = prompt.why.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.less(id: prompt.proposalID, why: why.isEmpty ? nil : why))
    }

    /// ⌘Y on the offer: a consent rung for these action types here.
    func acceptRungOffer() {
        guard let offer = rungOffer else { return }
        rungOffer = nil
        send(.always(id: offer.proposalID))
    }

    func dismissRungOffer() {
        rungOffer = nil
    }

    /// ⌘Z on a done or auto card: run its recorded undo steps.
    func undoFocused() {
        guard let proposal = focusedProposal, proposal.canUndo else { return }
        send(.undo(id: proposal.id))
    }

    /// ⌘D on a card or an artifact: a new ordinary chat about it.
    func discussFocused() {
        guard let discussion = focusedDiscussion else { return }
        onDiscuss?(discussion)
    }

    var focusedDiscussion: Discussion? {
        if let proposal = focusedProposal { return discussion(for: proposal) }
        if let artifact = artifacts.first(where: { $0.id == focusedCardID }) { return discussion(for: artifact) }
        return nil
    }

    func discussion(for proposal: Proposal) -> Discussion {
        Self.discussion(
            for: proposal,
            vault: FileManager.default.homeDirectoryForCurrentUser.appending(path: "vault", directoryHint: .isDirectory),
            data: paths?.data
        )
    }

    func discussion(for artifact: CosArtifact) -> Discussion {
        let card = proposal(artifact.card)
        var text = "Prepared file: \(artifact.name)"
        if card == nil, let headline = artifact.headline { text += "\nFor: \(headline)" }
        if let card { text += "\n\n" + Self.cardText(card) }
        let url = paths.map { artifact.url(in: $0) }
        let files = [url].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
        return Discussion(title: artifact.name, cardText: text, files: files, cardID: artifact.card)
    }

    /// The card as the text a new chat starts from: headline, why, the
    /// message, and the numbered actions.
    nonisolated static func cardText(_ proposal: Proposal) -> String {
        var lines = [proposal.headline]
        if !proposal.source.isEmpty { lines.append("From: \(proposal.source)") }
        if !proposal.why.isEmpty { lines.append("Why: \(proposal.why)") }
        lines.append("")
        lines.append(proposal.message)
        for (index, action) in proposal.actions.enumerated() {
            lines.append("\(index + 1). \(action.typeLabel): \(action.text)")
        }
        return lines.joined(separator: "\n")
    }

    /// What Discuss attaches: the card's text, its source files resolved
    /// under the vault (only ones that exist, never outside it), and its
    /// prepared files.
    nonisolated static func discussion(for proposal: Proposal, vault: URL, data: URL?) -> Discussion {
        let manager = FileManager.default
        let vaultPath = vault.standardizedFileURL.path(percentEncoded: false)
        var files: [URL] = []
        for path in proposal.paths where !path.isEmpty {
            let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : vault.appending(path: path)).standardizedFileURL
            guard url.path(percentEncoded: false).hasPrefix(vaultPath),
                  manager.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            files.append(url)
        }
        if let data {
            for artifact in proposal.artifacts {
                // Relative to the data dir (`artifacts/<id>/draft.md`), or to the card's folder.
                let relative = artifact.hasPrefix("artifacts/") ? artifact : "artifacts/\(proposal.id)/\(artifact)"
                let url = data.appending(path: relative).standardizedFileURL
                if manager.fileExists(atPath: url.path(percentEncoded: false)) { files.append(url) }
            }
        }
        var unique: [URL] = []
        for url in files where !unique.contains(url) { unique.append(url) }
        return Discussion(title: proposal.headline, cardText: cardText(proposal), files: unique, cardID: proposal.id)
    }

    // MARK: - Activity, Artifacts, Charter

    /// The day Activity shows moves by `delta` days; nil is today.
    func moveActivityDay(_ delta: Int, calendar: Calendar = .current) {
        let current = activityDay.flatMap { ChiefOfStaffDates.day($0, calendar: calendar) } ?? calendar.startOfDay(for: now)
        guard let next = calendar.date(byAdding: .day, value: delta, to: current) else { return }
        let today = calendar.startOfDay(for: now)
        activityDay = next >= today ? nil : ChiefOfStaffDates.string(next, calendar: calendar)
        send(.loadActivity(day: activityDay))
    }

    /// Return or ⌘O on an artifact, or Edit charter: the file in its
    /// default app. Never by itself.
    func openFocusedFile() {
        if viewMode == .charter, let path = charter?.path {
            send(.open(URL(fileURLWithPath: path)))
            return
        }
        guard let paths, let artifact = artifacts.first(where: { $0.id == focusedCardID }) else { return }
        send(.open(artifact.url(in: paths)))
    }

    /// ⌘⌫ on a row in the Charter: forget a learning, or remove a rung.
    func removeFocusedRung() {
        guard viewMode == .charter, let id = focusedCardID else { return }
        if id.hasPrefix("learning:") {
            send(.forget(key: String(id.dropFirst("learning:".count))))
        } else if let rung = rungs.first(where: { $0.id == id }) {
            send(.never(rung: rung.rung))
        }
    }

    /// ⌘N in the Charter: a new learning; Return adds it. "This project"
    /// and "This sender" come from the filter or the last focused card.
    func openAddRule(from proposal: Proposal? = nil) {
        let card = proposal ?? focusedProposal ?? lastFocusedProposal
        let project = projectFilter ?? card.flatMap { $0.project.isEmpty ? nil : $0.project }
        let sender = card.flatMap { $0.sender.isEmpty ? nil : Self.senderName($0.sender) }
        addRule = AddRule(project: project, sender: sender)
    }

    /// "Sam Client <sam@example.com>" is "Sam Client".
    static func senderName(_ sender: String) -> String {
        let name = sender.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? sender
        return name.isEmpty ? sender : name
    }

    func setAddRuleScope(_ scope: AddRule.Scope) {
        guard addRule?.isAvailable(scope) == true else { return }
        addRule?.scope = scope
    }

    func submitAddRule() {
        guard let draft = addRule else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        addRule = nil
        if draft.scope == .voice {
            send(.charterLine(text: text, section: "voice"))
        } else {
            send(.rule(text: text, scope: draft.scopeArgument))
        }
    }

    /// A learnings card: forget one of the two rows that disagree.
    func forgetConflict(_ index: Int, on proposal: Proposal? = nil) {
        guard let card = proposal ?? focusedProposal, let conflict = card.conflict,
              conflict.keys.indices.contains(index) else { return }
        send(.forget(key: conflict.keys[index]))
    }

    // MARK: - Card actions

    /// ⌘↩ on a card: Do it (Got it on a card with nothing to run), or Run
    /// while editing.
    func doFocused() {
        guard let proposal = focusedProposal, proposal.isWaiting else { return }
        // Busy, or cut off by a crash: nothing runs from a key.
        guard card(proposal.id).isEditing || proposal.canDoIt else { return }
        dismissTransient()
        send(card(proposal.id).isEditing ? .runEdit(id: proposal.id) : .doIt(id: proposal.id))
    }

    /// ⌘E on a card: its actions become fields.
    func editFocused() {
        guard let proposal = focusedProposal, proposal.isWaiting, !proposal.isNotice else { return }
        beginEdit(proposal)
    }

    /// ⌘⌫ on a card: No. Nothing runs.
    func noFocused() {
        guard let proposal = focusedProposal, proposal.isWaiting, !card(proposal.id).isEditing else { return }
        dismissTransient()
        send(.no(id: proposal.id))
    }

    /// ⌘R on a card: bring a Later, No, handled or expired card back now.
    func bringBackFocused() {
        guard let proposal = focusedProposal, proposal.canBringBack else { return }
        send(.reopen(id: proposal.id))
    }

    /// ⌘L on a card: the Later menu.
    func openLaterMenu() {
        guard let proposal = focusedProposal, proposal.isWaiting, !card(proposal.id).isEditing else { return }
        bulkArmed = nil
        laterMenu = LaterMenu(proposalID: proposal.id)
    }

    func moveLaterMenu(_ delta: Int) {
        guard var menu = laterMenu, !menu.isPicking else { return }
        menu.index = ListSelection.wrappedIndex(menu.index, by: delta, count: LaterChoice.allCases.count)
        laterMenu = menu
    }

    /// Return or a click in the Later menu. Pick date asks for a day first.
    func chooseLater(_ choice: LaterChoice? = nil) {
        guard var menu = laterMenu else { return }
        let choice = choice ?? LaterChoice(rawValue: menu.index) ?? .tomorrow
        if choice == .pickDate, !menu.isPicking {
            menu.index = choice.rawValue
            menu.isPicking = true
            laterMenu = menu
            return
        }
        var picked: String?
        if choice == .pickDate {
            guard let day = ChiefOfStaffDates.parseDay(menu.pickText, now: now) else {
                notice = "Type a day: tomorrow, fri, 2026-10-02."
                return
            }
            picked = day
        }
        guard let until = choice.until(picked: picked) else { return }
        laterMenu = nil
        notice = nil
        send(.later(id: menu.proposalID, until: until))
    }

    func setLaterPickText(_ text: String) {
        laterMenu?.pickText = text
    }

    func beginEdit(_ proposal: Proposal) {
        let card = card(proposal.id)
        guard !card.isRunning else { return }
        dismissTransient()
        focusedCardID = proposal.id
        card.drafts = ActionDraft.drafts(for: proposal)
        card.isEditing = true
        editFocusRequest &+= 1
    }

    func cancelEdit(_ id: String) {
        cards[id]?.isEditing = false
    }

    /// ⇧⌘↩: Do all visible TODAY rows. The first press arms it and says how
    /// many; the second runs them. Any other key disarms it.
    func doAllToday() {
        // The morning brief is read, not run: it keeps its own Got it.
        let ids = today.filter { !$0.isMorning && $0.canDoIt && !(cards[$0.id]?.isRunning ?? false) }.map(\.id)
        guard !ids.isEmpty else { return }
        if let armed = bulkArmed, armed == ids {
            bulkArmed = nil
            bulkIDs.formUnion(ids)
            for id in ids { send(.doIt(id: id)) }
        } else {
            laterMenu = nil
            bulkArmed = ids
        }
    }

    // MARK: - Views, filter, sheets

    func toggleSection(_ section: Section) {
        if expanded.contains(section) { expanded.remove(section) } else { expanded.insert(section) }
        refocus()
    }

    func setProjectFilter(_ slug: String?) {
        projectFilter = slug
        projectPicker = nil
        tasks = []
        tasksProblem = nil
        if showsTasks, let slug { send(.loadTasks(project: slug)) }
        refocus()
    }

    /// ⇧⌘P: the picker; again closes it.
    func toggleProjectPicker() {
        projectPicker = projectPicker == nil ? ProjectPicker() : nil
    }

    /// The projects a query names, best first (`All projects` is the view's).
    func matchingProjects(_ query: String) -> [CosProject] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return projects }
        let folded = FuzzyMatcher.fold(trimmed)
        return projects
            .compactMap { project -> (CosProject, Int)? in
                let score = [project.name, project.slug]
                    .compactMap { FuzzyMatcher.score(foldedQuery: folded, foldedCandidate: FuzzyMatcher.fold($0)) }
                    .max()
                return score.map { (project, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// ⇧⌘T on the board: the filtered project's canonical task lanes.
    func toggleTasks() {
        showsTasks.toggle()
        if showsTasks, let projectFilter { send(.loadTasks(project: projectFilter)) }
    }

    /// ⌘N: the New task sheet, on the filtered project when there is one.
    func openNewTask(title: String = "") {
        laterMenu = nil
        var draft = NewTask(title: title)
        if let project = filteredProject ?? focusedProposal.flatMap({ card in projects.first { $0.slug == card.project } }) {
            draft.projectSlug = project.slug
            draft.projectQuery = project.name
        }
        newTask = draft
    }

    /// Return or ⌘↩ in the sheet: `cos add`. The sheet stays with a line
    /// saying what is missing.
    func submitNewTask() {
        guard var draft = newTask else { return }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        // A typed project that was never picked from the list: its best match.
        let query = draft.projectQuery.trimmingCharacters(in: .whitespaces)
        let project = draft.projectSlug ?? (query.isEmpty ? nil : matchingProjects(query).first?.slug)
        guard !title.isEmpty else {
            draft.problem = "Type the task."
            newTask = draft
            return
        }
        guard !title.hasPrefix("-") else {
            draft.problem = "A task cannot start with a dash."
            newTask = draft
            return
        }
        guard let project else {
            draft.problem = "Pick a project."
            newTask = draft
            return
        }
        var due: String?
        if !draft.due.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let day = ChiefOfStaffDates.parseDay(draft.due, now: now) else {
                draft.problem = "Due: tomorrow, fri, or 2026-10-02."
                newTask = draft
                return
            }
            due = day
        }
        newTask = nil
        send(.addTask(title: title, project: project, due: due))
    }

    // MARK: - Commands

    func send(_ command: Command) {
        commandSink.yield(command)
    }

    /// Runs until cancelled. Call once, from the app's root task.
    func run() async {
        guard let files else { return }
        isAvailable = await files.cliExists()
        guard isAvailable else { return }
        await notifier?.prepare()
        await reload(force: true)
        await withDiscardingTaskGroup { group in
            group.addTask { await self.pollThread() }
            group.addTask { await self.keepAlive() }
            group.addTask { await self.pollProjects() }
            for await command in commands {
                group.addTask { await self.perform(command) }
            }
        }
    }

    private func pollThread() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            await reload(force: false)
        }
    }

    private func keepAlive() async {
        guard let files else { return }
        while !Task.isCancelled {
            await files.touchAlive(now: clock())
            try? await Task.sleep(for: Self.aliveInterval)
        }
    }

    private func pollProjects() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.projectsInterval)
            await refreshProjects()
        }
    }

    /// Read the thread if it moved and the pause flag, then ask the CLI for
    /// its numbers and projects when either changed, and announce what is new.
    func reload(force: Bool) async {
        guard let files else { return }
        let read = await files.readThreadIfChanged(force: force)
        let paused = await files.isPaused()
        var changed = force || paused != isPaused
        isPaused = paused
        switch read {
        case .unchanged:
            break
        case .missing:
            apply([])
            problem = nil
            changed = true
        case .record(let record):
            apply(ChiefOfStaffThread.items(in: record))
            problem = nil
            changed = true
        case .unreadable(let reason):
            problem = "The thread could not be read: \(reason)"
        }
        if changed {
            await refreshStatus()
            await refreshProjects()
        }
        await announceNewCards()
    }

    private func refreshStatus() async {
        guard let runner else { return }
        do {
            let result = try await runner.run(.status)
            guard result.succeeded else {
                problem = "cos status failed: " + (OutcomeLine.lastLine(of: result.stderr) ?? "exit \(result.exitCode)")
                return
            }
            status = try CosStatus.decode(result.stdout)
            isPaused = status?.paused ?? isPaused
        } catch {
            problem = "cos did not answer: \(error.localizedDescription)"
        }
    }

    private func refreshProjects() async {
        guard let runner else { return }
        guard let result = try? await runner.run(.projects), result.succeeded,
              let list = try? CosProject.decodeList(result.stdout)
        else { return }
        projects = list
        items = named(items)
    }

    /// The notices for cards that appeared, and jobs that turned red, since
    /// the last read. The first read only seeds both.
    func announceNewCards() async {
        let ids = Set(pending.map(\.id))
        let red = Set(health?.red ?? [])
        guard var announced, let knownRed else {
            self.announced = ids
            self.knownRed = red
            return
        }
        // Oldest first, so the notifications stack in arrival order.
        let fresh = pending.filter { !announced.contains($0.id) }.reversed()
        let newlyRed = (health?.red ?? []).filter { !knownRed.contains($0) }
        announced.formUnion(ids)
        self.announced = announced
        self.knownRed = red
        guard let notifier else { return }
        let notices = ChiefOfStaffNotificationRules.notices(
            for: Array(fresh),
            newlyRed: newlyRed,
            healthHeadline: health?.headline ?? "",
            now: clock(),
            quietHours: quietHours
        )
        for notice in notices { await notifier.post(notice) }
    }

    func perform(_ command: Command) async {
        switch command {
        case .doIt(let id):
            await verdict(id) { .doIt(id: id) }
        case .runEdit(let id):
            guard let card = cards[id], card.isEditing else { return }
            let actions = card.drafts.map(\.action)
            await verdict(id) { .edit(id: id, actions: actions) }
        case .no(let id):
            await verdict(id) { .no(id: id, reason: nil) }
        case .later(let id, let until):
            await verdict(id) { .later(id: id, until: until) }
        case .reopen(let id):
            await verdict(id) { .reopen(id: id) }
        case .addTask(let title, let project, let due):
            await addTask(title: title, project: project, due: due)
        case .loadTasks(let project):
            await loadTasks(project: project)
        case .more(let id):
            await feedback(id, .more(id: id), done: "More like this: noted.")
        case .less(let id, let why):
            await feedback(id, .less(id: id, why: why), done: "Less like this: noted.")
        case .always(let id):
            await simple(.always(id: id), done: "It will do this by itself from now on.")
            await loadRungsIfShown()
        case .never(let rung):
            await simple(.never(rung: rung), done: "Removed. It asks again next time.")
            await loadRungsIfShown()
        case .undo(let id):
            await verdict(id) { .undo(id: id) }
        case .rule(let text, let scope):
            await simple(.rule(text: text, scope: scope), done: "Learning added.")
            await loadCharter()
        case .charterLine(let text, let section):
            await simple(.charterLine(text: text, section: section), done: "Added to the charter.")
            await loadCharter()
        case .forget(let key):
            await simple(.forget(key: key), done: "Forgotten.")
            await reload(force: true)
            if viewMode == .charter { await loadLearnings() }
        case .loadActivity(let day):
            await loadActivity(day: day)
        case .loadArtifacts:
            await loadArtifacts()
        case .loadCharter:
            await loadCharter()
        case .open(let url):
            guard let fileOpener else { return }
            do {
                try await fileOpener.open(url)
            } catch {
                notice = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        case .recordTurn(let question, let answer, let names):
            await record(question: question, answer: answer, attachmentNames: names)
        case .tell(let text, let card, let chat):
            await branchTell(text, about: card, fromChat: chat)
        case .linkBranch(let card, let branch, let title):
            await appendBranch(kind: "branch", card: card, branch: branch, text: "Branch opened: \(title)", turns: nil)
        case .branchSummary(let card, let branch, let text, let turns):
            await appendBranch(kind: "branch_summary", card: card, branch: branch, text: text, turns: turns)
        case .refresh:
            await reload(force: true)
        }
    }

    /// One `cos` call on a card, its lines on the card, then a fresh read
    /// so the tiers and the counts move with it.
    private func verdict(_ id: String, _ command: () -> CosCommand) async {
        guard let runner else { return }
        let card = card(id)
        guard !card.isRunning else { return }
        card.isRunning = true
        card.outcome = nil
        let call = command()
        let order = focusOrder
        do {
            let result = try await runner.run(call)
            switch call {
            case .no:
                card.outcome = result.succeeded ? [OutcomeLine(ok: true, text: "Recorded as no.")] : OutcomeLine.lines(from: result)
            case .later, .reopen, .undo:
                let said = OutcomeLine.lastLine(of: result.stdout) ?? "Done."
                card.outcome = [result.succeeded ? OutcomeLine(ok: true, text: said) : OutcomeLine.lines(from: result)[0]]
            default:
                card.outcome = OutcomeLine.lines(from: result)
            }
            if result.succeeded || card.outcome?.contains(where: \.ok) == true { card.isEditing = false }
            notice = card.outcome?.first.map { ($0.ok ? "" : "Failed: ") + $0.text }
        } catch {
            card.outcome = [OutcomeLine(ok: false, text: "cos did not finish: \(error.localizedDescription)")]
        }
        card.isRunning = false
        // "Always do this for <project>?" after a single Do it that ran.
        if case .doIt = call, let proposal = proposal(id), proposal.offersRung,
           card.outcome?.allSatisfy(\.ok) == true, !bulkIDs.contains(id) {
            rungOffer = RungOffer(
                proposalID: id,
                project: proposal.projectName ?? (proposal.project.isEmpty ? "all projects" : proposal.project),
                types: proposal.actions.map(\.typeLabel)
            )
        }
        bulkIDs.remove(id)
        await reload(force: true)
        // A card a branch made merges its branch back once it ran.
        if case .doIt = call, proposal(id)?.status == .done { onCardDone?(id) }
        // The card left the view: the keyboard moves to its neighbour.
        if focusedCardID == nil || !focusOrder.contains(focusedCardID ?? ""), let index = order.firstIndex(of: id) {
            let rest = focusOrder
            focusedCardID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)]
        }
    }

    /// One `cos` call whose outcome is one line of notice.
    private func simple(_ command: CosCommand, done: String) async {
        guard let runner else { return }
        do {
            let result = try await runner.run(command)
            notice = result.succeeded ? done : "Failed: " + (OutcomeLine.lastLine(of: result.stderr) ?? "exit \(result.exitCode)")
        } catch {
            notice = "Failed: \(error.localizedDescription)"
        }
    }

    private func feedback(_ id: String, _ command: CosCommand, done: String) async {
        await simple(command, done: done)
        await reload(force: true)
    }

    private func loadActivity(day: String?) async {
        guard let runner else { return }
        do {
            let result = try await runner.run(.activity(day: day))
            guard day == activityDay else { return }
            guard result.succeeded else {
                viewProblem = "Activity: " + (OutcomeLine.lastLine(of: result.stderr) ?? "exit \(result.exitCode)")
                return
            }
            activity = try CosActivity.decode(result.stdout)
            viewProblem = nil
        } catch {
            viewProblem = "Activity could not be read: \(error.localizedDescription)"
        }
    }

    private func loadArtifacts() async {
        guard let runner else { return }
        do {
            let result = try await runner.run(.artifacts)
            guard result.succeeded else {
                viewProblem = "Artifacts: " + (OutcomeLine.lastLine(of: result.stderr) ?? "exit \(result.exitCode)")
                return
            }
            artifacts = try CosArtifact.decodeList(result.stdout)
            viewProblem = nil
        } catch {
            viewProblem = "Artifacts could not be read: \(error.localizedDescription)"
        }
    }

    private func loadCharter() async {
        guard let runner else { return }
        do {
            let result = try await runner.run(.charter)
            guard result.succeeded else {
                viewProblem = "Charter: " + (OutcomeLine.lastLine(of: result.stderr) ?? "exit \(result.exitCode)")
                return
            }
            charter = try CosCharter.decode(result.stdout)
            if let charter, !charter.rungs.isEmpty { rungs = charter.rungs }
            viewProblem = nil
        } catch {
            viewProblem = "The charter could not be read: \(error.localizedDescription)"
        }
        await loadRungs()
        await loadLearnings()
    }

    private func loadLearnings() async {
        guard let runner, let result = try? await runner.run(.learnings), result.succeeded,
              let list = try? CosLearning.decodeList(result.stdout) else { return }
        learnings = list
    }

    private func loadRungsIfShown() async {
        if viewMode == .charter { await loadRungs() }
    }

    private func loadRungs() async {
        guard let runner, let result = try? await runner.run(.rungs), result.succeeded,
              let list = try? CosRung.decodeList(result.stdout) else { return }
        rungs = list
    }

    private func addTask(title: String, project: String, due: String?) async {
        guard let runner else { return }
        do {
            let result = try await runner.run(.add(title: title, project: project, due: due))
            notice = result.succeeded
                ? "Task added to \(projects.first { $0.slug == project }?.name ?? project)."
                : "Task not added: " + (OutcomeLine.lastLine(of: result.stderr) ?? "exit \(result.exitCode)")
        } catch {
            notice = "Task not added: \(error.localizedDescription)"
        }
        await refreshProjects()
        if showsTasks, projectFilter == project { await loadTasks(project: project) }
    }

    private func loadTasks(project: String) async {
        guard let runner else { return }
        do {
            let result = try await runner.run(.tasks(project: project))
            guard projectFilter == project else { return }
            tasks = result.succeeded ? try CosTask.decodeList(result.stdout) : []
            tasksProblem = result.succeeded ? nil : OutcomeLine.lastLine(of: result.stderr)
        } catch {
            tasksProblem = error.localizedDescription
        }
    }

    /// A branch's link or merge-back line, as an assistant turn `cos`
    /// records with its meta.
    private func appendBranch(kind: String, card: String, branch: UUID, text: String, turns: Int?) async {
        guard let runner else { return }
        var meta = ["kind": kind, "card": card, "branch": branch.uuidString]
        if let turns { meta["turns"] = String(turns) }
        do {
            let result = try await runner.run(.append(role: .assistant, text: text, meta: meta))
            recordProblem = result.succeeded ? nil
                : "Could not record the branch: " + (OutcomeLine.lastLine(of: result.stderr) ?? "exit \(result.exitCode)")
        } catch {
            recordProblem = "Could not record the branch: \(error.localizedDescription)"
        }
        await reload(force: false)
    }

    /// Both turns of a question answered in Quick Launch, into the one
    /// thread through `cos append`, so the brain and other surfaces see them.
    private func record(question: String, answer: String, attachmentNames: [String]) async {
        guard let runner else { return }
        var meta: [String: String] = [:]
        if !attachmentNames.isEmpty { meta["attachments"] = attachmentNames.joined(separator: ", ") }
        do {
            let asked = try await runner.run(.append(role: .user, text: question, meta: meta))
            guard asked.succeeded else {
                recordProblem = "Could not record the question: " + (OutcomeLine.lastLine(of: asked.stderr) ?? "exit \(asked.exitCode)")
                return
            }
            let answered = try await runner.run(.append(role: .assistant, text: answer, meta: [:]))
            recordProblem = answered.succeeded ? nil
                : "Could not record the answer: " + (OutcomeLine.lastLine(of: answered.stderr) ?? "exit \(answered.exitCode)")
        } catch {
            recordProblem = "Could not record the turn: \(error.localizedDescription)"
        }
        await reload(force: false)
    }

    // MARK: - Notification choices

    func handle(_ choice: ChiefOfStaffNotificationChoice) {
        switch choice {
        case .doIt(let id): send(.doIt(id: id))
        case .no(let id): send(.no(id: id))
        case .open(let id): onOpen?(id)
        case .reply(let id, let text):
            let card = proposal(id)
            // "task: …" is a new task on the card's project.
            if let title = Self.taskTitle(in: text) {
                if let project = card?.project, !project.isEmpty {
                    send(.addTask(title: title, project: project, due: nil))
                } else {
                    onOpen?(nil)
                    openNewTask(title: title)
                }
                return
            }
            // The reply is about this card: `cos tell --card` gets its id.
            setSubject(card?.id)
            onReply?(text)
        }
    }

    /// The title after `task:`, or nil when the reply is not a task.
    static func taskTitle(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("task:") else { return nil }
        let title = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// A notification Reply as the chat message it becomes: the card it
    /// answers named first, so the model knows which one.
    static func replyMessage(_ text: String, about proposal: Proposal?) -> String {
        guard let proposal else { return text }
        return "About card \(proposal.id) (\(proposal.headline)): \(text)"
    }

    // MARK: - Render proof

    /// A fixed state for the offscreen proof: no files, no CLI.
    func override(items: [ChiefOfStaffThreadItem], status: CosStatus?, paused: Bool = false, projects: [CosProject]? = nil) {
        apply(items)
        self.status = status
        isPaused = paused
        isAvailable = true
        if let projects {
            self.projects = projects
            self.items = named(self.items)
        }
    }
}

/// The Chief of Staff keys in the pinned conversation. Pure, so every route
/// is tested without a window.
enum ChiefOfStaffKeys {
    /// Where the keyboard is, as the keys see it.
    enum Place: Sendable, Equatable {
        /// The composer, and whether its draft is empty.
        case composer(draftIsEmpty: Bool)
        /// A card (list or board).
        case card(board: Bool)
        /// A card's Edit fields.
        case editing
        /// The Later menu over a card.
        case laterMenu
        /// The Later menu's Pick date field: typing is the field's.
        case laterPicking
        /// A prepared file in Artifacts.
        case artifact
        /// A consent rung in the Charter.
        case rung
    }

    enum Action: Sendable, Equatable {
        /// Onto the first card.
        case focusCards
        /// Up (-1) or down (+1) the cards.
        case move(Int)
        /// Board: left (-1) or right (+1) a column.
        case moveColumn(Int)
        case toComposer
        case doIt
        case edit
        case later
        case no
        case bringBack
        case more
        case less
        case undo
        case discuss
        /// Artifacts: open the file; Charter: open the charter file.
        case openFile
        case removeRung
        case acceptRung
        case activityDay(Int)
        /// A learnings card: forget the first (0) or second (1) row.
        case forgetConflict(Int)
        /// ↩ or a typed character on a card: a message about it, in the
        /// composer, starting with the character.
        case reply(String?)
        /// ⇧⌘W in a branch: merge back and return to the pinned chat.
        case closeBranch
        case runEdit
        case cancelEdit
        case menuMove(Int)
        case menuPick(LaterChoice?)
        case menuClose
        // Anywhere in the pinned conversation.
        case showView(ChiefOfStaffModel.ViewMode)
        case newTask
        case toggleHealth
        case pickProject
        case doAllToday
        case toggleTasks
    }

    /// The keys in a branch: ⇧⌘W Close branch, and on a card the branch
    /// made, that card's own keys. ↑↓ leave it; nothing else of the pinned
    /// conversation's acts here.
    static func routeBranch(
        key: VirtualKey?,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        place: Place
    ) -> Action? {
        if modifiers.overlayRelevant == [.command, .shift], characters?.lowercased() == "w" {
            switch place {
            case .composer, .card: return .closeBranch
            default: break
            }
        }
        if case .composer = place { return nil }
        let action = route(key: key, characters: characters, modifiers: modifiers, place: place, hasCards: true)
        switch action {
        case .move: return .toComposer
        case .toComposer, .doIt, .edit, .later, .no, .bringBack, .more, .undo, .reply, .discuss,
             .runEdit, .cancelEdit, .menuMove, .menuPick, .menuClose:
            return action
        default:
            return nil
        }
    }

    static func route(
        key: VirtualKey?,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        place: Place,
        hasCards: Bool,
        hasRungOffer: Bool = false,
        onConflict: Bool = false
    ) -> Action? {
        let modifiers = modifiers.overlayRelevant
        let character = characters?.lowercased()
        let isArrow = key == .upArrow || key == .downArrow
        let delta = key == .upArrow ? -1 : 1

        if place == .laterPicking {
            if key?.isReturn == true, modifiers.isEmpty { return .menuPick(.pickDate) }
            if key == .escape, modifiers.isEmpty { return .menuClose }
            return nil
        }
        if place == .laterMenu {
            if isArrow, modifiers.isEmpty { return .menuMove(delta) }
            if key?.isReturn == true, modifiers.isEmpty { return .menuPick(nil) }
            if key == .escape, modifiers.isEmpty { return .menuClose }
            if modifiers.isEmpty, let character, let digit = Int(character),
               let choice = LaterChoice(rawValue: digit - 1) { return .menuPick(choice) }
            return nil
        }
        if place == .editing {
            if key?.isReturn == true, modifiers == [.command] { return .runEdit }
            if key == .escape, modifiers.isEmpty { return .cancelEdit }
            return nil
        }

        // The pinned conversation's own keys, from the composer or a card.
        // ⌥⌘1 to ⌥⌘5: ⌘1 to ⌘9 stay the rail's, in this chat as in any.
        if modifiers == [.command, .option] {
            if let character, let number = Int(character), let view = ChiefOfStaffModel.ViewMode(rawValue: number) {
                return .showView(view)
            }
            if character == "[" { return .activityDay(-1) }
            if character == "]" { return .activityDay(1) }
        }
        if modifiers == [.command] {
            switch character {
            case "n": return .newTask
            case "i": return .toggleHealth
            case "y" where hasRungOffer: return .acceptRung
            default: break
            }
        }
        if modifiers == [.command, .shift] {
            if character == "p" { return .pickProject }
            if character == "t" { return .toggleTasks }
            if key?.isReturn == true { return .doAllToday }
        }

        switch place {
        case .composer(let draftIsEmpty):
            guard hasCards, key == .upArrow else { return nil }
            // ⌥↑ from anywhere in the draft; a bare ↑ only on an empty one,
            // so a draft keeps its own caret keys.
            if modifiers == [.option] || (modifiers.isEmpty && draftIsEmpty) { return .focusCards }
            return nil
        case .artifact, .rung:
            if isArrow, modifiers.isEmpty || modifiers == [.option] { return .move(delta) }
            if key == .escape, modifiers.isEmpty { return .toComposer }
            if place == .artifact {
                if key?.isReturn == true, modifiers.isEmpty { return .openFile }
                if modifiers == [.command], character == "o" { return .openFile }
                if modifiers == [.command], character == "d" { return .discuss }
            } else {
                if key == .delete, modifiers == [.command] { return .removeRung }
                if modifiers == [.command], character == "o" { return .openFile }
            }
            return nil
        case .card(let board):
            if isArrow, modifiers.isEmpty || modifiers == [.option] { return .move(delta) }
            // A learnings card: 1 or 2 forgets that row.
            if onConflict, modifiers.isEmpty, let character, let number = Int(character), (1...2).contains(number) {
                return .forgetConflict(number - 1)
            }
            if board, key == .leftArrow || key == .rightArrow, modifiers.isEmpty {
                return .moveColumn(key == .leftArrow ? -1 : 1)
            }
            if key == .escape, modifiers.isEmpty { return .toComposer }
            if key?.isReturn == true, modifiers == [.command] { return .doIt }
            if key == .delete, modifiers == [.command] { return .no }
            // A bare ↩ never decides a card: it starts a message about it,
            // as typing does.
            if key?.isReturn == true, modifiers.isEmpty { return .reply(nil) }
            if modifiers.isEmpty || modifiers == [.shift], let typed = characters, typed.count == 1,
               let scalar = typed.unicodeScalars.first,
               !CharacterSet.whitespacesAndNewlines.contains(scalar), !CharacterSet.controlCharacters.contains(scalar),
               // Arrows and the other function keys arrive as private-use characters.
               !(0xF700...0xF8FF).contains(scalar.value) {
                return .reply(typed)
            }
            if modifiers == [.command] {
                switch character {
                case "e": return .edit
                case "l": return .later
                case "r": return .bringBack
                case "=", "+": return .more
                case "-": return .less
                case "z": return .undo
                case "d": return .discuss
                default: return nil
                }
            }
            return nil
        case .editing, .laterMenu, .laterPicking:
            return nil
        }
    }
}
