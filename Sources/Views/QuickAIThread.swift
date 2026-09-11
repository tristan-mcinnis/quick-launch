import AppKit
import SwiftUI

/// The Quick AI thread: user turns as pills on the right, answers as prose
/// on the left, the tool and status lines, the question card when the model
/// asks, the "↓ Latest" chip, and every scroll the thread makes. One view
/// for the Quick AI surface and the AI Chat window, so the two never drift.
///
/// The thread is one centred column as wide as on the standard 750-wide
/// surface (`QuickAIView.threadColumnWidth`), narrower when the window is.
struct QuickAIThread: View {
    @Bindable var viewModel: QuickViewModel
    /// Find in Chat's hits (AI Chat): each drawn in the hover fill inside
    /// the text, the current one in the selection fill. Nil on the Quick AI
    /// surface.
    var find: ThreadFindHighlights? = nil
    /// Where the current hit sits under its message's head, once laid out.
    var onFindHitOffset: ((FindHit, CGFloat) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the thread is scrolled. Every scroll the thread makes goes
    /// through it: to a message's head, to an edge, or by a page.
    @State private var threadPosition = ScrollPosition()
    /// The thread's last reported geometry, for a page's size and bounds.
    @State private var threadGeometry = ThreadGeometry()
    /// Whether the thread is still, tracked by the reader, or animating a
    /// scroll it was asked for.
    @State private var scrollPhase = ScrollPhase.idle
    /// Where laid-out turns start in the thread's content, and a find
    /// scroll waiting for its message to be laid out. Not observed: a
    /// geometry report must never redraw the thread.
    @State private var turnGeometry = TurnGeometry()

    /// The thread's content, where `scrollTo(y:)` measures from.
    private nonisolated static let contentSpace = "quick-ai-thread-content"

    /// One message's own coordinate space, where a find hit is measured.
    nonisolated static func turnSpace(_ id: UUID) -> String { "quick-ai-turn-\(id.uuidString)" }

    private static let threadErrorID = "quick-ai-thread-error"
    private static let liveAnswerID = "quick-ai-live-answer"
    private static let detachedQuestionID = "quick-ai-detached-question"
    private static let detachedAnswerID = "quick-ai-detached-answer"
    private static let liveQuestionID = "quick-ai-live-question"
    private static let statusLineID = "quick-ai-status"
    private static let webSearchNoteID = "quick-ai-web-search"
    private static let threadNoticeID = "quick-ai-thread-notice"

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

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: House.Spacing.md) {
                let pendingQuestion = pendingQuestion
                ForEach(viewModel.conversationMessages) { message in
                    turn(message)
                        .coordinateSpace(.named(Self.turnSpace(message.id)))
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .named(Self.contentSpace)).minY
                        } action: { top in
                            turnGeometry.tops[message.id] = top
                            performPendingFindScroll(for: message.id)
                        }
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
                // Where the thread went after Continue in pi, or what
                // happened to the chat (stopped, moved, deleted).
                if let notice = viewModel.threadNotice {
                    toolLine(notice, symbol: viewModel.threadNoticeSymbol)
                        .id(Self.threadNoticeID)
                }
            }
            .frame(maxWidth: QuickAIView.threadColumnWidth)
            .padding(.top, House.Spacing.xl)
            .padding(.horizontal, House.Spacing.lg)
            .padding(.bottom, House.Spacing.md)
            // Centred in a window wider than the standard surface.
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(Self.contentSpace))
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
            // Nothing below a thread that fits its view, whatever the follow
            // flag says: a scroll to a message there never moves the view.
            if viewModel.showsJumpToLatest, !threadGeometry.fitsView { latestChip }
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
        /// The whole thread is in view. False before the first report.
        var fitsView: Bool { visibleHeight > 0 && contentHeight <= visibleHeight }
        /// The furthest down the view can go.
        var maximumTop: CGFloat { max(0, contentHeight - visibleHeight) }
        /// One page: the view's height less a line of overlap to keep place.
        var page: CGFloat { max(visibleHeight - House.Spacing.xxxl, House.Spacing.xxxl) }

        /// The view's top that puts a find hit at content `y` a third of
        /// the way down the view, inside the scroll range.
        func findScrollTop(hitAt y: CGFloat) -> CGFloat {
            min(max(0, y - visibleHeight / 3), maximumTop)
        }
    }

    /// Laid-out turns' tops in the content, and the find scroll waiting for
    /// one. A reference the view keeps, so writing it never redraws.
    @MainActor final class TurnGeometry {
        var tops: [UUID: CGFloat] = [:]
        var pending: (id: UUID, offset: CGFloat)?
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
            VStack(alignment: .trailing, spacing: House.Spacing.xs) {
                // The question's attachments sit over its pill, read only.
                if !message.attachmentRefs.isEmpty {
                    pillChips(for: message)
                }
                userPill(
                    viewModel.collapseState(for: message),
                    showsShortcut: viewModel.showsCollapseShortcut(for: message),
                    findRanges: find?.ranges(in: message.id, part: .question) ?? [],
                    findCurrent: find?.current(in: message.id).flatMap { $0.part == .question ? $0 : nil }
                ) {
                    viewModel.toggleTranscriptMessage(message.id)
                }
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

    /// A sent question's chips: a click opens the file in Quick Look or the
    /// link in the browser; a "Not loaded" chip offers Re-attach.
    private func pillChips(for message: QuickMessage) -> some View {
        let refs = Dictionary(message.attachmentRefs.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        return AttachmentPillChips(
            chips: viewModel.attachmentChips(for: message),
            onOpen: { chip in
                guard let ref = refs[chip.id] else { return }
                if let url = viewModel.attachmentFileURL(ref) {
                    AttachmentQuickLook.shared.preview(url)
                } else {
                    viewModel.openAttachment(ref)
                }
            },
            onReattach: { chip in
                if let ref = refs[chip.id] { viewModel.reattach(ref) }
            },
            canReattach: { chip in
                refs[chip.id].map(viewModel.canReattach) ?? false
            }
        )
        .frame(maxWidth: House.Layout.quickAIAnswerMaxWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
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
                instanceID: "message-\(message.id.uuidString)",
                messageID: message.id
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
        findRanges: [TextRange] = [],
        findCurrent: FindHit? = nil,
        toggle: (() -> Void)?
    ) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            CollapsibleMessageText(
                state: state,
                showsShortcut: showsShortcut,
                plainTextFont: AQDesign.TypeToken.body,
                fillsWidth: false,
                findRanges: findRanges,
                findCurrent: findCurrent?.range
            ) {
                toggle?()
            }
            .overlay(alignment: .topLeading) {
                if let findCurrent, let onFindHitOffset {
                    GeometryReader { proxy in
                        FindHitMarker(
                            rect: FindHitGeometry.plainRect(
                                text: state.displayedText,
                                font: NSFont.systemFont(ofSize: House.TypeToken.Size.bodySmall),
                                range: findCurrent.range,
                                width: proxy.size.width
                            ),
                            space: Self.turnSpace(findCurrent.messageID)
                        ) { offset in
                            onFindHitOffset(findCurrent, offset)
                        }
                    }
                }
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

    private func answerProse(
        _ markdown: String,
        isStreaming: Bool,
        instanceID: String,
        messageID: UUID? = nil
    ) -> some View {
        let current = messageID.flatMap { find?.current(in: $0) }
        return MarkdownTextView(
            markdown: markdown,
            isStreaming: isStreaming,
            scrolls: false,
            instanceID: instanceID,
            findRanges: messageID.flatMap { find?.segmentRanges(in: $0) } ?? [:],
            findCurrent: current.flatMap { hit in
                guard case .segment(let segment) = hit.part else { return nil }
                return SegmentFindHit(segment: segment, range: hit.range)
            },
            findSpace: messageID.map(Self.turnSpace),
            onFindCurrentOffset: current.flatMap { hit in
                onFindHitOffset.map { report in { offset in report(hit, offset) } }
            }
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
        var findTarget: CGFloat?
        if case .messageOffset(let id, let offset) = target {
            if let top = turnGeometry.tops[id] {
                findTarget = geometry.findScrollTop(hitAt: top + offset)
                turnGeometry.pending = nil
            } else {
                // Not laid out yet: bring its head in first; once it is laid
                // out, `performPendingFindScroll` puts the hit in place.
                turnGeometry.pending = (id, offset)
            }
        }
        let move = {
            switch target {
            case .messageTop(let id): threadPosition.scrollTo(id: id, anchor: .top)
            case .messageOffset(let id, _):
                if let findTarget {
                    threadPosition.scrollTo(y: findTarget)
                } else {
                    threadPosition.scrollTo(id: id, anchor: .top)
                }
            case .top: threadPosition.scrollTo(edge: .top)
            case .bottom: threadPosition.scrollTo(edge: .bottom)
            case .pageUp: threadPosition.scrollTo(y: max(0, geometry.top - geometry.page))
            case .pageDown: threadPosition.scrollTo(y: min(geometry.maximumTop, geometry.top + geometry.page))
            }
        }
        animate(move)
    }

    /// A find scroll that waited for its message: the message is laid out
    /// now, so the hit goes a third of the way down the view.
    private func performPendingFindScroll(for id: UUID) {
        guard let pending = turnGeometry.pending, pending.id == id, let top = turnGeometry.tops[id] else { return }
        turnGeometry.pending = nil
        let target = threadGeometry.findScrollTop(hitAt: top + pending.offset)
        animate { threadPosition.scrollTo(y: target) }
    }

    private func animate(_ move: @escaping () -> Void) {
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
}
