import AppKit
import SwiftUI

/// `⌘J`: the current thread at full height, with the chat history list beside
/// it. It stays inside the one overlay window, so the composer and the footer
/// above and below it are the overlay's own.
///
/// Every message draws through the answer stack (`MarkdownTextView` with
/// `scrolls: false`), so prose, code blocks, and the code block's Copy and
/// wrap controls read here exactly as they do in the overlay answer body. The
/// rail lists the same history the `⌘[` and `⌘]` keys walk, and picking a row
/// continues that chat without leaving the view.
struct ConversationView: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            chatRail
            Rectangle()
                .fill(AQDesign.ColorToken.divider)
                .frame(width: AQDesign.hairline)
            thread
        }
        .frame(height: ConversationViewLayout.bodyHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation with \(viewModel.activeModelDisplay)")
    }

    // MARK: - Chat rail

    private var chatRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.standard) {
                SectionLabel(text: "Recent AI Chats")
                Spacer()
                KeyHint(label: "Open", keys: ["↩"])
            }
            .padding(.horizontal, AQDesign.Space.standard)
            .padding(.top, AQDesign.Space.standard)
            .padding(.bottom, AQDesign.Space.compact)

            SelectableListPane(
                items: viewModel.history,
                selectedIndex: $viewModel.conversationViewHistoryIndex,
                rowSpacing: PanelSizing.actionRowSpacing,
                rowHeight: AQDesign.rowHeight,
                listInsets: EdgeInsets(
                    top: AQDesign.Space.compact,
                    leading: AQDesign.Space.compact,
                    bottom: AQDesign.Space.compact,
                    trailing: AQDesign.Space.compact
                ),
                emptyText: "No chats yet",
                scrollsToSelection: true,
                onActivate: open
            ) { _, conversation, _ in
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(conversation.model.isEmpty ? "No model" : conversation.model)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, AQDesign.Space.standard)
                .contentShape(Rectangle())
            }

            HStack(spacing: AQDesign.Space.standard) {
                KeyHint(label: "Move", keys: ["↑", "↓"])
                KeyHint(label: "Back", keys: ["esc"])
                Spacer()
            }
            .padding(.horizontal, AQDesign.Space.standard)
            .padding(.bottom, AQDesign.Space.standard)
        }
        .frame(width: ConversationViewLayout.historyWidth)
    }

    private func open(_ conversation: QuickConversation) {
        viewModel.conversationViewHistoryIndex = viewModel.history.firstIndex {
            $0.id == conversation.id
        } ?? 0
        viewModel.loadConversation(id: conversation.id)
    }

    // MARK: - Thread

    private var thread: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AQDesign.Space.standard) {
                SectionLabel(text: "Conversation")
                Spacer()
                HouseChip(text: viewModel.activeModelDisplay, icon: "cpu")
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.top, AQDesign.Space.standard)
            .padding(.bottom, AQDesign.Space.compact)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AQDesign.Space.row) {
                        ForEach(viewModel.conversationMessages) { message in
                            block(for: message)
                                .id(message.id)
                        }
                        if viewModel.isStreaming {
                            block(for: liveAnswer, isLive: true)
                                .id(Self.liveAnswerID)
                        }
                    }
                    .padding(.horizontal, AQDesign.Space.panel)
                    .padding(.vertical, AQDesign.Space.standard)
                }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: viewModel.conversationMessages.count) { _, _ in scrollToEnd(proxy) }
                .onChange(of: viewModel.output) { _, _ in scrollToEnd(proxy) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let liveAnswerID = "conversation-live-answer"

    /// The in-flight answer, before the stream completes and it joins the
    /// conversation as a message.
    private var liveAnswer: QuickMessage {
        QuickMessage(role: .assistant, content: viewModel.output)
    }

    @ViewBuilder
    private func block(for message: QuickMessage, isLive: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
            Text((message.role == .user ? "You" : "Answer").uppercased())
                .font(AQDesign.TypeToken.section)
                .tracking(AQDesign.TypeToken.sectionTracking)
                .foregroundStyle(
                    message.role == .user
                        ? AQDesign.ColorToken.textPrimary
                        : AQDesign.ColorToken.textTertiary
                )
            if isLive {
                // The in-flight answer is not a stored message yet, so it
                // has no id to collapse under: it always shows what has
                // arrived, and the composer above can stop the stream.
                MarkdownTextView(
                    markdown: message.content,
                    isStreaming: true,
                    scrolls: false,
                    instanceID: "live-answer"
                )
            } else {
                CollapsibleMessageText(
                    state: viewModel.collapseState(for: message),
                    rendersMarkdown: true,
                    instanceID: "message-\(message.id.uuidString)"
                ) {
                    viewModel.toggleTranscriptMessage(message.id)
                }
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if viewModel.isStreaming {
            proxy.scrollTo(Self.liveAnswerID, anchor: .bottom)
        } else if let last = viewModel.conversationMessages.last?.id {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}
