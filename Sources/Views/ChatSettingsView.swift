import SwiftUI

/// The Chat card in the General pane: the chat defaults (the tools a new
/// chat starts with, in Quick AI and in AI Chat), Keep AI Chat on top, and
/// one status line each for Continue in pi and the tool backends.
///
/// The four tool switches are `QuickSettings.newChatTools`; Web search is
/// the one `modelWebSearchEnabled` setting the Translator reads too. Keep
/// AI Chat on top is the AI Chat window's own `UserDefaults` key, so the
/// window's `⌘K`, its menu, and this switch always agree. The status lines
/// come from `ChatBackendProbe`, off the main thread, when the pane appears.
struct ChatSettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @AppStorage(AIChatWindowModel.alwaysOnTopDefaultsKey) private var keepAIChatOnTop = false

    /// The assistant editor's Tools choice names this card by these words.
    static let defaultsNote = "Chat defaults: the tools a new chat starts with, in Quick AI and AI Chat. \u{2318}K \u{203A} Tools changes them for one chat."

    var body: some View {
        SettingsCard("Chat") {
            CardNote(isFirst: true) {
                CardText(Self.defaultsNote)
            }

            ForEach(ChatToolKind.allCases) { tool in
                SettingsRow(title: tool.displayName, detail: Self.detail(for: tool)) {
                    Toggle(tool.displayName, isOn: toolBinding(tool))
                        .toggleStyle(InkToggleStyle())
                        .accessibilityLabel("\(tool.displayName) in new chats")
                }
            }

            WebSearchProviderRow(viewModel: viewModel)

            SettingsRow(
                title: "Keep AI Chat on top",
                detail: "The AI Chat window stays above other apps' windows."
            ) {
                Toggle("Keep AI Chat on top", isOn: $keepAIChatOnTop)
                    .toggleStyle(InkToggleStyle())
            }

            if showsStatus {
                SettingsRow(
                    title: "Continue in pi",
                    detail: viewModel.chatBackendStatus?.piLine ?? "Looking for tmux, pi and Ghostty."
                ) {
                    statusWord(viewModel.chatBackendStatus?.piLevel)
                }
                SettingsRow(
                    title: "Tool backends",
                    detail: viewModel.chatBackendStatus?.toolsLine ?? "Looking for recall and vault-vps."
                ) {
                    statusWord(viewModel.chatBackendStatus?.toolsLevel)
                }
            }
        }
        .task { await viewModel.refreshChatBackendStatus() }
    }

    /// No probe and no answer (a test's view model): no lines to show.
    private var showsStatus: Bool {
        viewModel.chatBackendProbe != nil || viewModel.chatBackendStatus != nil
    }

    static func detail(for tool: ChatToolKind) -> String {
        switch tool {
        case .web: "Search with the provider chosen below. The Translator uses it too."
        default: tool.detail
        }
    }

    private func toolBinding(_ tool: ChatToolKind) -> Binding<Bool> {
        viewModel.settingsBinding(
            get: { $0.isNewChatToolOn(tool) },
            set: { settings, on in settings.setNewChatTool(tool, on: on) }
        )
    }

    /// A dot and the word that says the same thing: the dot is never the
    /// only signal.
    private func statusWord(_ level: ChatBackendStatus.Level?) -> some View {
        let (word, dot): (String, Color) = switch level {
        case .ready: ("Ready", AQDesign.ColorToken.success)
        case .partial: ("Partly ready", AQDesign.ColorToken.warning)
        case .missing: ("Not ready", AQDesign.ColorToken.danger)
        case nil: ("Checking\u{2026}", AQDesign.ColorToken.textTertiary)
        }
        return HStack(spacing: AQDesign.Space.standard) {
            StatusDot(color: dot)
            Text(word)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(word)
    }
}
