import AppKit
import SwiftUI

/// The Quick AI composer and what sits on it: an error that belongs to no
/// turn, the launch selection and attachment strips, and the composer row
/// (the Add Context circle, the pill field with the primary action inside
/// it, and the `⌘K` circle). One view for the Quick AI surface and the AI
/// Chat window. The window's field is multi-line: it grows with what is
/// typed, `↩` sends and `⇧↩` starts a new line, and Tab moves on to the
/// window's other controls.
///
/// With an attachment tray, `⌘V` of files, an image, or a lone link into an
/// empty field attaches them (`⌘Z` turns the link back into text), `⇧Tab`
/// moves into the chip strip, and in AI Chat the composer is a drop target.
struct QuickAIComposer: View {
    @Bindable var viewModel: QuickViewModel
    /// The tray the chips come from. Nil falls back to the environment's
    /// (`\.attachmentTray`); with neither, only the view model's own
    /// screenshots and context show as chips.
    var tray: AttachmentTray? = nil
    /// The AI Chat window's field grows to `AIChatWindowModel.composerLineLimit`
    /// lines; the Quick AI surface's stays one line.
    var multiline = false
    /// Tells the AI Chat window where the keyboard is.
    var onFocusChange: ((Bool) -> Void)? = nil
    @FocusState private var composerFocused: Bool
    @Environment(\.attachmentTray) private var environmentTray

    private var activeTray: AttachmentTray? { tray ?? environmentTray }

    /// The field's name. In the AI Chat window it is a message field, not
    /// "Ask Quick AI"; in Recent Chats it searches.
    static func fieldName(multiline: Bool, searchingChats: Bool) -> String {
        if searchingChats { return "Search chats" }
        return multiline ? "Message" : "Ask Quick AI"
    }

    /// Tab once the routing (an alias completing) passed on it. The single
    /// line surface has nothing to move to, so the key stays in the field;
    /// the AI Chat window's header, rail, and thread controls take it.
    static func tabResult(multiline: Bool) -> KeyPress.Result {
        multiline ? .ignored : .handled
    }

    /// Shift-Tab as AppKit reports it (backtab).
    static let backTab = KeyEquivalent("\u{19}")

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

    var body: some View {
        VStack(spacing: 0) {
            if let error = viewModel.errorMessage {
                errorLine(error)
            }
            // The strips read as rows; the surface has no hairlines.
            if viewModel.launchSelection != nil {
                LaunchSelectionStrip(viewModel: viewModel)
            }
            ComposerAttachmentStrip(viewModel: viewModel, tray: activeTray)
            composerRow
        }
        .background { pasteShortcuts }
        // Quick AI's whole surface is the drop target (OverlayView); in the
        // AI Chat window it is the composer.
        .attachmentDropTarget(multiline ? activeTray : nil, coversContent: true)
        .onAppear { focusComposer() }
        .onChange(of: viewModel.inputFocusRequest) { _, _ in focusComposer() }
        .onChange(of: composerFocused) { _, focused in onFocusChange?(focused) }
    }

    private var composerRow: some View {
        let action = viewModel.quickAIComposerAction
        // The circles sit on the field's last line as it grows.
        return HStack(alignment: .bottom, spacing: House.Spacing.xs) {
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
            .help(
                activeTray == nil
                    ? "Add context: a window, a selection, an area, or a screen (or type @)"
                    : "Add context: a window, a selection, a screen, a file, or a link (or type @)"
            )

            HStack(spacing: House.Spacing.xs) {
                // The placeholder is drawn as an overlay, not as the field's
                // prompt: a styled prompt takes the field's ink on macOS and
                // read as typed text. The empty prompt keeps the field from
                // drawing its label as a placeholder under the overlay.
                TextField(
                    text: $viewModel.input,
                    prompt: Text(""),
                    axis: multiline ? .vertical : .horizontal
                ) {
                    Text(Self.fieldName(multiline: multiline, searchingChats: false))
                }
                .lineLimit(multiline ? 1...AIChatWindowModel.composerLineLimit : 1...1)
                .textFieldStyle(.plain)
                .labelsHidden()
                // Raycast's field runs at the small reading size, the same
                // as its action label, not the launcher's 16.
                .font(AQDesign.TypeToken.body)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
                .frame(maxWidth: .infinity)
                .overlay(alignment: multiline ? .topLeading : .leading) {
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
                // An alias completes through the routing above. Otherwise
                // `⇧Tab` moves into the chip strip, and Tab stays in the
                // one-line field (nothing to move to) or, in the AI Chat
                // window, moves on to the window's other controls.
                .onKeyPress(keys: [.tab, Self.backTab], phases: .down) { press in
                    tabKey(press)
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .delete, .space, .escape], phases: [.down, .repeat]) { press in
                    stripKey(press)
                }
                .onChange(of: viewModel.input) { _, newValue in
                    // Recent Chats filters on it; elsewhere a typed `@`
                    // opens the same Add Context menu the circle does.
                    viewModel.quickAIComposerDidChange(newValue)
                    activeTray?.composerTextDidChange(newValue)
                }
                .accessibilityLabel(
                    Self.fieldName(multiline: multiline, searchingChats: viewModel.isRecentChatsPresented)
                )
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
            // One line is the pill; a multi-line field grows from it, the
            // text inset as the pill centres one line.
            .padding(.vertical, multiline ? Self.multilineTextInset : 0)
            .frame(minHeight: House.Control.pill, maxHeight: multiline ? nil : House.Control.pill)
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
                QuickAIAnnouncement.post(confirmation, priority: .medium)
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

    /// Above and below the text of a multi-line field: what centres one
    /// line of `body` text in the pill's height.
    static let multilineTextInset: CGFloat = {
        let font = NSFont.systemFont(ofSize: House.TypeToken.Size.bodySmall)
        let line = font.ascender - font.descender + font.leading
        return max(0, (House.Control.pill - line) / 2)
    }()

    /// The composer field's capsule.
    private static var fieldShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: House.Radius.pill, style: .circular)
    }

    private func focusComposer() {
        FocusRequest.apply($composerFocused)
    }

    // MARK: - Keys

    private func tabKey(_ press: KeyPress) -> KeyPress.Result {
        let isBackTab = press.key == Self.backTab || press.modifiers.contains(.shift)
        if isBackTab, let tray = activeTray, tray.enterStrip() { return .handled }
        return Self.tabResult(multiline: multiline)
    }

    /// `←` `→` Backspace Space `esc` while a chip in the strip has the keys.
    private func stripKey(_ press: KeyPress) -> KeyPress.Result {
        guard let tray = activeTray, tray.isStripFocused else { return .ignored }
        switch press.key {
        case .leftArrow: tray.moveFocus(-1)
        case .rightArrow: tray.moveFocus(1)
        case .delete: tray.handleBackspace(composerIsEmpty: viewModel.input.isEmpty)
        case .space:
            if let url = tray.focusedFileURL { AttachmentQuickLook.shared.preview(url) }
        default: tray.leaveStrip()
        }
        return .handled
    }

    // MARK: - Paste

    /// `⌘V` and the link paste's `⌘Z`, as window shortcuts, so they are
    /// seen before the field pastes. A paste that is not an attachment, or
    /// one while another field has the keys, goes on to the field as text.
    @ViewBuilder
    private var pasteShortcuts: some View {
        if let tray = activeTray {
            ZStack {
                Button("Paste") { paste(into: tray) }
                    .keyboardShortcut("v", modifiers: .command)
                Button("Undo Link") { undoLinkPaste(tray) }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!tray.canUndoPastedLink || !composerFocused)
            }
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// `⌘V` attaches only while the field asks a question: in Recent
    /// Chats it searches, and while a chat is renamed it holds the name.
    static func pasteAttaches(composerFocused: Bool, searchingChats: Bool, typingMode: Bool) -> Bool {
        composerFocused && !searchingChats && !typingMode
    }

    private func paste(into tray: AttachmentTray) {
        guard Self.pasteAttaches(
                composerFocused: composerFocused,
                searchingChats: viewModel.isRecentChatsPresented,
                typingMode: viewModel.inputMode != nil
              ),
              tray.paste(AttachmentPasteboardReader.read(), composerText: viewModel.input)
        else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            return
        }
        viewModel.requestInputFocus()
    }

    private func undoLinkPaste(_ tray: AttachmentTray) {
        guard let text = tray.undoPastedLink() else { return }
        viewModel.input = text
    }
}
