import SwiftUI
import Combine

struct OverlayView: View {
    @Bindable var viewModel: QuickViewModel
    @FocusState private var inputFocused: Bool
    /// The send button icon and color change based on state:
    ///  - idle: arrow.up.circle.fill (purple)
    ///  - streaming: stop.fill (purple)
    ///  - justCopied: checkmark.circle.fill (green, 2s)
    private var sendIcon: String {
        if viewModel.justCopied { return "checkmark.circle.fill" }
        if viewModel.isStreaming { return "stop.fill" }
        return "arrow.up.circle.fill"
    }

    private var sendColor: Color {
        viewModel.justCopied
            ? Color(red: 0.18, green: 0.72, blue: 0.36)
            : Color(red: 0.55, green: 0.36, blue: 0.96)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Input row
            HStack(spacing: 8) {
                TextField(
                    viewModel.isFollowUp ? "Ask a follow-up…" : "Ask anything…",
                    text: $viewModel.input,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await viewModel.submitResolvingFuzzyAlias() } }
                    .onKeyPress(.tab) {
                        guard !viewModel.savedPromptMatches.isEmpty else { return .ignored }
                        viewModel.completeFirstFuzzyAlias()
                        return .handled
                    }
                    .disabled(viewModel.isStreaming)

                // Send / stop / copied indicator — same slot, different icon
                Button {
                    if viewModel.isStreaming {
                        viewModel.cancel()
                    } else {
                        Task { await viewModel.submitResolvingFuzzyAlias() }
                    }
                } label: {
                    Image(systemName: sendIcon)
                        .foregroundStyle(sendColor)
                        .font(.system(size: 20))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(viewModel.input.isEmpty && !viewModel.isStreaming)
                .help(viewModel.justCopied ? "Copied to clipboard" : "Send (or press Return)")

                modelMenu

                Button {
                    viewModel.toggleActionPalette()
                } label: {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(viewModel.isActionPalettePresented ? sendColor : .secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Quick actions (Command-K)")

                historyMenu

                Button {
                    NotificationCenter.default.post(
                        name: .openSettings, object: nil)
                } label: {
                    Image(systemName: "gear")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            if viewModel.isActionPalettePresented {
                Divider()
                QuickActionPalette(viewModel: viewModel)
            }

            // Saved-prompt autocomplete
            if !viewModel.savedPromptMatches.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.savedPromptMatches) { match in
                        Button {
                            viewModel.complete(savedPrompt: match)
                        } label: {
                            HStack(spacing: 10) {
                                Text(viewModel.settings.savedPromptPrefix + match.alias)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.55, green: 0.36, blue: 0.96))
                                Text(match.prompt)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Divider + result (only shown when there's output or streaming)
            if !viewModel.output.isEmpty || viewModel.isStreaming {
                Divider()
                MarkdownTextView(
                    attributedString: MarkdownRenderer.render(viewModel.output),
                    isStreaming: viewModel.isStreaming
                )
                .frame(maxHeight: 380)
                .padding(20)
            }

            // Error message
            if let error = viewModel.errorMessage {
                Divider()
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .preferredColorScheme(viewModel.settings.appearance.swiftUIColorScheme)
        .onAppear { focusInput() }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in focusInput() }
        .onKeyPress(.escape) {
            if viewModel.isStreaming {
                viewModel.cancel()
            }
            NotificationCenter.default.post(name: .dismissOverlay, object: nil)
            return .handled
        }
    }

    private func focusInput() {
        Task { @MainActor in
            await Task.yield()
            inputFocused = true
        }
    }

    private var modelMenu: some View {
        Menu {
            Text("Using \(viewModel.activeModelDisplay)")
            Divider()
            ForEach(viewModel.settings.providers) { provider in
                Menu(provider.name) {
                    if provider.models.isEmpty {
                        Button("Refresh models") {
                            Task { await viewModel.refreshModels(providerID: provider.id) }
                        }
                    } else {
                        ForEach(provider.models, id: \.self) { model in
                            Button {
                                viewModel.selectModel(providerID: provider.id, model: model)
                            } label: {
                                if provider.id == viewModel.settings.selectedProviderID,
                                   model == provider.selectedModel {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Refresh detected models") {
                Task { await viewModel.refreshDetectedModels() }
            }
            Button("Model settings…") {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
        } label: {
            Image(systemName: "cpu")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model: \(viewModel.activeModelDisplay)")
    }

    private var historyMenu: some View {
        Menu {
            Button("New quick action") { viewModel.startNewConversation() }
            if !viewModel.history.isEmpty {
                Divider()
                ForEach(viewModel.history.prefix(10)) { conversation in
                    Button(conversation.title) {
                        viewModel.loadConversation(id: conversation.id)
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Recent quick actions")
    }
}

private struct QuickActionPalette: View {
    @Bindable var viewModel: QuickViewModel
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private var actions: [SavedPrompt] { viewModel.actionMatches }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Search actions", text: $viewModel.actionQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { runSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) {
                        viewModel.closeActionPalette()
                        return .handled
                    }
                Text("⌘K")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        Button { run(action) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: action.outputBehavior == .replaceSelection
                                      ? "text.cursor" : "sparkles")
                                    .frame(width: 18)
                                    .foregroundStyle(index == selectedIndex ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text("\(viewModel.settings.savedPromptPrefix)\(action.alias) · \(action.outputBehavior.displayName)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let hotkey = action.hotkey {
                                    Text(hotkeyDisplayName(hotkey))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 42)
                            .background(
                                index == selectedIndex ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: 252)

            HStack(spacing: 12) {
                Text("↑↓ Navigate")
                Text("↩ Run")
                Text("Tab completes aliases")
                Spacer()
                Text("Esc Close")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .onAppear { focusSearch() }
        .onChange(of: viewModel.actionQuery) { _, _ in selectedIndex = 0 }
    }

    private func focusSearch() {
        Task { @MainActor in
            await Task.yield()
            searchFocused = true
        }
    }

    private func move(_ delta: Int) {
        guard !actions.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + actions.count) % actions.count
    }

    private func runSelected() {
        guard actions.indices.contains(selectedIndex) else { return }
        run(actions[selectedIndex])
    }

    private func run(_ action: SavedPrompt) {
        Task { await viewModel.perform(action: action) }
    }

    private func hotkeyDisplayName(_ hotkey: ActionHotkey) -> String {
        var settings = QuickSettings()
        settings.hotkeyKeyCode = hotkey.keyCode
        settings.hotkeyModifiers = hotkey.modifiers
        return settings.hotkeyDisplayName
    }
}

extension Notification.Name {
    static let dismissOverlay = Notification.Name("ApfelQuick.dismissOverlay")
    static let openSettings = Notification.Name("ApfelQuick.openSettings")
    static let hotkeyChanged = Notification.Name("ApfelQuick.hotkeyChanged")
    static let actionHotkeysChanged = Notification.Name("ApfelQuick.actionHotkeysChanged")
    static let providerChanged = Notification.Name("ApfelQuick.providerChanged")
}
