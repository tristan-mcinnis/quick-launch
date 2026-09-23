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
        case recordTurn(question: String, answer: String, attachmentNames: [String])
        case refresh
    }

    /// ⌘1 List (the tiers) or ⌘2 Board (columns).
    enum ViewMode: Sendable, Equatable {
        case list
        case board
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
    /// The card the keyboard is on, or nil (the composer has it).
    var focusedCardID: String?
    /// Bumped to move the keyboard into the focused card's first field.
    private(set) var editFocusRequest = 0
    /// Why the last turn could not be recorded in the thread.
    private(set) var recordProblem: String?
    /// One short line after an action that leaves no card to show it on.
    private(set) var notice: String?

    var viewMode: ViewMode = .list {
        didSet { if viewMode != oldValue { refocus() } }
    }
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
    /// TODAY: quick one-tap actions.
    var today: [Proposal] { pending(.today) }
    /// WAITING ON OTHERS.
    var waitingOnOthers: [Proposal] { pending(.waiting) }
    var fyi: [Proposal] { pending(.fyi) }

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
        items = newItems
        // Every card has its state before a view reads it, so a render
        // never writes the model.
        for proposal in newItems.compactMap(\.proposal) where cards[proposal.id] == nil {
            cards[proposal.id] = ProposalCardState()
        }
        refocus()
    }

    /// A focused card that left the view hands the focus on.
    private func refocus() {
        guard let focusedCardID, !focusOrder.contains(focusedCardID) else { return }
        self.focusedCardID = focusOrder.first
    }

    // MARK: - The pinned chat

    /// The system message for a request in chat `id`: the Chief of Staff
    /// instruction, the waiting cards and the last twelve proposals. Nil
    /// for any other chat.
    func systemMessage(forChat id: UUID) -> String? {
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
    }

    // MARK: - Card actions

    /// ⌘↩ on a card: Do it (Got it on a card with nothing to run), or Run
    /// while editing.
    func doFocused() {
        guard let proposal = focusedProposal, proposal.isWaiting else { return }
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
        let ids = today.filter { !(cards[$0.id]?.isRunning ?? false) }.map(\.id)
        guard !ids.isEmpty else { return }
        if let armed = bulkArmed, armed == ids {
            bulkArmed = nil
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
        case .recordTurn(let question, let answer, let names):
            await record(question: question, answer: answer, attachmentNames: names)
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
            case .later, .reopen:
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
        await reload(force: true)
        // The card left the view: the keyboard moves to its neighbour.
        if focusedCardID == nil || !focusOrder.contains(focusedCardID ?? ""), let index = order.firstIndex(of: id) {
            let rest = focusOrder
            focusedCardID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)]
        }
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
            onReply?(Self.replyMessage(text, about: card))
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
        if let projects { self.projects = projects }
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
        case runEdit
        case cancelEdit
        case menuMove(Int)
        case menuPick(LaterChoice?)
        case menuClose
        // Anywhere in the pinned conversation.
        case showList
        case showBoard
        case newTask
        case toggleHealth
        case pickProject
        case doAllToday
        case toggleTasks
    }

    static func route(
        key: VirtualKey?,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        place: Place,
        hasCards: Bool
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
        if modifiers == [.command] {
            switch character {
            case "1": return .showList
            case "2": return .showBoard
            case "n": return .newTask
            case "i": return .toggleHealth
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
        case .card(let board):
            if isArrow, modifiers.isEmpty || modifiers == [.option] { return .move(delta) }
            if board, key == .leftArrow || key == .rightArrow, modifiers.isEmpty {
                return .moveColumn(key == .leftArrow ? -1 : 1)
            }
            if key == .escape, modifiers.isEmpty { return .toComposer }
            if key?.isReturn == true, modifiers == [.command] { return .doIt }
            if key == .delete, modifiers == [.command] { return .no }
            if modifiers == [.command] {
                switch character {
                case "e": return .edit
                case "l": return .later
                case "r": return .bringBack
                default: return nil
                }
            }
            return nil
        case .editing, .laterMenu, .laterPicking:
            return nil
        }
    }
}
