import SwiftUI

/// Settings pane for managing saved prompts (aliases) and the command prefix.
struct SavedPromptsEditor: View {
    @Bindable var viewModel: QuickViewModel
    @State private var selection: SavedPrompt.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI Commands")
                    .font(AQDesign.TypeToken.heading)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("Prefix:")
                    .foregroundStyle(.secondary)
                TextField(
                    "/",
                    text: viewModel.settingsBinding(
                        get: { $0.savedPromptPrefix },
                        set: { settings, value in settings.savedPromptPrefix = value.isEmpty ? "/" : value }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                Text("Aliases use fuzzy matching. Type /eml, then Tab or Return, to run /email.")
                    .font(AQDesign.TypeToken.hint)
                    .foregroundStyle(.secondary)
            }

            Table(viewModel.settings.savedPrompts, selection: $selection) {
                TableColumn("Name") { prompt in
                    TextField(
                        "Action name",
                        text: bindingForName(prompt.id)
                    )
                    .textFieldStyle(.plain)
                }
                .width(min: 100, max: 170)
                TableColumn("Alias") { prompt in
                    TextField(
                        "alias",
                        text: bindingForAlias(prompt.id)
                    )
                    .textFieldStyle(.plain)
                }
                .width(min: 80, max: 140)
            }
            .frame(minHeight: 180)

            if let selection,
               let prompt = viewModel.settings.savedPrompts.first(where: { $0.id == selection }) {
                Divider()
                Text("Prompt")
                    .font(AQDesign.TypeToken.label)
                TextEditor(text: bindingForPrompt(prompt.id))
                    .font(AQDesign.TypeToken.detail)
                    .frame(minHeight: 76, maxHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: AQDesign.fieldCornerRadius)
                            .stroke(AQDesign.ColorToken.fieldStroke)
                    )
                Text("Use {selection} where the selected or typed text should appear. If omitted, the text is appended.")
                    .font(AQDesign.TypeToken.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text("Command:")
                        .foregroundStyle(.secondary)
                    TextField(
                        "Executable, e.g. recall",
                        text: bindingForCommandExecutable(prompt.id)
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    TextField(
                        "Arguments, e.g. search {input}",
                        text: bindingForCommandArguments(prompt.id)
                    )
                    .textFieldStyle(.roundedBorder)
                }
                Text("Optional. With an executable set, the action runs it directly (no shell) instead of a model. {input} inserts the typed text as one argument.")
                    .font(AQDesign.TypeToken.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Picker("Provider", selection: bindingForProvider(prompt.id)) {
                        Text("Current provider").tag(nil as UUID?)
                        ForEach(viewModel.settings.providers) { provider in
                            Text(provider.name).tag(provider.id as UUID?)
                        }
                    }
                    .frame(maxWidth: 260)

                    Picker("Model", selection: bindingForModel(prompt.id)) {
                        Text("Provider default").tag(nil as String?)
                        ForEach(modelsForPrompt(prompt), id: \.self) { model in
                            Text(model).tag(model as String?)
                        }
                    }
                    .frame(maxWidth: 260)
                    .disabled(prompt.providerID == nil)
                }
                Text("Pin this action to a provider and model, or let it use the current choice.")
                    .font(AQDesign.TypeToken.hint)
                    .foregroundStyle(.secondary)

                Picker("After running", selection: bindingForOutputBehavior(prompt.id)) {
                    ForEach(ActionOutputBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                ActionHotkeyRecorderView(hotkey: bindingForHotkey(prompt.id))
                if let conflict = viewModel.settings.actionHotkeyConflict(for: prompt.id) {
                    Text(conflict)
                        .font(AQDesign.TypeToken.footnote)
                        .foregroundStyle(AQDesign.ColorToken.danger)
                }
            }

            HStack {
                Button {
                    addRow()
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    removeSelected()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                Spacer()
                Button("Restore defaults") {
                    viewModel.updateSettings { $0.savedPrompts = SavedPrompt.defaults }
                    NotificationCenter.default.post(name: .actionHotkeysChanged, object: nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(AQDesign.TypeToken.hint)
            }
        }
    }

    private func bindingForName(_ id: SavedPrompt.ID) -> Binding<String> {
        Binding(
            get: { viewModel.settings.savedPrompts.first(where: { $0.id == id })?.name ?? "" },
            set: { newValue in
                update(id) { $0.name = newValue }
            }
        )
    }

    private func bindingForAlias(_ id: SavedPrompt.ID) -> Binding<String> {
        Binding(
            get: { viewModel.settings.savedPrompts.first(where: { $0.id == id })?.alias ?? "" },
            set: { newValue in
                update(id) { $0.alias = newValue }
            }
        )
    }

    private func bindingForPrompt(_ id: SavedPrompt.ID) -> Binding<String> {
        Binding(
            get: { viewModel.settings.savedPrompts.first(where: { $0.id == id })?.prompt ?? "" },
            set: { newValue in
                update(id) { $0.prompt = newValue }
            }
        )
    }

    private func bindingForOutputBehavior(_ id: SavedPrompt.ID) -> Binding<ActionOutputBehavior> {
        Binding(
            get: {
                viewModel.settings.savedPrompts.first(where: { $0.id == id })?.outputBehavior
                    ?? .showInOverlay
            },
            set: { newValue in
                update(id) { $0.outputBehavior = newValue }
            }
        )
    }

    private func bindingForHotkey(_ id: SavedPrompt.ID) -> Binding<ActionHotkey?> {
        Binding(
            get: { viewModel.settings.savedPrompts.first(where: { $0.id == id })?.hotkey },
            set: { newValue in
                update(id) { $0.hotkey = newValue }
            }
        )
    }

    private func bindingForCommandExecutable(_ id: SavedPrompt.ID) -> Binding<String> {
        Binding(
            get: {
                viewModel.settings.savedPrompts.first(where: { $0.id == id })?
                    .commandExecutable ?? ""
            },
            set: { newValue in
                update(id) {
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    $0.commandExecutable = trimmed.isEmpty ? nil : trimmed
                }
            }
        )
    }

    private func bindingForCommandArguments(_ id: SavedPrompt.ID) -> Binding<String> {
        Binding(
            get: {
                viewModel.settings.savedPrompts.first(where: { $0.id == id })?
                    .commandArguments?.joined(separator: " ") ?? ""
            },
            set: { newValue in
                update(id) {
                    let parts = newValue
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                    $0.commandArguments = parts.isEmpty ? nil : parts
                }
            }
        )
    }

    private func update(_ id: SavedPrompt.ID, mutation: (inout SavedPrompt) -> Void) {
        guard let index = viewModel.settings.savedPrompts.firstIndex(where: { $0.id == id }) else {
            return
        }
        viewModel.updateSettings { mutation(&$0.savedPrompts[index]) }
    }

    private func bindingForProvider(_ id: SavedPrompt.ID) -> Binding<UUID?> {
        Binding(
            get: { viewModel.settings.savedPrompts.first(where: { $0.id == id })?.providerID },
            set: { newValue in
                update(id) {
                    $0.providerID = newValue
                    $0.model = nil
                }
            }
        )
    }

    private func bindingForModel(_ id: SavedPrompt.ID) -> Binding<String?> {
        Binding(
            get: { viewModel.settings.savedPrompts.first(where: { $0.id == id })?.model },
            set: { newValue in
                update(id) { $0.model = newValue }
            }
        )
    }

    private func modelsForPrompt(_ prompt: SavedPrompt) -> [String] {
        guard let providerID = prompt.providerID else { return [] }
        return viewModel.settings.providers.first(where: { $0.id == providerID })?.models ?? []
    }

    private func addRow() {
        let new = SavedPrompt(alias: "new", prompt: "Your prompt here.")
        viewModel.updateSettings { $0.savedPrompts.append(new) }
        selection = new.id
    }

    private func removeSelected() {
        guard let selection else { return }
        viewModel.updateSettings { $0.savedPrompts.removeAll { $0.id == selection } }
        NotificationCenter.default.post(name: .actionHotkeysChanged, object: nil)
        self.selection = nil
    }
}
