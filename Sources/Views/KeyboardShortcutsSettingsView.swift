import SwiftUI

/// Settings › Keyboard Shortcuts.
///
/// Three cards: the keys you can rebind, the keys that stay fixed, and the
/// global hotkeys (which are set elsewhere). Every row's caps and every
/// conflict message comes from `ShortcutBindings`, the same table the key
/// routers, the footer hints, and the `⌘K` rows read, so what this pane shows
/// is what the app does.
struct KeyboardShortcutsSettingsView: View {
    @Bindable var viewModel: QuickViewModel

    /// The rows never offer Clear. A shortcut always has a key (its built-in
    /// one), so Clear could only mean Reset and would read as if the action
    /// could be left unbound. The Reset button beside the recorder is the one
    /// affordance, and it says what it does.
    static let recorderAllowsClear = false

    var body: some View {
        SettingsPaneScroller(pane: .keyboard) {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                actionsCard.settingsAnchor("keyboard.actions")
                fixedCard.settingsAnchor("keyboard.fixed")
                globalCard.settingsAnchor("keyboard.global")
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, House.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Rebindable

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
            ForEach(ShortcutGroup.allCases) { group in
                SettingsCard(group.title) {
                    CardNote(isFirst: true) {
                        CardText(group.detail)
                    }
                    ForEach(group.actions) { action in
                        ShortcutRow(viewModel: viewModel, action: action)
                    }
                }
            }
            SettingsCard {
                CardNote(isFirst: true) {
                    HStack(spacing: House.Spacing.sm) {
                        CardText(
                            viewModel.settings.customizedShortcuts.isEmpty
                                ? "Every shortcut is at its built-in key. Click a key to record another; it applies at once."
                                : "\(viewModel.settings.customizedShortcuts.count) shortcut\(viewModel.settings.customizedShortcuts.count == 1 ? "" : "s") changed. Reset puts the built-in key back."
                        )
                        Spacer(minLength: House.Spacing.sm)
                        if !viewModel.settings.customizedShortcuts.isEmpty {
                            Button("Reset All") { viewModel.resetAllShortcuts() }
                                .buttonStyle(.plain)
                                .font(AQDesign.TypeToken.metadata)
                                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Fixed

    private var fixedCard: some View {
        SettingsCard("Fixed Keys") {
            CardNote(isFirst: true) {
                CardText(
                    "These stay where they are. A rebind above may not take one of them."
                )
            }
            ForEach(ReservedShortcut.all, id: \.hotkey) { reserved in
                SettingsRow(title: reserved.label, detail: reserved.scope.label) {
                    KeyCapGroup(keys: reserved.hotkey.keyCaps)
                }
            }
        }
    }

    // MARK: - Global

    private var globalCard: some View {
        SettingsCard("Global Hotkeys") {
            CardNote(isFirst: true) {
                CardText(
                    "These work system-wide, in every app, so they live with the rest of the system settings: Quick Launch, Clipboard History, the Translator, and Type to Click are in General. A launcher item's hotkey is in Items; a quick action's is in AI Commands."
                )
            }
            GlobalHotkeyRow(title: "Open Quick Launch", caps: launcherCaps, isFirst: false)
            GlobalHotkeyRow(title: "Clipboard History", caps: viewModel.settings.clipboardHistoryHotkey.keyCaps)
            GlobalHotkeyRow(title: "Open Translator", caps: viewModel.settings.translatorHotkey.keyCaps)
            if viewModel.settings.typeToClickHotkeyEnabled {
                GlobalHotkeyRow(title: "Type to Click", caps: viewModel.settings.typeToClickHotkey.keyCaps)
            }
            CardNote {
                CardText(
                    "The in-app keys above only act while Quick Launch or its chat window has the keyboard. A global hotkey and an in-app key cannot share a combination."
                )
            }
        }
    }

    private var launcherCaps: [String] {
        ActionHotkey(
            keyCode: viewModel.settings.hotkeyKeyCode,
            modifiers: viewModel.settings.hotkeyModifiers
        ).keyCaps
    }
}

/// One rebindable shortcut: its name, what it does, its key caps, and the
/// collision message when a key is refused.
private struct ShortcutRow: View {
    @Bindable var viewModel: QuickViewModel
    let action: ShortcutAction
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(title: action.title, detail: action.detail) {
                HStack(spacing: House.Spacing.sm) {
                    if viewModel.settings.isShortcutCustomized(action) {
                        Button("Reset") {
                            error = nil
                            viewModel.resetShortcut(action)
                        }
                        .buttonStyle(.plain)
                        .font(AQDesign.TypeToken.metadata)
                        .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        .help("Back to the built-in key")
                    }
                    ActionHotkeyRecorderView(
                        hotkey: binding,
                        label: action.title,
                        showsLabel: false,
                        allowsClear: KeyboardShortcutsSettingsView.recorderAllowsClear,
                        changeNotification: .shortcutBindingsChanged
                    )
                }
            }
            if let error {
                CardNote { CardText(error, tone: AQDesign.ColorToken.danger) }
            }
        }
    }

    /// The value shown is always the resolved key, so a shortcut at its
    /// built-in key still shows its caps. Recording a new key writes an
    /// override; recording the built-in key again, or Clear, removes it.
    private var binding: Binding<ActionHotkey?> {
        Binding(
            get: { viewModel.settings.shortcutHotkey(for: action) },
            set: { hotkey in
                error = viewModel.setShortcut(hotkey, for: action)
            }
        )
    }
}

/// One read-only global hotkey row.
private struct GlobalHotkeyRow: View {
    let title: String
    let caps: [String]
    var isFirst: Bool = false

    var body: some View {
        SettingsRow(title: title, isFirst: isFirst) {
            HStack(spacing: House.Spacing.sm) {
                KeyCapGroup(keys: caps)
                Text("System-wide")
                    .font(AQDesign.TypeToken.metadata)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
            }
        }
    }
}
