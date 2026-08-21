import SwiftUI
import Combine

struct OverlayView: View {
    @Bindable var viewModel: QuickViewModel
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            ? AQDesign.ColorToken.success
            : AQDesign.ColorToken.accent
    }

    var body: some View {
        VStack(spacing: 0) {
            // Input row
            HStack(spacing: AQDesign.Space.standard) {
                TextField(
                    viewModel.isFollowUp ? "Ask a follow-up…" : "Ask anything…",
                    text: $viewModel.input,
                    axis: .vertical
                )
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.input)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .submitLabel(.send)
                    .onSubmit { Task { await viewModel.submitResolvingFuzzyAlias() } }
                    .onKeyPress(.tab) {
                        guard !viewModel.savedPromptMatches.isEmpty else { return .ignored }
                        viewModel.completeFirstFuzzyAlias()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !viewModel.applicationMatches.isEmpty else { return .ignored }
                        viewModel.moveApplicationSelection(1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !viewModel.applicationMatches.isEmpty else { return .ignored }
                        viewModel.moveApplicationSelection(-1)
                        return .handled
                    }
                    .onChange(of: viewModel.input) { _, _ in
                        viewModel.resetApplicationSelection()
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

                moreMenu
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            if viewModel.isApplicationActionPanePresented,
               let application = viewModel.contextualApplication {
                Divider()
                ApplicationActionPane(
                    viewModel: viewModel,
                    application: application
                )
            } else if viewModel.isActionPalettePresented {
                Divider()
                QuickActionPalette(viewModel: viewModel)
            }

            if !viewModel.isActionPalettePresented,
               !viewModel.isApplicationActionPanePresented,
               !viewModel.applicationMatches.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(viewModel.applicationMatches.enumerated()),
                        id: \.element.id
                    ) { index, application in
                        Button {
                            viewModel.launch(application: application)
                        } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 22, height: 22)
                                Text(application.name)
                                    .font(AQDesign.TypeToken.body.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if index == viewModel.applicationSelectionIndex {
                                    Text("Open  ↩")
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 20)
                            .frame(height: 42)
                            .background(
                                index == viewModel.applicationSelectionIndex
                                    ? AQDesign.ColorToken.selectionFill
                                    : .clear
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(application.name)")
                    }
                }
            }

            // Saved-prompt autocomplete
            if !viewModel.isApplicationActionPanePresented,
               !viewModel.savedPromptMatches.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.savedPromptMatches) { match in
                        Button {
                            viewModel.complete(savedPrompt: match)
                        } label: {
                            HStack(spacing: 10) {
                                Text(viewModel.settings.savedPromptPrefix + match.alias)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(AQDesign.ColorToken.accent)
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

            if viewModel.isConversationHistoryPresented {
                Divider()
                ConversationTranscript(messages: viewModel.conversationMessages)
                    .transition(.opacity)
            } else if !viewModel.output.isEmpty || viewModel.isStreaming {
                Divider()
                MarkdownTextView(
                    attributedString: MarkdownRenderer.render(viewModel.output),
                    isStreaming: viewModel.isStreaming
                )
                .frame(maxHeight: 380)
                .padding(20)
                .transition(.opacity)
            }

            if !viewModel.output.isEmpty && !viewModel.isStreaming {
                Divider()
                HStack(spacing: AQDesign.Space.standard) {
                    Button {
                        viewModel.copyOutputAndMark()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .frame(minWidth: 92, minHeight: AQDesign.controlHeight)
                            .contentShape(Rectangle())
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy result (Command-Shift-C)")
                    Button {
                        Task { await viewModel.pasteOutputToPreviousApp() }
                    } label: {
                        Label(
                            viewModel.pasteTargetName.map { "Paste to \($0)" } ?? "Paste Back",
                            systemImage: "arrow.turn.down.right"
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 120, minHeight: AQDesign.controlHeight)
                        .contentShape(Rectangle())
                    }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .help("Paste result into the previous app (Command-Shift-V)")
                    Spacer()
                }
                .font(AQDesign.TypeToken.label)
                .buttonStyle(.borderless)
                .tint(AQDesign.ColorToken.accent)
                .padding(.horizontal, 20)
                .frame(height: AQDesign.controlHeight)
            }

            // Error message
            if let error = viewModel.errorMessage {
                Divider()
                HStack(spacing: AQDesign.Space.standard) {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(AQDesign.ColorToken.danger)
                    Spacer()
                    if viewModel.needsAccessibilityPermission {
                        Button("Open System Settings") {
                            viewModel.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: AQDesign.cornerRadius))
        .preferredColorScheme(viewModel.settings.appearance.swiftUIColorScheme)
        .animation(
            reduceMotion ? nil : .easeOut(duration: AQDesign.motionDuration),
            value: viewModel.output.isEmpty
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: AQDesign.motionDuration),
            value: viewModel.isConversationHistoryPresented
        )
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

    private var moreMenu: some View {
        Menu {
            Button {
                viewModel.toggleActionPalette()
            } label: {
                Label("Quick Actions…", systemImage: "wand.and.stars")
            }

            Divider()
            modelSubmenu
            historySubmenu

            if !viewModel.conversationMessages.isEmpty {
                Divider()
                Button {
                    viewModel.toggleConversationHistory()
                } label: {
                    Label(
                        viewModel.isConversationHistoryPresented
                            ? "Show Latest Result"
                            : "Show Conversation",
                        systemImage: "text.bubble"
                    )
                }
            }

            Divider()
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Label("Settings…", systemImage: "gear")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16))
                .foregroundStyle(viewModel.isActionPalettePresented ? sendColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Actions, model, history, and settings")
    }

    private var modelSubmenu: some View {
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
            Label("Model: \(viewModel.activeModelDisplay)", systemImage: "cpu")
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var historySubmenu: some View {
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
            Label("Recent Quick Actions", systemImage: "clock.arrow.circlepath")
        }
    }
}

private struct ConversationTranscript: View {
    let messages: [QuickMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role == .user ? "You" : "Answer")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(
                                    message.role == .user ? AQDesign.ColorToken.accent : .secondary
                                )
                            Text(String(message.content.prefix(8_000)))
                                .font(.system(size: 13))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(message.id)
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 380)
            .onAppear {
                guard let lastID = messages.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
        .accessibilityLabel("Current quick action conversation")
    }
}

private struct ApplicationActionPane: View {
    @Bindable var viewModel: QuickViewModel
    let application: LaunchableApplication

    var body: some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
            HStack(spacing: AQDesign.Space.standard) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
                    Text(application.name)
                        .font(AQDesign.TypeToken.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Application actions")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open") {
                    _ = viewModel.launch(application: application)
                }
                .buttonStyle(.borderedProminent)
                .tint(AQDesign.ColorToken.accent)
                .frame(minHeight: AQDesign.controlHeight)
            }

            TextField("Search alias", text: Binding(
                get: { viewModel.applicationAlias(for: application) },
                set: { viewModel.setApplicationAlias($0, for: application) }
            ))
            .textFieldStyle(.roundedBorder)

            ActionHotkeyRecorderView(
                hotkey: Binding(
                    get: { viewModel.applicationHotkey(for: application) },
                    set: { viewModel.setApplicationHotkey($0, for: application) }
                ),
                label: "Global hotkey",
                changeNotification: .launcherItemHotkeysChanged
            )

            if let conflict = viewModel.applicationConfigurationConflict(for: application) {
                Text(conflict)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.danger)
            }

            HStack {
                Text("Return opens · Command-K closes actions")
                Spacer()
                Button("Done") { viewModel.closeApplicationActionPane() }
                    .buttonStyle(.plain)
            }
            .font(AQDesign.TypeToken.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AQDesign.Space.section)
        .padding(.vertical, 12)
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
                                    .foregroundStyle(
                                        index == selectedIndex
                                            ? AQDesign.ColorToken.accent
                                            : .secondary
                                    )
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
                                index == selectedIndex ? AQDesign.ColorToken.selectionFill : .clear,
                                in: RoundedRectangle(cornerRadius: AQDesign.itemCornerRadius)
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
    static let launcherItemHotkeysChanged = Notification.Name("ApfelQuick.launcherItemHotkeysChanged")
    static let providerChanged = Notification.Name("ApfelQuick.providerChanged")
    static let managedServiceRequested = Notification.Name("ApfelQuick.managedServiceRequested")
}
