import SwiftUI

/// Settings pane for managing saved prompts (aliases) and the command prefix.
struct SavedPromptsEditor: View {
    @Bindable var viewModel: QuickViewModel
    @State private var selection: SavedPrompt.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quick Actions")
                    .font(.headline)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("Prefix:")
                    .foregroundStyle(.secondary)
                TextField("/", text: $viewModel.settings.savedPromptPrefix)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onChange(of: viewModel.settings.savedPromptPrefix) { _, newValue in
                        if newValue.isEmpty {
                            viewModel.settings.savedPromptPrefix = "/"
                        }
                        viewModel.settings.save()
                    }
                Text("Aliases use fuzzy matching. Type /eml, then Tab or Return, to run /email.")
                    .font(.system(size: 11))
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
                    .font(.system(size: 12, weight: .medium))
                TextEditor(text: bindingForPrompt(prompt.id))
                    .font(.system(size: 12))
                    .frame(minHeight: 76, maxHeight: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                Text("Use {selection} where the selected or typed text should appear. If omitted, the text is appended.")
                    .font(.system(size: 10))
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
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Picker("After running", selection: bindingForOutputBehavior(prompt.id)) {
                    ForEach(ActionOutputBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                ActionHotkeyRecorderView(hotkey: bindingForHotkey(prompt.id))
                if let conflict = viewModel.settings.actionHotkeyConflict(for: prompt.id) {
                    Text(conflict)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
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
                    viewModel.settings.savedPrompts = SavedPrompt.defaults
                    viewModel.settings.save()
                    NotificationCenter.default.post(name: .actionHotkeysChanged, object: nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
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
                if let index = viewModel.settings.savedPrompts.firstIndex(where: { $0.id == id }) {
                    viewModel.settings.savedPrompts[index].alias = newValue
                    viewModel.settings.save()
                }
            }
        )
    }

    private func bindingForPrompt(_ id: SavedPrompt.ID) -> Binding<String> {
        Binding(
            get: { viewModel.settings.savedPrompts.first(where: { $0.id == id })?.prompt ?? "" },
            set: { newValue in
                if let index = viewModel.settings.savedPrompts.firstIndex(where: { $0.id == id }) {
                    viewModel.settings.savedPrompts[index].prompt = newValue
                    viewModel.settings.save()
                }
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

    private func update(_ id: SavedPrompt.ID, mutation: (inout SavedPrompt) -> Void) {
        guard let index = viewModel.settings.savedPrompts.firstIndex(where: { $0.id == id }) else {
            return
        }
        mutation(&viewModel.settings.savedPrompts[index])
        viewModel.settings.save()
    }

    private func bindingForProvider(_ id: SavedPrompt.ID) -> Binding<UUID?> {
        Binding(
            get: { viewModel.settings.savedPrompts.first(where: { $0.id == id })?.providerID },
            set: { newValue in
                if let index = viewModel.settings.savedPrompts.firstIndex(where: { $0.id == id }) {
                    viewModel.settings.savedPrompts[index].providerID = newValue
                    viewModel.settings.savedPrompts[index].model = nil
                    viewModel.settings.save()
                }
            }
        )
    }

    private func bindingForModel(_ id: SavedPrompt.ID) -> Binding<String?> {
        Binding(
            get: { viewModel.settings.savedPrompts.first(where: { $0.id == id })?.model },
            set: { newValue in
                if let index = viewModel.settings.savedPrompts.firstIndex(where: { $0.id == id }) {
                    viewModel.settings.savedPrompts[index].model = newValue
                    viewModel.settings.save()
                }
            }
        )
    }

    private func modelsForPrompt(_ prompt: SavedPrompt) -> [String] {
        guard let providerID = prompt.providerID else { return [] }
        return viewModel.settings.providers.first(where: { $0.id == providerID })?.models ?? []
    }

    private func addRow() {
        let new = SavedPrompt(alias: "new", prompt: "Your prompt here.")
        viewModel.settings.savedPrompts.append(new)
        viewModel.settings.save()
        selection = new.id
    }

    private func removeSelected() {
        guard let selection else { return }
        viewModel.settings.savedPrompts.removeAll { $0.id == selection }
        viewModel.settings.save()
        NotificationCenter.default.post(name: .actionHotkeysChanged, object: nil)
        self.selection = nil
    }
}
