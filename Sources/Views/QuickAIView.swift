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

    private static let bottomID = "quick-ai-thread-end"
    private static let liveAnswerID = "quick-ai-live-answer"
    private static let detachedQuestionID = "quick-ai-detached-question"
    private static let detachedAnswerID = "quick-ai-detached-answer"
    private static let liveQuestionID = "quick-ai-live-question"
    private static let statusLineID = "quick-ai-status"
    private static let webSearchNoteID = "quick-ai-web-search"

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
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: House.Spacing.md) {
                    let pendingQuestion = pendingQuestion
                    ForEach(viewModel.conversationMessages) { message in
                        turn(message)
                            .id(message.id)
                        // The search line and the lines of the calls still
                        // streaming belong to the newest question; while that
                        // question is pending they hang under its pill
                        // instead. A finished answer draws its own lines.
                        if pendingQuestion == nil, message.id == lastUserMessageID {
                            liveToolLines
                        }
                    }
                    // A question that is not a thread turn (the one being
                    // searched for, the one a local answer belongs to, one
                    // with no chat behind it) still reads as a turn: an
                    // answer never draws without its question.
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
                    // already drawn above; the dots take over once the
                    // model is thinking.
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
                    // A finished answer that is not the thread's last turn
                    // (a local answer, a command result, a Vault Search, a
                    // failed stream's partial text) draws after the thread,
                    // whether or not a chat is kept.
                    if let answer = viewModel.quickAIDetachedAnswer {
                        answerProse(answer, isStreaming: false, instanceID: "answer")
                            .id(Self.detachedAnswerID)
                    }
                    Color.clear
                        .frame(height: House.hairline)
                        .id(Self.bottomID)
                }
                .frame(maxWidth: Self.threadColumnWidth)
                .padding(.top, House.Spacing.xl)
                .padding(.horizontal, House.Spacing.lg)
                .padding(.bottom, House.Spacing.md)
                // Centred in a window wider than the standard surface.
                .frame(maxWidth: .infinity)
            }
            .overlay {
                let hints = viewModel.quickAIEmptyStateHints
                if !hints.isEmpty { emptyStateHints(hints) }
            }
            .onAppear { scrollToEnd(proxy) }
            .onChange(of: viewModel.conversationMessages.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: viewModel.output) { _, _ in scrollToEnd(proxy) }
            .onChange(of: viewModel.isStreaming) { _, _ in scrollToEnd(proxy) }
            .onChange(of: viewModel.streamingStatus) { _, _ in scrollToEnd(proxy) }
            .onChange(of: viewModel.liveToolRecords.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: viewModel.pendingAskQuestion?.isAnswered) { _, _ in scrollToEnd(proxy) }
            // Show more and Collapse bring the message's head to the top.
            .onChange(of: viewModel.threadScrollRequest) { _, request in
                guard let request else { return }
                if reduceMotion {
                    proxy.scrollTo(request.messageID, anchor: .top)
                } else {
                    withAnimation(.easeOut(duration: AQDesign.Motion.select)) {
                        proxy.scrollTo(request.messageID, anchor: .top)
                    }
                }
            }
        }
        .accessibilityLabel("Conversation with \(viewModel.activeModelDisplay)")
    }

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

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
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
                NSAccessibility.post(
                    element: NSApplication.shared,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: confirmation,
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ]
                )
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

    // MARK: - Floating choosers

    /// The Transform chooser, the model chooser, and Add Context float above
    /// the composer here, where at root they sit inline under the input row.
    @ViewBuilder
    private var floatingChooser: some View {
        if viewModel.isTransformChooserPresented
            || viewModel.isModelChooserPresented
            || viewModel.isAddContextMenuPresented {
            Group {
                if viewModel.isTransformChooserPresented {
                    TransformChooserPane(viewModel: viewModel)
                } else if viewModel.isModelChooserPresented {
                    ModelChooserPane(viewModel: viewModel)
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
