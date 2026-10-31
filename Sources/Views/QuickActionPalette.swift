import SwiftUI
import Combine
import HouseDesign

/// The `⌘K` palette: answer actions, the window's own actions, attach
/// commands, and saved prompts. Floats over the launcher, the Quick AI
/// surface, and the AI Chat window.
struct QuickActionPalette: View {
    @Bindable var viewModel: QuickViewModel
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    enum Entry: Identifiable {
        case result(ResultAction)
        case surface(QuickAISurfaceAction)
        case command(LauncherCatalogItem)
        case prompt(SavedPrompt)
        /// `⌘K` › Tools: one of the chat's tools, toggled by Return.
        case tool(ChatToolKind)
        case searchProvider(WebSearchProvider)
        /// `⌘K` › Open Source: one of the answer's sources.
        case source(ChatSource)
        /// `⌘K` › Copy Message or Capture Message to Memory: one message.
        case message(QuickMessage)

        var id: String {
            switch self {
            case .result(let action): "result:" + action.id
            case .surface(let action): "surface:" + action.id
            case .command(let item): "command:" + item.itemID
            case .prompt(let prompt): "prompt:" + prompt.id.uuidString
            case .tool(let kind): "tool:" + kind.rawValue
            case .searchProvider(let provider): "search-provider:" + provider.rawValue
            case .source(let source): "source:" + source.id
            case .message(let message): "message:" + message.id.uuidString
            }
        }
    }

    private var entries: [Entry] {
        switch viewModel.actionPaletteSubmenu {
        case .tools:
            return viewModel.paletteToolRows.map(Entry.tool)
        case .searchProviders:
            return viewModel.paletteSearchProviders.map(Entry.searchProvider)
        case .sources:
            return viewModel.paletteSourceRows.map(Entry.source)
        case .messages:
            return viewModel.paletteMessageRows.map(Entry.message)
        case nil:
            return viewModel.paletteResultActions.map(Entry.result)
                + viewModel.paletteSurfaceActions.map(Entry.surface)
                + viewModel.paletteCommandMatches.map(Entry.command)
                + viewModel.actionMatches.map(Entry.prompt)
        }
    }

    private var searchPrompt: String {
        switch viewModel.actionPaletteSubmenu {
        case .tools: "Search tools"
        case .searchProviders: "Search providers"
        case .sources: "Search sources"
        case .messages: "Search messages"
        case nil: "Search actions"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField(searchPrompt, text: $viewModel.actionQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { runSelected() }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                KeyCapGroup(keys: viewModel.shortcutKeyCaps(for: .commandPalette))
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.vertical, 10)

            SelectableListPane(
                items: entries,
                selectedIndex: $selectedIndex,
                rowSpacing: PanelSizing.actionRowSpacing,
                rowHeight: PanelSizing.actionRowHeight,
                listInsets: EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6),
                emptyText: "No actions here yet",
                scrollsToSelection: true,
                accessibilityValue: { index, isSelected in
                    isSelected
                        ? "Selected, \(index + 1) of \(entries.count)"
                        : "\(index + 1) of \(entries.count)"
                },
                onActivate: run
            ) { _, entry, isSelected in
                row(for: entry, isSelected: isSelected)
                    .padding(.horizontal, 20)
            }
            // Hug the rows (capped at six); an empty palette shows one quiet
            // placeholder row instead of a stretched dark sheet.
            .modifier(ComposerPaneListHeight(
                preferredHeight: PanelSizing.actionListHeight(rows: entries.count, padded: false),
                chromeHeight: PanelSizing.actionPaletteHeight(rows: 1) - PanelSizing.actionListHeight(rows: 1, padded: false)
            ))

            HStack(spacing: AQDesign.Space.row) {
                Text("↑↓ Navigate")
                switch viewModel.actionPaletteSubmenu {
                case .tools:
                    Text("↩ Turn on or off")
                    Text("For this chat")
                case .searchProviders:
                    Text("↩ Use provider")
                    Text("All chats")
                case .sources:
                    Text("↩ Open")
                case .messages(let action):
                    Text(action == .copy ? "↩ Copy" : "↩ Capture")
                case nil:
                    Text("↩ Run")
                    Text("Tab completes aliases")
                }
                Spacer()
                Text(viewModel.actionPaletteSubmenu == nil ? "Esc Close" : "Esc Back")
            }
            .font(AQDesign.TypeToken.metadata)
            .foregroundStyle(AQDesign.ColorToken.textTertiary)
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.bottom, 10)
        }
        .onAppear {
            focusSearch()
            announceSelected()
        }
        .onChange(of: viewModel.actionQuery) { _, _ in
            selectedIndex = 0
            announceSelected()
        }
        .onChange(of: viewModel.actionPaletteSubmenu) { _, _ in
            selectedIndex = 0
            announceSelected()
        }
    }

    @ViewBuilder
    private func row(for entry: Entry, isSelected: Bool) -> some View {
        switch entry {
        case .result(let action):
            paletteRow(symbol: viewModel.resultActionSystemImage(action), title: viewModel.resultActionTitle(action), detail: viewModel.resultActionDetail(action) ?? action.paletteGroup) {
                // The row names the key the router answers, not the default.
                KeyCapGroup(keys: viewModel.shortcutKeyCaps(for: ShortcutAction.forResultAction(action)))
            }
        case .surface(let action):
            paletteRow(symbol: action.systemImage, title: action.title, detail: action.detail) {
                if let actionName = action.shortcutAction {
                    KeyCapGroup(keys: viewModel.shortcutKeyCaps(for: actionName))
                } else if let shortcut = action.shortcut {
                    KeyCapGroup(keys: shortcut.keyCaps)
                }
            }
        case .command(let item):
            paletteRow(symbol: item.systemImage, title: item.title, detail: item.detail) {
                EmptyView()
            }
        case .prompt(let action):
            // An assistant row picks the assistant for the chat; every other
            // row runs its prompt on the text.
            paletteRow(
                symbol: action.isAssistant
                    ? ResultAction.changeAssistant.systemImage
                    : (action.outputBehavior == .replaceSelection ? "text.cursor" : "sparkles"),
                title: action.name,
                detail: "\(viewModel.settings.savedPromptPrefix)\(action.alias) · "
                    + (action.isAssistant ? "Assistant" : action.outputBehavior.displayName)
            ) {
                if let hotkey = action.hotkey {
                    KeyCapGroup(keys: hotkey.keyCaps)
                }
            }
        case .searchProvider(let provider):
            paletteRow(symbol: "magnifyingglass", title: provider.title, detail: provider.detail) {
                if viewModel.settings.webSearchProvider == provider {
                    Image(systemName: "checkmark")
                        .accessibilityLabel("Current provider")
                }
            }
        case .tool(let kind):
            let isAvailable = viewModel.isChatToolAvailable(kind)
            // A tool this Mac cannot run is never offered, whatever the chat
            // chose, so its row says so instead of "On".
            let isOn = isAvailable && viewModel.chatTools.contains(kind)
            paletteRow(
                symbol: kind.systemImage,
                title: kind.displayName,
                detail: isAvailable ? kind.detail : "Not available on this Mac"
            ) {
                HStack(spacing: AQDesign.Space.compact) {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(AQDesign.TypeToken.metadata)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                            .accessibilityHidden(true)
                    }
                    Text(isAvailable ? (isOn ? "On" : "Off") : "Unavailable")
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(isOn ? AQDesign.ColorToken.textPrimary : AQDesign.ColorToken.textTertiary)
                }
            }
        case .source(let source):
            paletteRow(
                symbol: "doc.text",
                title: source.title,
                detail: source.day ?? "Source"
            ) {
                EmptyView()
            }
        case .message(let message):
            paletteRow(
                symbol: message.role == .user ? "text.bubble" : "sparkles",
                title: QuickViewModel.messagePreview(message),
                detail: viewModel.messageDetail(message)
            ) {
                EmptyView()
            }
        }
    }

    /// Every palette row is the same shape: tile, title, detail, keys.
    @ViewBuilder
    private func paletteRow<Trailing: View>(
        symbol: String,
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: AQDesign.Space.row) {
            IconTile {
                Image(systemName: symbol)
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
            }
            HStack(alignment: .firstTextBaseline, spacing: AQDesign.Space.standard) {
                Text(title)
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: AQDesign.Space.standard)
            trailing()
        }
    }

    private func focusSearch() {
        FocusRequest.apply($searchFocused)
    }

    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        selectedIndex = ListSelection.wrappedIndex(selectedIndex, by: delta, count: entries.count)
        announceSelected()
    }

    private func announceSelected() {
        let current = entries
        guard current.indices.contains(selectedIndex) else { return }
        let title: String
        switch current[selectedIndex] {
        case .result(let action): title = viewModel.resultActionTitle(action)
        case .surface(let action): title = action.title
        case .command(let item): title = item.title
        case .prompt(let prompt): title = prompt.name
        case .searchProvider(let provider):
            title = provider.title + (viewModel.settings.webSearchProvider == provider ? ", current provider" : "")
        case .tool(let kind):
            title = "\(kind.displayName), \(viewModel.chatTools.contains(kind) ? "on" : "off")"
        case .source(let source): title = "Source \(source.title)"
        case .message(let message):
            title = "\(viewModel.messageDetail(message)), \(QuickViewModel.messagePreview(message))"
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: "\(title), selected, \(selectedIndex + 1) of \(current.count).",
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func runSelected() {
        let current = entries
        guard current.indices.contains(selectedIndex) else { return }
        run(current[selectedIndex])
    }

    private func run(_ entry: Entry) {
        switch entry {
        case .result(let action):
            Task { await viewModel.performResultAction(action) }
        case .surface(let action):
            viewModel.performQuickAISurfaceAction(action)
        case .command(let item):
            Task { await viewModel.runPaletteCommand(item) }
        case .prompt(let action):
            Task { await viewModel.perform(action: action) }
        case .tool(let kind):
            // The palette stays open so several tools can change at once.
            viewModel.toggleChatTool(kind)
            announceSelected()
        case .searchProvider(let provider):
            viewModel.selectWebSearchProvider(provider)
        case .source(let source):
            viewModel.requestOpenSource(source)
        case .message(let message):
            guard case .messages(let action) = viewModel.actionPaletteSubmenu else { return }
            Task { await viewModel.performMessageAction(action, on: message) }
        }
    }
}
