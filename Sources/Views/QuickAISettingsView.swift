import SwiftUI

/// The Quick AI card in the General pane: what Return does on a finished
/// answer, the Tab hint, when a new chat starts, whether the model may ask
/// clarifying questions, and the model Quick AI answers with.
///
/// Every row is a binding straight into `QuickSettings`, so a change applies
/// immediately and survives a relaunch, the same as every other General row.
/// The controls are the house ones: `InkSegmentedControl` for a two-way
/// choice, a menu picker for a list, `InkToggleStyle` for a switch.
struct QuickAISettingsView: View {
    @Bindable var viewModel: QuickViewModel

    var body: some View {
        SettingsCard("Quick AI") {
            SettingsRow(
                title: "Primary Action",
                detail: viewModel.settings.quickAIPrimaryAction.detail,
                isFirst: true
            ) {
                InkSegmentedControl(
                    selection: viewModel.settingsBinding(\.quickAIPrimaryAction),
                    options: QuickAIPrimaryAction.allCases.map {
                        InkSegment(value: $0, title: $0.displayName)
                    }
                )
                .accessibilityLabel("Primary action on a completed answer")
                .frame(maxWidth: 320)
            }

            SettingsRow(
                title: "Tab Shortcut",
                detail: "Hide the \u{21E5} hint in root search. Tab opens Quick AI whether the hint is shown or not."
            ) {
                Toggle("Hide the Tab hint in root search", isOn: tabHintHidden)
                    .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Start New Chat", detail: startNewChatDetail) {
                Picker("Start New Chat", selection: viewModel.settingsBinding(\.newChatInterval)) {
                    ForEach(NewChatInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .accessibilityLabel("Start New Chat")
            }

            SettingsRow(
                title: "Clarifying questions",
                detail: "Let the model pause and ask a short multiple-choice question when a request cannot be answered without your decision. Off, it answers the most reasonable reading."
            ) {
                Toggle(
                    "Let the model ask clarifying questions",
                    isOn: viewModel.settingsBinding(\.quickAIClarifyingQuestionsEnabled)
                )
                .toggleStyle(InkToggleStyle())
            }

            SettingsRow(title: "Model", detail: modelDetail) {
                Picker("Quick AI model", selection: modelSelection) {
                    Text("Use current model").tag("")
                    ForEach(modelOptions, id: \.id) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                .accessibilityLabel("Quick AI model")
            }
        }
    }

    /// Stored the other way round: the setting says whether the hint is shown,
    /// the switch says whether it is hidden.
    private var tabHintHidden: Binding<Bool> {
        viewModel.settingsBinding(
            get: { !$0.tabShortcutHintVisible },
            set: { settings, hidden in settings.tabShortcutHintVisible = !hidden }
        )
    }

    private var startNewChatDetail: String {
        switch viewModel.settings.newChatInterval {
        case .always:
            "Every question starts a new chat."
        case .never:
            "The chat keeps going until you start a new one yourself."
        case let interval:
            "A chat older than \(interval.displayName.lowercased()) is replaced by a new one."
        }
    }

    private var modelDetail: String {
        let settings = viewModel.settings
        guard let provider = settings.quickAIProvider else {
            return "No model is available. Add a provider in Models."
        }
        let model = settings.quickAIModelOverride(for: provider.id) ?? provider.selectedModel
        let named = model.isEmpty ? provider.name : "\(provider.name) · \(model)"
        return settings.quickAIProviderID == nil
            ? "Following the launcher: \(named)"
            : "Answers come from \(named)"
    }

    /// The whole choice as one string, so a single menu covers every installed
    /// provider and every model it publishes. An empty value is "use the
    /// current model", which is what leaves the setting unset.
    private var modelSelection: Binding<String> {
        Binding(
            get: {
                let settings = viewModel.settings
                guard let providerID = settings.quickAIProviderID else { return "" }
                return Self.selectionID(providerID: providerID, model: settings.quickAIModel)
            },
            set: { value in
                viewModel.updateSettings { settings in
                    guard !value.isEmpty else {
                        settings.quickAIProviderID = nil
                        settings.quickAIModel = ""
                        return
                    }
                    let parts = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                    guard let providerID = UUID(uuidString: String(parts[0])) else { return }
                    settings.quickAIProviderID = providerID
                    settings.quickAIModel = parts.count > 1 ? String(parts[1]) : ""
                }
            }
        )
    }

    private var modelOptions: [(id: String, title: String)] {
        let settings = viewModel.settings
        var options: [(id: String, title: String)] = []
        for provider in settings.providers {
            let configured = settings.quickAIProviderID == provider.id ? settings.quickAIModel : ""
            var models = Set(provider.models)
            if !provider.selectedModel.isEmpty { models.insert(provider.selectedModel) }
            if !configured.isEmpty { models.insert(configured) }
            for model in models.sorted() {
                options.append((
                    Self.selectionID(providerID: provider.id, model: model),
                    "\(provider.name) · \(model)"
                ))
            }
            if configured.isEmpty {
                options.append((
                    Self.selectionID(providerID: provider.id, model: ""),
                    "\(provider.name) · Default model"
                ))
            }
        }
        return options
    }

    private static func selectionID(providerID: UUID, model: String) -> String {
        "\(providerID.uuidString)|\(model)"
    }
}
