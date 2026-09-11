import AppKit
import SwiftUI

/// Quick AI, after Raycast's: a `panelWidth` × `quickAIHeight` surface
/// that replaces the launcher in place. The user can drag the window larger
/// (the size is remembered, `QuickAISize`); the header and composer span
/// the window, and the thread stays one centred column as wide as the
/// standard surface's, so lines stay readable. A header (back chevron,
/// conversation title over the model, expand glyph), the scrolling thread
/// (user turns as pills on the right, answers as prose on the left, one
/// tool or status line, the question card when the model asks), and the
/// composer row along the bottom edge: the Add Context circle, the pill
/// field with the primary action inside it, and the `⌘K` circle. There is
/// no footer well; the composer row is the footer.
///
/// Every chooser that floats over the launcher floats here too, anchored
/// above the composer. The field keeps focus the whole time the surface is
/// open, streaming included.
struct QuickAIView: View {
    @Bindable var viewModel: QuickViewModel
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the thread is scrolled. Every scroll the thread makes goes
    /// through it: to a message's head, to an edge, or by a page.
    @State private var threadPosition = ScrollPosition()
    /// The thread's last reported geometry, for a page's size and bounds.
    @State private var threadGeometry = ThreadGeometry()
    /// Whether the thread is still, tracked by the reader, or animating a
    /// scroll it was asked for.
    @State private var scrollPhase = ScrollPhase.idle

    /// The composer row from the panel's bottom edge: the pill-high row plus
    /// its inset above and below. The floating `⌘K` pane and the choosers
    /// sit on top of it.
    static let composerRowHeight = House.Control.pill + House.Spacing.xs * 2

    /// The header row. Raycast's is 60 tall; the nearest house control
    /// height is the input row.
    static let headerHeight = House.Control.input

    /// The thread's column: the width it has on the standard 750-wide
    /// surface, inside the `Spacing.lg` gutters. A window dragged wider
    /// centres this column instead of stretching it, so answer lines stay
    /// at `quickAIAnswerMaxWidth` and user pills end at the column's right
    /// edge, exactly as at 750.
    static let threadColumnWidth = PanelSizing.panelWidth - House.Spacing.lg * 2

    private static let threadErrorID = "quick-ai-thread-error"
    private static let liveAnswerID = "quick-ai-live-answer"
    private static let detachedQuestionID = "quick-ai-detached-question"
    private static let detachedAnswerID = "quick-ai-detached-answer"
    private static let liveQuestionID = "quick-ai-live-question"
    private static let statusLineID = "quick-ai-status"
    private static let webSearchNoteID = "quick-ai-web-search"
    private static let threadNoticeID = "quick-ai-thread-notice"

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if viewModel.isRecentChatsPresented {
                    RecentChatsList(viewModel: viewModel)
                } else {
                    thread
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = viewModel.errorMessage {
                errorLine(error)
            }
            // The strips read as rows; the surface has no hairlines.
            if viewModel.launchSelection != nil {
                LaunchSelectionStrip(viewModel: viewModel)
            }
            if viewModel.hasPendingAttachment {
                AttachmentStrip(viewModel: viewModel)
            }
            composer
        }
        // Fills the window: 750 × 475 at the least, as large as the user
        // drags it. A fixed frame would pin the hosting view's size and
        // stop the drag.
        .frame(
            minWidth: PanelSizing.panelWidth,
            maxWidth: .infinity,
            minHeight: PanelSizing.quickAIHeight,
            maxHeight: .infinity
        )
        .overlay(alignment: .bottom) { floatingChooser }
        .onAppear { focusComposer() }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in focusComposer() }
        .onChange(of: viewModel.threadError) { _, error in
            guard let error else { return }
            announce("Error. \(error.message)", priority: .high)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick AI")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: House.Spacing.sm) {
            // The chevron is the quiet one: secondary ink, a step smaller
            // than the expand glyph, as in Raycast.
            glyphButton(
                "chevron.left",
                font: AQDesign.TypeToken.glyphSmall,
                color: AQDesign.ColorToken.textSecondary,
                label: "Back to search",
                help: "Back to search, keeping this chat (esc)"
            ) {
                viewModel.closeQuickAI()
            }
            VStack(alignment: .leading, spacing: House.Spacing.xxs) {
                Text(viewModel.quickAITitle)
                    .font(AQDesign.TypeToken.subheading)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let source = viewModel.answerSourceTitle {
                    // A command's output or a Vault Search is not the
                    // model's: the line names where the answer came from.
                    Text(source)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("Source: \(source)")
                } else {
                HStack(spacing: House.Spacing.xxs) {
                    // An assistant chat names its assistant ahead of the
                    // model, in full ink: the name opens Change Assistant.
                    if let assistant = viewModel.activeAssistant {
                        assistantName(assistant.name)
                        Text("·")
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .accessibilityHidden(true)
                    }
                    // The model line is a button: it opens the model chooser
                    // to change the model for the next message.
                    Button {
                        viewModel.toggleModelChooserFromHeader()
                    } label: {
                        Text(viewModel.activeModelDisplay)
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Model: \(viewModel.activeModelDisplay)")
                    .accessibilityHint("Change the model")
                    .accessibilityValue(viewModel.isModelChooserPresented ? "Open" : "Closed")
                    .help("Change model (\(ResultAction.changeModel.shortcut.keyCaps.joined()))")
                    }
                }
            }
            Spacer(minLength: House.Spacing.sm)
            // Raycast's expand glyph is a boxed up-right arrow; this is the
            // nearest SF Symbol.
            glyphButton(
                "arrow.up.right.square",
                font: AQDesign.TypeToken.glyphMedium,
                color: AQDesign.ColorToken.textPrimary,
                label: "Recent Chats",
                help: "Recent Chats (⌘J)"
            ) {
                viewModel.toggleRecentChats()
            }
            .accessibilityValue(viewModel.isRecentChatsPresented ? "Open" : "Closed")
        }
        // A tighter left inset than right: with the compact button and the
        // row gap, the title starts where Raycast's does.
        .padding(.leading, House.Spacing.sm)
        .padding(.trailing, House.Spacing.lg)
        .frame(height: Self.headerHeight)
    }

    /// The assistant's name on the model line: a button for Change
    /// Assistant, never truncated ahead of the model.
    private func assistantName(_ name: String) -> some View {
        Button {
            viewModel.toggleAssistantChooser()
        } label: {
            Text(name)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Assistant: \(name)")
        .accessibilityHint("Change the assistant")
        .accessibilityValue(viewModel.isAssistantChooserPresented ? "Open" : "Closed")
        .help("Change assistant (\(ResultAction.changeAssistant.shortcut.keyCaps.joined()))")
    }

    private func glyphButton(
        _ symbol: String,
        font: Font,
        color: Color,
        label: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(font)
                .foregroundStyle(color)
                .frame(width: House.Control.compact, height: House.Control.compact)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(help)
    }

    // MARK: - Thread

    private var lastUserMessageID: UUID? {
        viewModel.conversationMessages.last { $0.role == .user }?.id
    }

    /// The question that is not yet a turn of the thread, drawn as its own
    /// pill: the one being asked while the web search runs (the user
    /// message joins the thread only when the model is called), the one a
    /// detached answer (a local answer, a Vault Search) belongs to, and any
    /// question with no chat behind it.
    private var pendingQuestion: String? {
        if let question = viewModel.pendingQuestion, !question.isEmpty,
           viewModel.isStreaming || viewModel.quickAIDetachedAnswer != nil {
            return question
        }
        // An answer with no chat behind it (a Vault Search, for one).
        if viewModel.currentConversation == nil,
           let question = viewModel.lastQuestion, !question.isEmpty {
            return question
        }
        return nil
    }

    /// The empty surface: three quiet lines naming the ways in, centred in
    /// the space the thread will take.
    private func emptyStateHints(_ hints: [String]) -> some View {
        VStack(spacing: House.Spacing.xs) {
            ForEach(hints, id: \.self) { hint in
                Text(hint)
                    .font(AQDesign.TypeToken.body)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var thread: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: House.Spacing.md) {
                let pendingQuestion = pendingQuestion
                ForEach(viewModel.conversationMessages) { message in
                    turn(message)
                        .id(message.id)
                    // The search line belongs to the newest question;
                    // while that question is still pending it hangs
                    // under the pending pill instead.
                    // The search line and the lines of the calls still
                    // streaming belong to the newest question; while that
                    // question is pending they hang under its pill instead.
                    // A finished answer draws its own lines.
                    if pendingQuestion == nil, message.id == lastUserMessageID {
                        liveToolLines
                    }
                    // A provider error stays with the question it failed,
                    // in the tool line's place, with Retry.
                    if let error = viewModel.threadError, error.messageID == message.id {
                        threadErrorLine(error.message)
                            .id(Self.threadErrorID)
                    }
                }
                // A question that is not a thread turn (the one being
                // searched for, the one a command's output or a Vault Search
                // belongs to, one with no chat behind it) still reads as a
                // turn: an answer never draws without its question.
                if let question = pendingQuestion {
                    userPill(MessageCollapseState(text: question, collapses: false), toggle: nil)
                        .id(Self.detachedQuestionID)
                    liveToolLines
                }
                // The model paused to ask. The live card sits where the
                // answer will; once picked it joins the thread as the
                // record and the answer continues under it.
                if let ask = viewModel.pendingAskQuestion, !ask.isAnswered {
                    AskUserQuestionCard(
                        question: ask,
                        selectedIndex: viewModel.askQuestionSelectionIndex,
                        isInteractive: true,
                        onMove: { viewModel.moveAskQuestionSelection($0) },
                        onPick: { viewModel.answerAskQuestion(index: $0) }
                    )
                    .id(Self.liveQuestionID)
                }
                // While the search itself runs its note is the status,
                // already drawn above; the dots take over once the model is
                // thinking.
                if viewModel.isStreaming,
                   viewModel.output.isEmpty,
                   !viewModel.isAskQuestionActive,
                   viewModel.streamingStatus == nil || viewModel.streamingStatus != viewModel.webSearchNote {
                    statusLine
                        .id(Self.statusLineID)
                }
                if viewModel.isStreaming, !viewModel.output.isEmpty {
                    answerProse(viewModel.output, isStreaming: true, instanceID: "live-answer")
                        .id(Self.liveAnswerID)
                }
                // A finished answer that is not the thread's last turn (a
                // command's output, a Vault Search, a failed stream's
                // partial text) draws after the thread, whether or not a
                // chat is kept.
                if let answer = viewModel.quickAIDetachedAnswer {
                    answerProse(answer, isStreaming: false, instanceID: "answer")
                        .id(Self.detachedAnswerID)
                }
                // Where the thread went after Continue in pi.
                if let notice = viewModel.threadNotice {
                    toolLine(notice, symbol: "terminal")
                        .id(Self.threadNoticeID)
                }
            }
            .frame(maxWidth: Self.threadColumnWidth)
            .padding(.top, House.Spacing.xl)
            .padding(.horizontal, House.Spacing.lg)
            .padding(.bottom, House.Spacing.md)
            // Centred in a window wider than the standard surface.
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($threadPosition)
        .onScrollGeometryChange(for: ThreadGeometry.self) { geometry in
            ThreadGeometry(
                top: geometry.visibleRect.minY,
                visibleHeight: geometry.visibleRect.height,
                contentHeight: geometry.contentSize.height
            )
        } action: { old, new in
            threadGeometry = new
            // Only a move of the view (the reader's scroll, or one the
            // thread made) decides whether it follows the bottom; text
            // landing under a still view does not. A scroll the thread
            // animates is judged where it lands, not on its first frame.
            viewModel.threadDidScroll(
                distanceFromBottom: new.distanceFromBottom,
                moved: old.top != new.top && scrollPhase != .animating
            )
        }
        .onScrollPhaseChange { previous, phase in
            scrollPhase = phase
            // A scroll that just came to rest (the reader's, or an animated
            // one the thread made) is judged where it landed.
            if phase == .idle, previous != .idle {
                viewModel.threadDidScroll(distanceFromBottom: threadGeometry.distanceFromBottom)
            }
        }
        .overlay {
            let hints = viewModel.quickAIEmptyStateHints
            if !hints.isEmpty { emptyStateHints(hints) }
        }
        .overlay(alignment: .bottom) {
            if viewModel.showsJumpToLatest { latestChip }
        }
        .onAppear { followBottom() }
        .onChange(of: viewModel.conversationMessages.count) { _, _ in followBottom() }
        .onChange(of: viewModel.output) { _, _ in followBottom() }
        .onChange(of: viewModel.isStreaming) { _, _ in followBottom() }
        .onChange(of: viewModel.streamingStatus) { _, _ in followBottom() }
        .onChange(of: viewModel.threadError) { _, _ in followBottom() }
        .onChange(of: viewModel.pendingAskQuestion?.isAnswered) { _, _ in followBottom() }
        .onChange(of: viewModel.liveToolRecords.count) { _, _ in followBottom() }
        .onChange(of: viewModel.threadNotice) { _, notice in
            followBottom()
            guard let notice else { return }
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: notice,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
        // A new question (or another chat) follows the bottom again.
        .onChange(of: viewModel.isThreadFollowingBottom) { _, follows in
            if follows { scrollToEnd() }
        }
        // Show more and Collapse, the page keys, ⌘↑ ⌘↓, and the chip.
        .onChange(of: viewModel.threadScrollRequest) { _, request in
            guard let request else { return }
            scroll(to: request.target)
        }
        .accessibilityLabel("Conversation with \(viewModel.activeModelDisplay)")
    }

    /// What the thread's scroll view reports: where its view is, how tall
    /// the view is, and how tall the content.
    struct ThreadGeometry: Equatable {
        var top: CGFloat = 0
        var visibleHeight: CGFloat = 0
        var contentHeight: CGFloat = 0

        var distanceFromBottom: CGFloat { contentHeight - (top + visibleHeight) }
        /// The furthest down the view can go.
        var maximumTop: CGFloat { max(0, contentHeight - visibleHeight) }
        /// One page: the view's height less a line of overlap to keep place.
        var page: CGFloat { max(visibleHeight - House.Spacing.xxxl, House.Spacing.xxxl) }
    }

    /// "↓ Latest": the reader scrolled up from newer text. Clicking it, or
    /// `⌘↓`, goes back to the bottom and follows it again.
    private var latestChip: some View {
        Button {
            viewModel.scrollThread(.bottom)
        } label: {
            HouseChip(text: "Latest", icon: "arrow.down")
                .raisedCard(radius: AQDesign.fieldCornerRadius, fill: AQDesign.ColorToken.raisedSurface)
                .houseShadow(AQDesign.Shadow.card)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, House.Spacing.xs)
        .accessibilityLabel("Jump to latest")
        .help("Jump to latest (\(Self.jumpToLatestKeys.joined()))")
    }

    /// The key the chip names: ⌘↓.
    static let jumpToLatestKeys = ["⌘", "↓"]

    @ViewBuilder
    private func turn(_ message: QuickMessage) -> some View {
        switch message.role {
        case .user:
            userPill(
                viewModel.collapseState(for: message),
                showsShortcut: viewModel.showsCollapseShortcut(for: message)
            ) {
                viewModel.toggleTranscriptMessage(message.id)
            }
        case .system:
            // Never a saved turn; nothing to draw if one ever arrives.
            EmptyView()
        case .assistant:
            if let question = message.askUserQuestion {
                // The record of a question the model asked and the option
                // the user picked.
                AskUserQuestionCard(question: question, isInteractive: false)
            } else {
                answerTurn(message)
            }
        }
    }

    /// An answer with what its tools left: the tool lines above the prose,
    /// the sources under it, and a Capture to Memory checkmark last. Saved
    /// with the chat, so a reopened chat draws the same lines.
    private func answerTurn(_ message: QuickMessage) -> some View {
        let records = message.tools
        let sources = message.sources
        let above = records.filter(\.drawsAboveAnswer)
        return VStack(alignment: .leading, spacing: House.Spacing.md) {
            if !above.isEmpty {
                toolLineGroup(above.map { ($0.summary, $0.systemImage) })
            }
            // Answers never collapse: Raycast folds only what you send.
            answerProse(
                message.content,
                isStreaming: false,
                instanceID: "message-\(message.id.uuidString)"
            )
            if !sources.isEmpty {
                sourceList(sources)
            }
            ForEach(Array(records.filter { !$0.drawsAboveAnswer }.enumerated()), id: \.offset) { _, record in
                toolLine(record.summary, symbol: record.systemImage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The lines of the ask in flight: an explicit web search, then each
    /// tool call as it finishes. Grouped as a finished answer groups them,
    /// so nothing moves when the answer lands.
    @ViewBuilder
    private var liveToolLines: some View {
        let lines = (viewModel.webSearchNote.map { [($0, "globe")] } ?? [])
            + viewModel.liveToolRecords.map { ($0.summary, $0.systemImage) }
        if !lines.isEmpty {
            toolLineGroup(lines)
                .id(Self.webSearchNoteID)
        }
    }

    /// Consecutive tool lines, closer together than the turns around them.
    private func toolLineGroup(_ lines: [(text: String, symbol: String)]) -> some View {
        VStack(alignment: .leading, spacing: House.Spacing.xs) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                toolLine(line.text, symbol: line.symbol)
            }
        }
    }

    /// Sources listed under an answer before the rest are left to `⌘K` ›
    /// Open Source.
    static let listedSourceLimit = 5

    /// The answer's sources: a quiet list under the prose, one row each
    /// (the title or file, then its day). A row with a local file opens it
    /// on click, as `⌘K` › Open Source (`⌘O`) does.
    private func sourceList(_ sources: [ChatSource]) -> some View {
        VStack(alignment: .leading, spacing: House.Spacing.xxs) {
            ForEach(sources.prefix(Self.listedSourceLimit)) { source in
                sourceRow(source)
            }
            if sources.count > Self.listedSourceLimit {
                Text("\(sources.count - Self.listedSourceLimit) more in ⌘K › Open Source")
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .padding(.leading, House.Control.keyCap + House.Spacing.xs)
            }
        }
        .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sources")
    }

    @ViewBuilder
    private func sourceRow(_ source: ChatSource) -> some View {
        let label = HStack(spacing: House.Spacing.xs) {
            // The tool lines' glyph column, so every line's text starts at
            // one edge.
            Image(systemName: "doc.text")
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .frame(width: House.Control.keyCap)
            Text(source.title)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let day = source.day {
                Text(day)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(minHeight: House.Control.keyCap)
        .contentShape(Rectangle())
        if let path = source.path, viewModel.fileOpener != nil {
            Button {
                viewModel.requestOpenSource(source)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .help("Open \(path)")
            .accessibilityLabel("Source: \(source.title)\(source.day.map { ", \($0)" } ?? "")")
            .accessibilityHint("Opens the file")
        } else {
            label
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Source: \(source.title)\(source.day.map { ", \($0)" } ?? "")")
        }
    }

    /// A user turn: a pill on the right in secondary ink one step below
    /// the answer prose, wrapping left-aligned inside it. No "You" label.
    private func userPill(
        _ state: MessageCollapseState,
        showsShortcut: Bool = false,
        toggle: (() -> Void)?
    ) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            CollapsibleMessageText(
                state: state,
                showsShortcut: showsShortcut,
                plainTextFont: AQDesign.TypeToken.body,
                fillsWidth: false
            ) {
                toggle?()
            }
            .foregroundStyle(AQDesign.ColorToken.textSecondary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, House.Spacing.sm)
            .padding(.vertical, House.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
                    .fill(AQDesign.ColorToken.chipFill)
            )
            .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(state.text)")
    }

    private func answerProse(_ markdown: String, isStreaming: Bool, instanceID: String) -> some View {
        MarkdownTextView(
            markdown: markdown,
            isStreaming: isStreaming,
            scrolls: false,
            instanceID: instanceID
        )
        .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .leading)
    }

    /// The model is working and nothing has landed yet: the breathing dots,
    /// or the globe when the status is a web search, and the status text.
    /// A memory, vault, or skill call keeps the dots while it runs; its
    /// line, with its own glyph, lands when it finishes.
    private var statusLine: some View {
        let status = viewModel.streamingStatus ?? "Thinking…"
        let isWebSearch = status.hasPrefix("Search web") || status.hasPrefix("Searching the web")
        return toolLine(status, symbol: isWebSearch ? "globe" : nil)
    }

    /// One quiet line: a glyph (or the thinking dots) and tertiary text.
    /// The glyph sits in a fixed column, so the text of consecutive lines
    /// starts at one edge whatever the symbol's width.
    private func toolLine(_ text: String, symbol: String?) -> some View {
        HStack(spacing: House.Spacing.xs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(AQDesign.TypeToken.body)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .frame(width: House.Control.keyCap)
            } else {
                ThinkingIndicator()
            }
            Text(text)
                .font(AQDesign.TypeToken.body)
                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minHeight: House.Control.keyCap)
        .accessibilityElement(children: .combine)
    }

    private func scrollToEnd() {
        threadPosition.scrollTo(edge: .bottom)
    }

    /// New text keeps the newest line in view only while the reader is at
    /// the bottom; scrolled up, the view stays where they are.
    private func followBottom() {
        guard viewModel.isThreadFollowingBottom else { return }
        scrollToEnd()
    }

    private func scroll(to target: QuickViewModel.ThreadScrollRequest.Target) {
        let geometry = threadGeometry
        let move = {
            switch target {
            case .messageTop(let id): threadPosition.scrollTo(id: id, anchor: .top)
            case .top: threadPosition.scrollTo(edge: .top)
            case .bottom: threadPosition.scrollTo(edge: .bottom)
            case .pageUp: threadPosition.scrollTo(y: max(0, geometry.top - geometry.page))
            case .pageDown: threadPosition.scrollTo(y: min(geometry.maximumTop, geometry.top + geometry.page))
            }
        }
        if reduceMotion {
            move()
        } else {
            withAnimation(.easeOut(duration: AQDesign.Motion.select)) { move() }
        }
    }

    // MARK: - Thread error

    /// A provider error under the question it failed, in the tool line's
    /// style: the warning glyph and the message in danger ink, then Retry
    /// with its key.
    private func threadErrorLine(_ message: String) -> some View {
        HStack(spacing: House.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle")
                .font(AQDesign.TypeToken.body)
                .foregroundStyle(AQDesign.ColorToken.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(AQDesign.TypeToken.body)
                .foregroundStyle(AQDesign.ColorToken.danger)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: House.Spacing.xs)
            Button {
                viewModel.retryFailedTurn()
            } label: {
                KeyHint(label: "Retry", keys: ResultAction.regenerate.shortcut.keyCaps)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry")
            .help("Ask this question again (\(ResultAction.regenerate.shortcut.keyCaps.joined()))")
        }
        .frame(minHeight: House.Control.keyCap)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error: \(message)")
    }

    // MARK: - Error

    private func errorLine(_ error: String) -> some View {
        HStack(spacing: AQDesign.Space.standard) {
            Text(error)
                .font(AQDesign.TypeToken.detail)
                .foregroundStyle(AQDesign.ColorToken.danger)
                .lineLimit(2)
            Spacer()
            if viewModel.needsAccessibilityPermission {
                Button("Open System Settings") {
                    viewModel.openAccessibilitySettings()
                }
                .buttonStyle(InkButtonStyle())
            }
        }
        .padding(.horizontal, House.Spacing.lg)
        .padding(.vertical, House.Spacing.xs)
    }

    // MARK: - Composer

    private var composer: some View {
        let action = viewModel.quickAIComposerAction
        return HStack(spacing: House.Spacing.xs) {
            Button {
                viewModel.toggleAddContextMenu()
            } label: {
                Image(systemName: "plus")
                    .font(AQDesign.TypeToken.glyphMedium)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .frame(width: House.Control.pill, height: House.Control.pill)
                    .background(Circle().fill(AQDesign.ColorToken.surfaceFill))
                    .overlay(
                        Circle().strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: AQDesign.hairline)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add Context")
            .accessibilityValue(viewModel.isAddContextMenuPresented ? "Open" : "Closed")
            .help("Add context: a window, a selection, an area, or a screen (or type @)")

            HStack(spacing: House.Spacing.xs) {
                // The placeholder is drawn as an overlay, not as the field's
                // prompt: a styled prompt takes the field's ink on macOS and
                // read as typed text. The empty prompt keeps the field from
                // drawing its label as a placeholder under the overlay.
                TextField(text: $viewModel.input, prompt: Text("")) {
                    Text("Ask Quick AI")
                }
                .textFieldStyle(.plain)
                .labelsHidden()
                // Raycast's field runs at the small reading size, the same
                // as its action label, not the launcher's 16.
                .font(AQDesign.TypeToken.body)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if viewModel.input.isEmpty {
                        Text(viewModel.quickAIComposerPlaceholder)
                            .font(AQDesign.TypeToken.body)
                            .foregroundStyle(AQDesign.ColorToken.textTertiary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit { viewModel.submitFromComposer() }
                .modifier(ComposerKeyRouting(viewModel: viewModel))
                // Tab has nothing to move to on this surface: an alias
                // completes through the routing above, and otherwise the key
                // stays in the field instead of walking focus away.
                .onKeyPress(.tab) { .handled }
                .onChange(of: viewModel.input) { _, newValue in
                    // Recent Chats filters on it; elsewhere a typed `@`
                    // opens the same Add Context menu the circle does.
                    viewModel.quickAIComposerDidChange(newValue)
                }
                .accessibilityLabel(viewModel.isRecentChatsPresented ? "Search chats" : "Ask Quick AI")
                if let confirmation = viewModel.composerConfirmation {
                    // A copy just landed: a checkmark in place of the action
                    // for a moment, then the action comes back.
                    Image(systemName: "checkmark")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .accessibilityHidden(true)
                    Text(confirmation)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                } else {
                    Text(action.label)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                    KeyCapGroup(keys: action.keys)
                }
            }
            .padding(.leading, House.Spacing.md)
            .padding(.trailing, House.Spacing.sm)
            .frame(height: House.Control.pill)
            // `Radius.pill` is half the row height, so this is a capsule,
            // drawn as a circular rounded rectangle: `Capsule`'s stroke
            // leaves a stray hairline outside its left cap on macOS 26.
            // Outline only, as Raycast draws it: the hairline on the glass,
            // no fill.
            .overlay(
                Self.fieldShape.strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: AQDesign.hairline)
            )
            .accessibilityElement(children: .contain)
            .accessibilityValue(
                viewModel.composerConfirmation
                    ?? "\(action.label), \(action.keys.joined(separator: " "))"
            )
            .onChange(of: viewModel.composerConfirmation) { _, confirmation in
                guard let confirmation else { return }
                announce(confirmation, priority: .medium)
            }

            Button {
                viewModel.handleCommandK()
            } label: {
                // A circle, the twin of the plus circle across the field,
                // full ink in both states as Raycast draws it. Closed it is
                // outline only; the open state shows on the circle's fill.
                Image(systemName: "command")
                    .font(AQDesign.TypeToken.glyphMedium)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .frame(width: House.Control.pill, height: House.Control.pill)
                    .background {
                        if viewModel.isActionPalettePresented {
                            Circle().fill(AQDesign.ColorToken.interactiveFill)
                        }
                    }
                    .overlay(
                        Circle().strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: AQDesign.hairline)
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Actions")
            .accessibilityValue(viewModel.isActionPalettePresented ? "Open" : "Closed")
            .help("Actions (⌘K)")
        }
        .padding(House.Spacing.xs)
    }

    /// The composer field's capsule.
    private static var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
    }

    private func focusComposer() {
        FocusRequest.apply($composerFocused)
    }

    private func announce(_ text: String, priority: NSAccessibilityPriorityLevel) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: priority.rawValue,
            ]
        )
    }

    // MARK: - Floating choosers

    /// The Transform chooser, the model chooser, and Add Context float above
    /// the composer here, where at root they sit inline under the input row.
    @ViewBuilder
    private var floatingChooser: some View {
        if viewModel.isTransformChooserPresented
            || viewModel.isModelChooserPresented
            || viewModel.isAssistantChooserPresented
            || viewModel.isAddContextMenuPresented {
            Group {
                if viewModel.isTransformChooserPresented {
                    TransformChooserPane(viewModel: viewModel)
                } else if viewModel.isModelChooserPresented {
                    ModelChooserPane(viewModel: viewModel)
                } else if viewModel.isAssistantChooserPresented {
                    AssistantChooserPane(viewModel: viewModel)
                } else {
                    AddContextPane(viewModel: viewModel)
                }
            }
            // The window's full inner width, at any size.
            .frame(maxWidth: .infinity)
            .panelGlass(radius: AQDesign.cardCornerRadius)
            .panelShadows()
            .padding(.horizontal, House.Spacing.xs)
            .padding(.bottom, Self.composerRowHeight)
        }
    }
}

// MARK: - Recent Chats

/// `⌘J`: the recent chat list in place of the thread. One column of the
/// launcher's own chat rows (the Chats catalog rows: icon tile, title,
/// question count and time), pinned first, narrowed by what the composer
/// holds; `↑↓` move, `↩` opens the chat in the thread, `esc` clears the
/// search and then returns to the thread.
private struct RecentChatsList: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        let items = viewModel.recentChatItems
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                SectionLabel(text: "Recent Chats")
                Spacer()
                KeyHint(label: "Move", keys: ["↑", "↓"])
                KeyHint(label: "Open", keys: ["↩"])
                // Escape clears a search before it leaves the list.
                KeyHint(label: viewModel.input.isEmpty ? "Back" : "Clear", keys: ["esc"])
            }
            .padding(.horizontal, House.Spacing.lg)
            .padding(.vertical, House.Spacing.xs)

            SelectableListPane(
                items: items,
                selectedIndex: $viewModel.recentChatsIndex,
                rowSpacing: PanelSizing.actionRowSpacing,
                rowHeight: House.Control.row,
                listInsets: EdgeInsets(
                    top: House.Spacing.xs,
                    leading: House.Spacing.sm,
                    bottom: House.Spacing.xs,
                    trailing: House.Spacing.sm
                ),
                emptyText: viewModel.input.isEmpty ? "No chats yet" : "No chats match",
                scrollsToSelection: true,
                onActivate: open
            ) { index, item, isSelected in
                LauncherResultRow(
                    result: .item(item),
                    isSelected: isSelected,
                    position: index + 1,
                    total: items.count
                )
                .padding(.horizontal, House.Spacing.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent Chats")
    }

    private func open(_ item: LauncherCatalogItem) {
        viewModel.recentChatsIndex = viewModel.recentChatItems.firstIndex { $0.id == item.id } ?? 0
        viewModel.openSelectedRecentChat()
    }
}

// MARK: - Change Assistant

/// ⌘K › Change Assistant (`⌥⌘A`): No Assistant, then every assistant, with
/// its alias and tools. ↑↓ move, Return picks, Esc closes. Floats above the
/// composer, like the model chooser.
private struct AssistantChooserPane: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        let options = viewModel.assistantChooserOptions
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Text(ResultAction.changeAssistant.title)
                    .font(AQDesign.TypeToken.section)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                Spacer()
                KeyHint(label: "Move", keys: ["↑", "↓"])
                KeyHint(label: QuickViewModel.assistantChooserConfirmTitle, keys: ["↩"])
                KeyHint(label: "Close", keys: ["esc"])
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.top, AQDesign.Space.standard)

            SelectableListPane(
                items: options,
                selectedIndex: $viewModel.assistantChooserIndex,
                rowHeight: AQDesign.rowHeight,
                scrollsToSelection: true,
                onActivate: { option in
                    // A click picks the row it lands on, not the keyed one.
                    if let index = options.firstIndex(of: option) {
                        viewModel.assistantChooserIndex = index
                    }
                    viewModel.runAssistantChooserSelection()
                }
            ) { _, option, _ in
                HStack(spacing: AQDesign.Space.row) {
                    IconTile {
                        Image(systemName: option.assistantID == nil
                              ? "bubble.left"
                              : ResultAction.changeAssistant.systemImage)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    }
                    Text(option.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                    Text(option.detail)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, AQDesign.Space.row)
                .contentShape(Rectangle())
            }
            .frame(height: PanelSizing.actionListHeight(rows: options.count, padded: false))
            .padding(.horizontal, AQDesign.Space.standard)
            .padding(.bottom, AQDesign.Space.standard)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ResultAction.changeAssistant.title)
    }
}
