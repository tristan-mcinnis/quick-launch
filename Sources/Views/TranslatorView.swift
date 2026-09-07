import AppKit
import SwiftUI

/// Its own window: source text above, translation below, the target language
/// on the right, the keys in the footer. Same tokens as the launcher.
struct TranslatorView: View {
    @Bindable var model: TranslatorModel
    @FocusState private var sourceFocused: Bool
    @FocusState private var pickerFocused: Bool
    @State private var pickerIndex = 0

    static let size = NSSize(width: 680, height: 520)

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, AQDesign.Space.panel)
                .frame(height: House.Control.xlarge)
            HouseDivider()
            if model.isTargetPickerPresented {
                targetPicker
            } else {
                panes
            }
            FooterWell { footer }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .panelGlass()
        .onAppear { focusSource() }
        .onChange(of: model.isTargetPickerPresented) { _, presented in
            if presented { focusPicker() } else { focusSource() }
        }
    }

    private var header: some View {
        HStack(spacing: AQDesign.Space.row) {
            Image(systemName: "character.bubble")
                .font(AQDesign.TypeToken.glyph)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .accessibilityHidden(true)
            Text("Translate")
                .font(AQDesign.TypeToken.subheading)
                .foregroundStyle(AQDesign.ColorToken.textPrimary)
            if let detected = model.detectedSource {
                Text("from \(detected.title)")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
            }
            Spacer()
            if model.isTranslating {
                ThinkingIndicator().frame(width: 18, height: 18)
            }
            Button {
                model.isTargetPickerPresented.toggle()
            } label: {
                HStack(spacing: AQDesign.Space.standard) {
                    Text("to \(model.target.title)")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    KeyCapGroup(keys: ["⌘", "P"])
                }
                .padding(.horizontal, AQDesign.Space.standard)
                .frame(height: House.Control.chip)
                .background(
                    RoundedRectangle(
                        cornerRadius: AQDesign.fieldCornerRadius,
                        style: .continuous
                    )
                    .fill(AQDesign.ColorToken.chipFill)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change target language (⌘P)")
        }
    }

    private var panes: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
                HStack {
                    SectionLabel(text: "Source")
                    Spacer()
                    if model.hasRetainedSelection {
                        Button {
                            model.useRetainedSelection()
                        } label: {
                            HStack(spacing: AQDesign.Space.compact) {
                                Image(systemName: "text.cursor")
                                Text("Use selected text")
                            }
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Import the text that was selected when Quick Launch opened")
                    }
                    Text("\(model.source.count) characters")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.textTertiary)
                }
                TextEditor(text: $model.source)
                    .font(AQDesign.TypeToken.prose)
                    .scrollContentBackground(.hidden)
                    .focused($sourceFocused)
                    .onChange(of: model.source) { _, _ in model.sourceChanged() }
                    .overlay(alignment: .topLeading) {
                        if model.source.isEmpty {
                            Text("Type or paste text. ⌘⇧V uses the clipboard.")
                                .font(AQDesign.TypeToken.prose)
                                .foregroundStyle(AQDesign.ColorToken.textTertiary)
                                // Not spacing: these two match NSTextView's own
                                // text-container inset so the placeholder sits
                                // exactly where the typed glyphs will.
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.vertical, AQDesign.Space.row)
            .frame(maxHeight: .infinity)

            HouseDivider()

            VStack(alignment: .leading, spacing: AQDesign.Space.compact) {
                HStack {
                    SectionLabel(text: model.target.title)
                    Spacer()
                    if let message = model.message {
                        Text(message)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                            .lineLimit(1)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
                        Text(model.translation.isEmpty && !model.isTranslating ? " " : model.translation)
                            .font(AQDesign.TypeToken.input)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let pinyin = model.pinyin, !pinyin.isEmpty {
                            HouseDivider()
                            Text(pinyin)
                                .font(AQDesign.TypeToken.detail)
                                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .padding(.vertical, AQDesign.Space.row)
            .frame(maxHeight: .infinity)
        }
    }

    private var targetPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Image(systemName: "magnifyingglass")
                    .font(AQDesign.TypeToken.glyph)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityHidden(true)
                TextField("Type a language", text: $model.targetQuery)
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.input)
                    .focused($pickerFocused)
                    .onSubmit { choose(pickerIndex) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onChange(of: model.targetQuery) { _, _ in pickerIndex = 0 }
                KeyCapGroup(keys: ["esc"])
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .frame(height: AQDesign.inputHeight)
            HouseDivider()
            SelectableListPane(
                items: model.filteredTargets,
                selectedIndex: $pickerIndex,
                rowSpacing: PanelSizing.actionRowSpacing,
                rowHeight: AQDesign.rowHeight,
                listInsets: EdgeInsets(
                    top: AQDesign.Space.standard,
                    leading: AQDesign.Space.standard,
                    bottom: AQDesign.Space.standard,
                    trailing: AQDesign.Space.standard
                ),
                onActivate: { target in model.setTarget(target) }
            ) { _, item, _ in
                HStack(spacing: AQDesign.Space.row) {
                    IconTile {
                        Image(systemName: "globe")
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    }
                    Text(item.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    Spacer()
                    if item == model.target {
                        Image(systemName: "checkmark")
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    }
                }
                .padding(.horizontal, AQDesign.Space.row)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: AQDesign.Space.row) {
            StatusDot(color: model.isTranslating
                ? AQDesign.ColorToken.warning
                : AQDesign.ColorToken.success)
            Text(model.isTargetPickerPresented ? "Target Language" : "Translator")
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
            Spacer(minLength: AQDesign.Space.row)
            if model.isTargetPickerPresented {
                FooterHintView(label: "Choose", keys: ["↩"])
                FooterHintView(label: "Back", keys: ["esc"])
            } else {
                FooterHintView(label: "Copy", keys: ["⌘", "↩"])
                FooterHintView(label: "Paste back", keys: ["⇧", "⌘", "↩"])
                FooterHintView(label: "Swap", keys: ["⌘", "S"])
                FooterHintView(label: "Target", keys: ["⌘", "P"])
                FooterHintView(label: "Close", keys: ["esc"])
            }
        }
    }

    private func move(_ delta: Int) {
        pickerIndex = ListSelection.wrappedIndex(
            pickerIndex, by: delta, count: model.filteredTargets.count
        )
    }

    private func choose(_ index: Int) {
        let targets = model.filteredTargets
        guard targets.indices.contains(index) else { return }
        model.setTarget(targets[index])
    }

    private func focusSource() {
        FocusRequest.apply($sourceFocused)
    }

    private func focusPicker() {
        FocusRequest.apply($pickerFocused)
    }
}

/// One "Label ⌘K" pair for footers outside the launcher: the house `KeyHint`,
/// under the name this window and its tests already use.
struct FooterHintView: View {
    let label: String
    let keys: [String]

    var body: some View {
        KeyHint(label: label, keys: keys)
    }
}

/// The translator's window: borderless, key-able, routes its shortcuts.
final class TranslatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘↩ copy, ⇧⌘↩ paste back, ⌘S swap, ⌘P target, ⇧⌘V clipboard, esc.
    var shortcutHandler: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        if event.type == .keyDown,
           shortcutHandler?(event.charactersIgnoringModifiers, event.keyCode, modifiers) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        _ = shortcutHandler?(nil, 53, [])
    }
}
