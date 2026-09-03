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
                .padding(.horizontal, 20)
                .frame(height: 48)
            Divider()
            if model.isTargetPickerPresented {
                targetPicker
            } else {
                panes
            }
            Divider()
            footer
                .padding(.horizontal, 20)
                .frame(height: AQDesign.footerHeight)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                AQDesign.ColorToken.panelTint
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AQDesign.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: AQDesign.cornerRadius)
                .strokeBorder(AQDesign.ColorToken.panelStroke, lineWidth: 1)
        )
        .onAppear { focusSource() }
        .onChange(of: model.isTargetPickerPresented) { _, presented in
            if presented { focusPicker() } else { focusSource() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.bubble")
                .foregroundStyle(AQDesign.ColorToken.emphasis)
            Text("Translate")
                .font(AQDesign.TypeToken.body.weight(.semibold))
            if let detected = model.detectedSource {
                Text("from \(detected.title)")
                    .font(AQDesign.TypeToken.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isTranslating {
                ThinkingIndicator().frame(width: 18, height: 18)
            }
            Button {
                model.isTargetPickerPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("to \(model.target.title)")
                        .font(AQDesign.TypeToken.label)
                    KeyCapGroup(keys: ["⌘", "P"])
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(AQDesign.ColorToken.keyCapFill))
            }
            .buttonStyle(.plain)
            .help("Change target language (⌘P)")
        }
    }

    private var panes: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Source")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.source.count) characters")
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(.tertiary)
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
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.target.title)
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let message = model.message {
                        Text(message)
                            .font(AQDesign.TypeToken.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.translation.isEmpty && !model.isTranslating ? " " : model.translation)
                            .font(AQDesign.TypeToken.input)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let pinyin = model.pinyin, !pinyin.isEmpty {
                            Divider()
                            Text(pinyin)
                                .font(AQDesign.TypeToken.detail)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity)
        }
    }

    private var targetPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a language", text: $model.targetQuery)
                    .textFieldStyle(.plain)
                    .font(AQDesign.TypeToken.body)
                    .focused($pickerFocused)
                    .onSubmit { choose(pickerIndex) }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onChange(of: model.targetQuery) { _, _ in pickerIndex = 0 }
                KeyCapGroup(keys: ["esc"])
            }
            .padding(.horizontal, 20)
            .frame(height: PanelSizing.paneHeaderHeight)
            Divider()
            SelectableListPane(
                items: model.filteredTargets,
                selectedIndex: $pickerIndex,
                rowSpacing: 2,
                rowHeight: 36,
                listInsets: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8),
                onActivate: { target in model.setTarget(target) }
            ) { _, item, _ in
                HStack {
                    Text(item.title).font(AQDesign.TypeToken.body.weight(.medium))
                    Spacer()
                    if item == model.target {
                        Image(systemName: "checkmark").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(model.isTargetPickerPresented ? "Target Language" : "Translator")
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(.secondary)
            Spacer()
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

/// One "Label ⌘K" pair for footers outside the launcher.
struct FooterHintView: View {
    let label: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(.secondary)
            KeyCapGroup(keys: keys)
        }
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
