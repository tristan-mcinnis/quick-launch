import AppKit
import SwiftUI

struct ApplicationSettingsView: View {
    @Bindable var viewModel: QuickViewModel
    @State private var query = ""
    @State private var selection: String?

    private var applications: [LaunchableApplication] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return viewModel.applications }
        return viewModel.applications.filter { application in
            FuzzyMatcher.score(query: trimmed, candidate: application.name) != nil
                || FuzzyMatcher.score(
                    query: trimmed,
                    candidate: viewModel.applicationAlias(for: application)
                ) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AQDesign.Space.standard) {
            Text("Applications")
                .font(.headline)
            Text("Every app can have a search alias and an optional global hotkey.")
                .font(AQDesign.TypeToken.label)
                .foregroundStyle(.secondary)

            TextField("Find an app", text: $query)
                .textFieldStyle(.roundedBorder)

            Table(applications, selection: $selection) {
                TableColumn("Application") { application in
                    HStack(spacing: AQDesign.Space.standard) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                        Text(application.name)
                            .lineLimit(1)
                    }
                }
                .width(min: 170, ideal: 230)

                TableColumn("Alias") { application in
                    Text(viewModel.applicationAlias(for: application))
                        .foregroundStyle(
                            viewModel.applicationAlias(for: application).isEmpty
                                ? .secondary
                                : .primary
                        )
                }
                .width(min: 90, ideal: 140)

                TableColumn("Hotkey") { application in
                    Text(hotkeyName(viewModel.applicationHotkey(for: application)))
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
            }
            .frame(minHeight: 250)

            if let application = selectedApplication {
                Divider()
                HStack {
                    Text(application.name)
                        .font(AQDesign.TypeToken.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Button("Open") { _ = viewModel.launch(application: application) }
                }

                TextField("Search alias", text: aliasBinding(for: application))
                    .textFieldStyle(.roundedBorder)

                ActionHotkeyRecorderView(
                    hotkey: hotkeyBinding(for: application),
                    label: "Global hotkey",
                    changeNotification: .launcherItemHotkeysChanged
                )

                if let conflict = viewModel.applicationConfigurationConflict(for: application) {
                    Text(conflict)
                        .font(AQDesign.TypeToken.caption)
                        .foregroundStyle(AQDesign.ColorToken.danger)
                }
            }
        }
        .padding(AQDesign.Space.window)
    }

    private var selectedApplication: LaunchableApplication? {
        guard let selection else { return nil }
        return viewModel.applications.first { $0.id == selection }
    }

    private func aliasBinding(for application: LaunchableApplication) -> Binding<String> {
        Binding(
            get: { viewModel.applicationAlias(for: application) },
            set: { viewModel.setApplicationAlias($0, for: application) }
        )
    }

    private func hotkeyBinding(
        for application: LaunchableApplication
    ) -> Binding<ActionHotkey?> {
        Binding(
            get: { viewModel.applicationHotkey(for: application) },
            set: { viewModel.setApplicationHotkey($0, for: application) }
        )
    }

    private func hotkeyName(_ hotkey: ActionHotkey?) -> String {
        guard let hotkey else { return "Not set" }
        var settings = QuickSettings()
        settings.hotkeyKeyCode = hotkey.keyCode
        settings.hotkeyModifiers = hotkey.modifiers
        return settings.hotkeyDisplayName
    }
}
