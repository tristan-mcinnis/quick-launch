import AppKit
import SwiftUI
import HouseDesign

/// Its own window: source text above, translation below, the source and
/// target languages on the right with Swap between them, the keys in the
/// footer. Same tokens as the launcher, and the
/// launcher footer's strip: status dot and context, then `KeyHint`s. Every
/// key it names comes from `TranslatorKey`.
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
            if model.languagePicker != nil {
                languagePicker
            } else {
                panes
            }
            FooterWell { footer }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .panelGlass()
        .task(id: model.sourceFocusRevision) {
            sourceFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            sourceFocused = true
        }
        .onChange(of: model.languagePicker) { _, side in
            pickerIndex = 0
            if side != nil { focusPicker() } else { focusSource() }
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
            Spacer()
            if model.isTranslating {
                ThinkingIndicator().frame(width: 18, height: 18)
            }
            languageChip("from \(sourceChipTitle)", key: .source, help: TranslatorKey.sourceHelp) {
                model.toggleLanguagePicker(.source)
            }
            Button {
                model.swap()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .frame(width: House.Control.chip, height: House.Control.chip)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(TranslatorKey.swapHelp)
            .accessibilityLabel("Swap languages")
            languageChip("to \(model.target.title)", key: .target, help: TranslatorKey.targetHelp) {
                model.toggleLanguagePicker(.target)
            }
        }
    }

    /// Auto names the language it found once a request has run.
    private var sourceChipTitle: String {
        switch model.sourceSelection {
        case .auto: model.detectedSource.map { "\($0.title) · auto" } ?? "Auto detect"
        case .fixed(let language): language.title
        }
    }

    private func languageChip(
        _ title: String,
        key: TranslatorKey,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AQDesign.Space.standard) {
                Text(title)
                    .font(AQDesign.TypeToken.label)
                    .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    .lineLimit(1)
                KeyCapGroup(keys: key.shortcut.keyCaps)
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
        .help(help)
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
                TextEditor(text: $model.sourceInput)
                    .font(AQDesign.TypeToken.prose)
                    .scrollContentBackground(.hidden)
                    .focused($sourceFocused)
                    .accessibilityLabel("Source text")
                    .overlay(alignment: .topLeading) {
                        if model.source.isEmpty {
                            Text(TranslatorKey.sourcePlaceholder)
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

    private var languagePicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: AQDesign.Space.row) {
                Image(systemName: "magnifyingglass")
                    .font(AQDesign.TypeToken.glyph)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                    .accessibilityHidden(true)
                TextField("Type a language", text: $model.pickerQuery)
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.input)
                    .focused($pickerFocused)
                    .onSubmit { choose(pickerIndex) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onChange(of: model.pickerQuery) { _, _ in pickerIndex = 0 }
                KeyCapGroup(keys: ["esc"])
            }
            .padding(.horizontal, AQDesign.Space.panel)
            .frame(height: AQDesign.inputHeight)
            HouseDivider()
            SelectableListPane(
                items: model.pickerOptions,
                selectedIndex: $pickerIndex,
                rowSpacing: PanelSizing.actionRowSpacing,
                rowHeight: AQDesign.rowHeight,
                listInsets: EdgeInsets(
                    top: AQDesign.Space.standard,
                    leading: AQDesign.Space.standard,
                    bottom: AQDesign.Space.standard,
                    trailing: AQDesign.Space.standard
                ),
                onActivate: { option in model.choosePickerOption(option) }
            ) { _, item, _ in
                HStack(spacing: AQDesign.Space.row) {
                    IconTile {
                        Image(systemName: item == .auto ? "wand.and.stars" : "globe")
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    }
                    Text(item.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    Spacer()
                    if item == model.pickerSelection {
                        Image(systemName: "checkmark")
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    }
                }
                .padding(.horizontal, AQDesign.Space.row)
            }
        }
    }

    /// The launcher footer's strip, token for token: the status dot and its
    /// context on the left, the shared `KeyHint`s on the right.
    private var footer: some View {
        HStack(spacing: AQDesign.Space.row) {
            StatusDot(color: model.isTranslating
                ? AQDesign.ColorToken.warning
                : AQDesign.ColorToken.success)
            Text(model.footerContext)
                .font(AQDesign.TypeToken.metadata)
                .foregroundStyle(AQDesign.ColorToken.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: AQDesign.Space.row)
            HStack(spacing: AQDesign.Space.row) {
                ForEach(model.footerHints, id: \.label) { hint in
                    KeyHint(label: hint.label, keys: hint.keys)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func move(_ delta: Int) {
        pickerIndex = ListSelection.wrappedIndex(
            pickerIndex, by: delta, count: model.pickerOptions.count
        )
    }

    private func choose(_ index: Int) {
        let options = model.pickerOptions
        guard options.indices.contains(index) else { return }
        model.choosePickerOption(options[index])
    }

    private func focusSource() {
        FocusRequest.apply($sourceFocused)
    }

    private func focusPicker() {
        FocusRequest.apply($pickerFocused)
    }
}

/// The translator's window: borderless, key-able, routes its shortcuts.
final class TranslatorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The `TranslatorKey` table (⌘↩ copy, ⇧⌘↩ paste back, ⌘S swap, ⌘F
    /// source, ⌘T target, ⇧⌘V clipboard, ⌘W close) and esc.
    var shortcutHandler: ((String?, UInt16, NSEvent.ModifierFlags) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        if event.type == .keyDown,
           shortcutHandler?(event.charactersIgnoringModifiers, event.keyCode, modifiers) == true {
            return true
        }
        // Accessory apps do not always have an Edit menu installed. Route
        // native editing directly so selection and paste work on every reopen.
        if event.type == .keyDown, modifiers == [.command],
           let editor = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil)
            case "c": editor.copy(nil)
            case "v" where editor.isEditable: editor.paste(nil)
            case "x" where editor.isEditable: editor.cut(nil)
            case "z" where editor.isEditable: editor.undoManager?.undo()
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        _ = shortcutHandler?(nil, 53, [])
    }
}
