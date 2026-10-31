import SwiftUI
import Combine
import HouseDesign

/// Raycast-style key hints: context on the left, actions on the right.
struct LauncherFooter: View {
    @Bindable var viewModel: QuickViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var visibleHints: [QuickViewModel.FooterHint] {
        let hints = viewModel.footerHints
        if dynamicTypeSize.isAccessibilitySize {
            return Array(hints.prefix(1))
        }
        guard let primary = hints.first else { return [] }
        if let actions = hints.first(where: { $0.label == "Actions" }) {
            // Show the primary destination, the next concrete action (the
            // paste/copy destination), then Actions — so a selection transform's
            // Replace and Paste destinations are both visible, not just ⌘K.
            let others = hints.filter { $0.label != "Actions" }
            return Array(([primary] + others.dropFirst()).prefix(2) + [actions])
        }
        return Array(hints.prefix(2))
    }

    var body: some View {
        HStack(spacing: AQDesign.Space.row) {
            StatusDot(color: viewModel.isStreaming
                ? AQDesign.ColorToken.warning
                : AQDesign.ColorToken.success)
            Text(viewModel.footerContext)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AQDesign.Space.row)
            HStack(spacing: AQDesign.Space.row) {
                ForEach(visibleHints, id: \.label) { hint in
                    KeyHint(label: hint.label, keys: hint.keys)
                }
            }
        }
        .frame(minHeight: AQDesign.footerHeight)
        .accessibilityElement(children: .combine)
    }
}

/// A coloured light and its word: "● On" in the success colour, "● Off" in
/// the danger colour, "● Paused" in the warning colour while a live session's
/// assertion is released by the battery. Read at a glance before the row text.
struct StatusLightLabel: View {
    let light: LauncherStatusLight

    private var color: Color {
        switch light {
        case .on: AQDesign.ColorToken.success
        case .paused: AQDesign.ColorToken.warning
        case .off: AQDesign.ColorToken.danger
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(light.label)
                .font(AQDesign.TypeToken.metadata.weight(.medium))
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(light.label)
    }
}

/// Three dots that breathe in turn: the model is working. Subtle on purpose.
struct ThinkingIndicator: View {
    @State private var phase = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `@State`, not a stored `let`: a stored publisher is rebuilt on every
    /// view init during streaming, which resets the subscription and can
    /// freeze the dots at phase 0. State keeps one publisher per identity.
    @State private var timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(AQDesign.ColorToken.textPrimary)
                    .frame(width: 5, height: 5)
                    .opacity(reduceMotion ? 0.55 : (index == phase ? 0.95 : 0.3))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: phase)
        .onReceive(timer) { _ in
            guard !reduceMotion else { return }
            phase = (phase + 1) % 3
        }
        .accessibilityLabel("Working")
    }
}

// MARK: - Shared composer pieces
//
// The root input row and the Quick AI composer are two fields with one
// keyboard contract; the strips and choosers under them are the same views
// on both surfaces (inline at root, floating over the Quick AI thread).

/// The arrow keys and Tab, routed in one fixed precedence: a live question,
/// the Transform chooser, the model chooser, Add Context, Recent Chats, the
/// answer's chat browsing, then the launcher list.
struct ComposerKeyRouting: ViewModifier {
    @Bindable var viewModel: QuickViewModel

    func body(content: Content) -> some View {
        content
            .onKeyPress(.tab) {
                viewModel.handleTab() ? .handled : .ignored
            }
            .onKeyPress(keys: [.upArrow, .downArrow, .pageUp, .pageDown], phases: [.down, .repeat]) { press in
                arrow(press)
            }
            .onKeyPress(.rightArrow) {
                guard viewModel.isGridCatalog, !viewModel.launcherMatches.isEmpty else { return .ignored }
                viewModel.moveApplicationSelection(1)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard viewModel.isGridCatalog, !viewModel.launcherMatches.isEmpty else { return .ignored }
                viewModel.moveApplicationSelection(-1)
                return .handled
            }
    }

    /// ↑ ↓ PageUp PageDown. On the Quick AI thread, PageUp and PageDown,
    /// ⌥↑ ⌥↓, and ⌘↑ ⌘↓ scroll it (the panel's shortcut path usually takes
    /// the modified arrows first; this is the same rule for the field).
    /// Plain ↑ ↓ move whatever list is up.
    private func arrow(_ press: KeyPress) -> KeyPress.Result {
        let command = press.modifiers == .command
        let option = press.modifiers == .option
        let key: QuickViewModel.ThreadKey
        switch press.key {
        case .pageUp: key = .pageUp
        case .pageDown: key = .pageDown
        case .upArrow: key = .up
        default: key = .down
        }
        let pages = key == .pageUp || key == .pageDown
        if pages || command || option {
            if viewModel.handleThreadKey(key, command: command, option: option) { return .handled }
            // Off the thread PageUp and PageDown are the field's; a modified
            // arrow moves a list as a plain one does.
            if pages { return .ignored }
        }
        return move(key == .up ? -1 : 1)
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        // The `/` palette has no field of its own: the draft is its search,
        // so the composer keeps the keyboard and these keys are routed here.
        if viewModel.isSlashCommandPalettePresented {
            viewModel.moveSlashCommandSelection(delta)
            return .handled
        }
        if viewModel.isTransformChooserPresented {
            viewModel.moveTransformChooserSelection(delta)
            return .handled
        }
        if viewModel.isModelChooserPresented {
            viewModel.moveModelChooserSelection(delta)
            return .handled
        }
        if viewModel.isAssistantChooserPresented {
            viewModel.moveAssistantChooserSelection(delta)
            return .handled
        }
        if viewModel.isCaptureChooserPresented {
            viewModel.moveCaptureChooserSelection(delta)
            return .handled
        }
        if viewModel.isAddContextMenuPresented {
            viewModel.moveAddContextSelection(delta)
            return .handled
        }
        if viewModel.isRecentChatsPresented {
            viewModel.moveRecentChatsSelection(delta)
            return .handled
        }
        // On the Quick AI surface ↑ on an empty composer recalls the last
        // question and ↓ does nothing; with text the keys are the field's.
        if viewModel.isQuickAIPresented {
            return viewModel.handleComposerArrow(delta) ? .handled : .ignored
        }
        guard !viewModel.launcherMatches.isEmpty else { return .ignored }
        viewModel.moveSelectionVertically(delta)
        return .handled
    }
}
