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

/// The Chief of Staff inside Quick Launch: the `cos` thread as read, the
/// waiting cards, each card's session state, the keyboard's card focus, and
/// the notices. It reads files through `CosFiles` and acts only through the
/// `cos` CLI, so nothing here writes the thread or blocks the main actor.
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

    static let pollInterval: Duration = .seconds(2)
    static let aliveInterval: Duration = .seconds(30)

    enum Command: Sendable, Equatable {
        case doIt(id: String)
        case runEdit(id: String)
        case skip(id: String)
        case recordTurn(question: String, answer: String, attachmentNames: [String])
        case refresh
    }

    // MARK: - State

    /// The thread's turns, in order.
    private(set) var items: [ChiefOfStaffThreadItem] = [] {
        didSet {
            waiting = ChiefOfStaffThread.waiting(in: items)
            history = ChiefOfStaffThread.history(in: items)
        }
    }
    /// Waiting cards, newest first.
    private(set) var waiting: [Proposal] = []
    /// Decided cards and other surfaces' chat turns, in thread order.
    private(set) var history: [ChiefOfStaffThreadItem] = []
    private(set) var status: CosStatus?
    private(set) var isPaused = false
    /// Why the thread or the CLI could not be read, in one sentence.
    private(set) var problem: String?
    /// The CLI is installed. False on a Mac without it: no row, no chat.
    private(set) var isAvailable: Bool
    private(set) var cards: [String: ProposalCardState] = [:]
    /// The waiting card the keyboard is on, or nil (the composer has it).
    var focusedCardID: String?
    /// Bumped to move the keyboard into the focused card's first field.
    private(set) var editFocusRequest = 0
    /// Why the last turn could not be recorded in the thread.
    private(set) var recordProblem: String?

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
    /// Waiting ids already announced; nil until the first read, which only
    /// seeds it (those cards were announced before this launch).
    @ObservationIgnored private var announced: Set<String>?

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

    // MARK: - Reading

    var waitingCount: Int { waiting.count }

    /// "3 waiting", "Paused · 3 waiting", or "Nothing waiting".
    var summary: String {
        let count = waiting.isEmpty ? "Nothing waiting" : "\(waiting.count) waiting"
        return isPaused ? "Paused · \(count)" : count
    }

    func card(_ id: String) -> ProposalCardState {
        if let card = cards[id] { return card }
        let card = ProposalCardState()
        cards[id] = card
        return card
    }

    var focusedProposal: Proposal? {
        guard let focusedCardID else { return nil }
        return waiting.first { $0.id == focusedCardID }
    }

    /// Whether the keyboard is inside a card's Edit fields.
    var isEditingFocusedCard: Bool {
        focusedCardID.flatMap { cards[$0]?.isEditing } == true
    }

    func apply(_ newItems: [ChiefOfStaffThreadItem]) {
        items = newItems
        // Every waiting card has its state before a view reads it, so a
        // render never writes the model.
        for proposal in waiting where cards[proposal.id] == nil {
            cards[proposal.id] = ProposalCardState()
        }
        // A focused card that was decided elsewhere hands the focus on.
        if let focusedCardID, !waiting.contains(where: { $0.id == focusedCardID }) {
            self.focusedCardID = waiting.first?.id
        }
    }

    // MARK: - The pinned chat

    /// The system message for a request in chat `id`: the Chief of Staff
    /// instruction, the waiting cards and the last twelve proposals. Nil
    /// for any other chat.
    func systemMessage(forChat id: UUID) -> String? {
        guard id == Self.conversationID else { return nil }
        return ChiefOfStaffPrompt.systemMessage(
            waiting: waiting,
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

    // MARK: - Keyboard focus on the waiting cards

    /// Move the keyboard onto the waiting cards: the newest, or the one
    /// `delta` away from the focused card. Past the last card it goes back
    /// to the composer (nil). False when there is no card to move to.
    @discardableResult
    func moveCardFocus(_ delta: Int) -> Bool {
        guard !waiting.isEmpty else {
            focusedCardID = nil
            return false
        }
        guard let current = focusedCardID, let index = waiting.firstIndex(where: { $0.id == current }) else {
            focusedCardID = waiting.first?.id
            return true
        }
        let next = index + delta
        if next < 0 { return true }
        focusedCardID = next < waiting.count ? waiting[next].id : nil
        return true
    }

    func focusCard(_ id: String?) {
        focusedCardID = id.flatMap { id in waiting.contains { $0.id == id } ? id : nil } ?? waiting.first?.id
    }

    func releaseCardFocus() {
        if let focusedCardID { cards[focusedCardID]?.isEditing = false }
        focusedCardID = nil
    }

    /// ⌘↩ on a card: Do it (Got it on a notice), or Run while editing.
    func doFocused() {
        guard let proposal = focusedProposal else { return }
        if card(proposal.id).isEditing {
            send(.runEdit(id: proposal.id))
        } else {
            send(.doIt(id: proposal.id))
        }
    }

    /// ⌘E on a card: its actions become fields.
    func editFocused() {
        guard let proposal = focusedProposal, !proposal.isNotice else { return }
        beginEdit(proposal)
    }

    /// ⌘⌫ on a card: No. Nothing runs.
    func skipFocused() {
        guard let proposal = focusedProposal, !card(proposal.id).isEditing else { return }
        send(.skip(id: proposal.id))
    }

    func beginEdit(_ proposal: Proposal) {
        let card = card(proposal.id)
        guard !card.isRunning else { return }
        focusedCardID = proposal.id
        card.drafts = ActionDraft.drafts(for: proposal)
        card.isEditing = true
        editFocusRequest &+= 1
    }

    func cancelEdit(_ id: String) {
        cards[id]?.isEditing = false
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

    /// Read the thread if it moved and the pause flag, then ask the CLI for
    /// its numbers when either changed, and announce new cards.
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
        if changed { await refreshStatus() }
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

    /// The notices for cards that appeared since the last read.
    func announceNewCards() async {
        let ids = Set(waiting.map(\.id))
        guard var announced else {
            self.announced = ids
            return
        }
        // Oldest first, so the banners stack in arrival order.
        let fresh = waiting.filter { !announced.contains($0.id) }.reversed()
        announced.formUnion(ids)
        self.announced = announced
        guard let notifier else { return }
        for notice in ChiefOfStaffNotificationRules.notices(for: Array(fresh), now: clock(), quietHours: quietHours) {
            await notifier.post(notice)
        }
    }

    func perform(_ command: Command) async {
        switch command {
        case .doIt(let id):
            await verdict(id) { .doIt(id: id) }
        case .runEdit(let id):
            guard let card = cards[id], card.isEditing else { return }
            let actions = card.drafts.map(\.action)
            await verdict(id) { .edit(id: id, actions: actions) }
        case .skip(let id):
            await verdict(id) { .skip(id: id, reason: nil) }
        case .recordTurn(let question, let answer, let names):
            await record(question: question, answer: answer, attachmentNames: names)
        case .refresh:
            await reload(force: true)
        }
    }

    /// Do it, Edit's Run, or Skip: one `cos` call, its lines on the card,
    /// then a fresh read so the thread and the counts move with it.
    private func verdict(_ id: String, _ command: () -> CosCommand) async {
        guard let runner else { return }
        let card = card(id)
        guard !card.isRunning else { return }
        card.isRunning = true
        card.outcome = nil
        let call = command()
        do {
            let result = try await runner.run(call)
            if case .skip = call {
                card.outcome = result.succeeded ? [OutcomeLine(ok: true, text: "Recorded as no.")] : OutcomeLine.lines(from: result)
            } else {
                card.outcome = OutcomeLine.lines(from: result)
            }
            if result.succeeded || card.outcome?.contains(where: \.ok) == true { card.isEditing = false }
        } catch {
            card.outcome = [OutcomeLine(ok: false, text: "cos did not finish: \(error.localizedDescription)")]
        }
        card.isRunning = false
        // The decided card leaves the waiting list; the keyboard moves on.
        if focusedCardID == id, card.outcome?.contains(where: \.ok) == true {
            let index = waiting.firstIndex { $0.id == id } ?? 0
            let rest = waiting.filter { $0.id != id }
            focusedCardID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
        }
        await reload(force: true)
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
        case .skip(let id): send(.skip(id: id))
        case .open(let id): onOpen?(id)
        case .reply(let id, let text):
            let card = id.flatMap { id in items.compactMap(\.proposal).first { $0.id == id } }
            onReply?(Self.replyMessage(text, about: card))
        }
    }

    /// A notification Reply as the chat message it becomes: the card it
    /// answers named first, so the model knows which one.
    static func replyMessage(_ text: String, about proposal: Proposal?) -> String {
        guard let proposal else { return text }
        return "About card \(proposal.id) (\(proposal.headline)): \(text)"
    }

    // MARK: - Render proof

    /// A fixed state for the offscreen proof: no files, no CLI.
    func override(items: [ChiefOfStaffThreadItem], status: CosStatus?, paused: Bool = false) {
        apply(items)
        self.status = status
        isPaused = paused
        isAvailable = true
    }
}

/// The Chief of Staff keys in the pinned conversation. Pure, so every route
/// is tested without a window.
enum ChiefOfStaffKeys {
    /// Where the keyboard is, as the keys see it.
    enum Place: Sendable, Equatable {
        /// The composer, and whether its draft is empty.
        case composer(draftIsEmpty: Bool)
        /// A waiting card.
        case card
        /// A card's Edit fields.
        case editing
    }

    enum Action: Sendable, Equatable {
        /// Onto the newest waiting card.
        case focusCards
        /// Up (-1) or down (+1) the waiting cards.
        case move(Int)
        case toComposer
        case doIt
        case edit
        case skip
        case runEdit
        case cancelEdit
    }

    static func route(
        key: VirtualKey?,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        place: Place,
        hasWaiting: Bool
    ) -> Action? {
        let modifiers = modifiers.overlayRelevant
        let isArrow = key == .upArrow || key == .downArrow
        let delta = key == .upArrow ? -1 : 1
        switch place {
        case .composer(let draftIsEmpty):
            guard hasWaiting, isArrow else { return nil }
            // ⌥↑ from anywhere in the draft; a bare ↑ only on an empty one,
            // so a draft keeps its own caret keys.
            if key == .upArrow, modifiers == [.option] || (modifiers.isEmpty && draftIsEmpty) {
                return .focusCards
            }
            return nil
        case .card:
            if isArrow, modifiers.isEmpty || modifiers == [.option] { return .move(delta) }
            if key == .escape, modifiers.isEmpty { return .toComposer }
            if key?.isReturn == true, modifiers == [.command] { return .doIt }
            if key == .delete, modifiers == [.command] { return .skip }
            if modifiers == [.command], characters?.lowercased() == "e" { return .edit }
            return nil
        case .editing:
            if key?.isReturn == true, modifiers == [.command] { return .runEdit }
            if key == .escape, modifiers.isEmpty { return .cancelEdit }
            return nil
        }
    }
}
