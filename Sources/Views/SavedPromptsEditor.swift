import SwiftUI

/// Settings pane for managing saved prompts (aliases) and the command prefix.
/// The list and the editor for the selected command are two cards.
struct SavedPromptsEditor: View {
    @Bindable var viewModel: QuickViewModel
    @State private var selection: SavedPrompt.ID?

    /// The shared model profiles. A parameter would be better, but this pane
    /// is built by `SettingsView`, which owns the pane list.
    private var preferences: ModelPreferenceStore { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.cardGap) {
                commandsCard
                if let selection,
                   let prompt = viewModel.settings.savedPrompts.first(where: { $0.id == selection }) {
                    detailCard(prompt)
                }
            }
            .padding(.horizontal, SettingsMetrics.paneInset)
            .padding(.bottom, House.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var commandsCard: some View {
        SettingsCard("Commands") {
            SettingsRow(title: "Prefix", isFirst: true) {
                TextField(
                    "/",
                    text: viewModel.settingsBinding(
                        get: { $0.savedPromptPrefix },
                        set: { settings, value in settings.savedPromptPrefix = value.isEmpty ? "/" : value }
                    )
                )
                .textFieldStyle(.plain)
                .font(AQDesign.TypeToken.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AQDesign.Space.standard)
                .frame(width: 60, height: House.Control.compact)
                .background(fieldBackground)
                .accessibilityLabel("Prefix")
            }

            CardNote {
                CardText("Aliases use fuzzy matching. Type /eml, then Tab or Return, to run /email.")
            }

            CardNote {
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
            }

            CardNote {
                HStack(spacing: AQDesign.Space.standard) {
                    Button {
                        addRow()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add command")
                    Button {
                        removeSelected()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil)
                    .accessibilityLabel("Remove command")
                    Spacer(minLength: House.Spacing.sm)
                    Button("Restore defaults") {
                        viewModel.updateSettings { $0.savedPrompts = SavedPrompt.defaults }
                        NotificationCenter.default.post(name: .actionHotkeysChanged, object: nil)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AQDesign.ColorToken.textSecondary)
                    .font(AQDesign.TypeToken.metadata)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func detailCard(_ prompt: SavedPrompt) -> some View {
        SettingsCard("Selected command") {
            CardNote(isFirst: true) {
                VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
                    Text("Prompt")
                        .font(AQDesign.TypeToken.label)
                        .foregroundStyle(AQDesign.ColorToken.textPrimary)
                    TextEditor(text: bindingForPrompt(prompt.id))
                        .font(AQDesign.TypeToken.detail)
                        .scrollContentBackground(.hidden)
                        .padding(AQDesign.Space.standard)
                        .frame(minHeight: 76, maxHeight: 100)
                        .background(fieldBackground)
                        .accessibilityLabel("Prompt")
                    CardText("Use {selection} where the selected or typed text should appear. If omitted, the text is appended.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            CardNote {
                VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
                    HStack(spacing: AQDesign.Space.standard) {
                        Text("Command:")
                            .font(AQDesign.TypeToken.label)
                            .foregroundStyle(AQDesign.ColorToken.textSecondary)
                        TextField(
                            "Executable, e.g. recall",
                            text: bindingForCommandExecutable(prompt.id)
                        )
                        .textFieldStyle(.plain)
                        .font(AQDesign.TypeToken.code)
                        .padding(.horizontal, AQDesign.Space.standard)
                        .frame(maxWidth: 180, minHeight: House.Control.compact)
                        .background(fieldBackground)
                        TextField(
                            "Arguments, e.g. search {input}",
                            text: bindingForCommandArguments(prompt.id)
                        )
                        .textFieldStyle(.plain)
                        .font(AQDesign.TypeToken.code)
                        .padding(.horizontal, AQDesign.Space.standard)
                        .frame(minHeight: House.Control.compact)
                        .background(fieldBackground)
                    }
                    CardText("Optional. With an executable set, the action runs it directly (no shell) instead of a model. {input} inserts the typed text as one argument.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsRow(title: "Provider") {
                Picker("Provider", selection: bindingForProvider(prompt.id)) {
                    Text("Current provider").tag(nil as UUID?)
                    ForEach(viewModel.settings.providers) { provider in
                        Text(provider.name).tag(provider.id as UUID?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            SettingsRow(title: "Model") {
                Picker("Model", selection: bindingForModel(prompt.id)) {
                    Text("Provider default").tag(nil as String?)
                    ForEach(modelsForPrompt(prompt), id: \.self) { model in
                        Text(model).tag(model as String?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(prompt.providerID == nil)
            }

            // Only a command that pins one model can pin an effort for it.
            if let pinned = pinnedModel(prompt),
               preferences.profile(providerID: pinned.providerID, model: pinned.model)
                   .supportsReasoningEffort {
                SettingsRow(title: "Reasoning effort") {
                    Picker("Reasoning effort", selection: bindingForEffort(prompt.id)) {
                        ForEach(ReasoningEffort.allCases) { effort in
                            Text(effort.title).tag(effort)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Reasoning effort")
                }
                CardNote {
                    CardText("Model default lets the provider decide. The choice carries over to the next model that supports it.")
                }
            }

            CardNote {
                CardText("Pin this action to a provider and model, or let it use the current choice.")
            }

            SettingsRow(title: "After running") {
                Picker("After running", selection: bindingForOutputBehavior(prompt.id)) {
                    ForEach(ActionOutputBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }

            SettingsRow(title: "Global hotkey") {
                ActionHotkeyRecorderView(
                    hotkey: bindingForHotkey(prompt.id),
                    label: "Global hotkey",
                    showsLabel: false
                )
            }
            if let conflict = viewModel.settings.actionHotkeyConflict(for: prompt.id) {
                CardNote { CardText(conflict, tone: AQDesign.ColorToken.danger) }
            }
        }
    }

    /// The house field ground: quiet fill plus a hairline, at `Radius.sm`.
    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: AQDesign.fieldCornerRadius, style: .continuous)
            .fill(AQDesign.ColorToken.surfaceFill)
            .overlay(
                RoundedRectangle(cornerRadius: AQDesign.fieldCornerRadius, style: .continuous)
                    .strokeBorder(AQDesign.ColorToken.tileStroke, lineWidth: AQDesign.hairline)
            )
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
                let providerID = viewModel.settings.savedPrompts
                    .first(where: { $0.id == id })?.providerID
                update(id) { $0.model = newValue }
                if let providerID, let newValue {
                    preferences.noteModelSelection(providerID: providerID, model: newValue)
                }
            }
        )
    }

    /// The provider and model a command pins, when it pins both. An effort
    /// only means something against one specific model.
    private func pinnedModel(_ prompt: SavedPrompt) -> (providerID: UUID, model: String)? {
        guard let providerID = prompt.providerID,
              let model = prompt.model,
              !model.isEmpty
        else { return nil }
        return (providerID, model)
    }

    private func bindingForEffort(_ id: SavedPrompt.ID) -> Binding<ReasoningEffort> {
        Binding(
            get: {
                guard let prompt = viewModel.settings.savedPrompts.first(where: { $0.id == id }),
                      let pinned = pinnedModel(prompt)
                else { return .modelDefault }
                return preferences.profile(providerID: pinned.providerID, model: pinned.model)
                    .reasoningEffort
            },
            set: { newValue in
                guard let prompt = viewModel.settings.savedPrompts.first(where: { $0.id == id }),
                      let pinned = pinnedModel(prompt)
                else { return }
                preferences.setReasoningEffort(
                    newValue,
                    providerID: pinned.providerID,
                    model: pinned.model
                )
            }
        )
    }

    private func modelsForPrompt(_ prompt: SavedPrompt) -> [String] {
        guard let providerID = prompt.providerID,
              let provider = viewModel.settings.providers.first(where: { $0.id == providerID })
        else { return [] }
        return ModelCatalogService.visibleModels(
            for: provider,
            currentModel: prompt.model,
            preferences: preferences
        )
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
