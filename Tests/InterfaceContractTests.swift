import Foundation
import Testing
@testable import QuickLaunch

@Suite("Launcher interface contract")
struct InterfaceContractTests {
    private static func source(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        root.deleteLastPathComponent()
        root.deleteLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @MainActor
    @Test("Arrow navigation announces the launcher selection")
    func launcherSelectionAnnouncement() {
        let viewModel = QuickViewModel()
        let count = viewModel.launcherMatches.count
        #expect(count > 1)

        viewModel.moveApplicationSelection(1)

        #expect(viewModel.launcherSelectionAnnouncementRevision == 1)
        #expect(viewModel.launcherSelectionAnnouncement.contains("selected, 2 of \(count)"))
        #expect(viewModel.launcherSelectionAnnouncement.contains("with Return"))
    }

    @Test("Actions expose selected state and announcements")
    func actionSelectionAccessibilityContract() throws {
        let overlay = try Self.source("Sources/Views/OverlayView.swift")
        let pane = try Self.source("Sources/Views/SelectableListPane.swift")
        #expect(pane.contains("accessibilityAddTraits(isSelected ? .isSelected : [])"))
        #expect(overlay.contains("SelectableListPane("))
        #expect(overlay.contains("private func announceSelected()"))
    }

    @Test("Command-comma routes to the real settings interface")
    func settingsRoute() throws {
        let source = try Self.source("Sources/App/QuickLaunchApp.swift")
        #expect(source.contains("SettingsView(viewModel: viewModel)"))
        #expect(source.contains("CommandGroup(replacing: .appSettings)"))
        #expect(source.contains("keyboardShortcut(\",\", modifiers: .command)"))
        #expect(!source.contains("Settings {\n            EmptyView()"))
    }

    @Test("Answer actions are keys from the shared table, not buttons")
    func answerActionsAreKeys() throws {
        let overlay = try Self.source("Sources/Views/OverlayView.swift")
        // The Quick AI composer is its own view, shared with AI Chat.
        let quickAI = try Self.source("Sources/Views/QuickAIComposer.swift")
        let actions = try Self.source("Sources/Models/ItemAction.swift")
        #expect(!overlay.contains("Paste Back"))
        #expect(!quickAI.contains("Paste Back"))
        #expect(!overlay.contains("keyboardShortcut(\"c\", modifiers: [.command, .shift])"))
        #expect(!quickAI.contains("keyboardShortcut(\"c\", modifiers: [.command, .shift])"))
        // The composer's one hint comes from the view model, which reads the
        // Primary Action setting; the view never names an action itself.
        #expect(quickAI.contains("viewModel.quickAIComposerAction"))
        #expect(overlay.contains("QuickAIView(viewModel: viewModel)"))
        #expect(overlay.contains("LauncherFooter(viewModel: viewModel)"))
        #expect(actions.contains("enum ResultAction"))
        #expect(actions.contains("case .copy: .commandShift(\"c\")"))
        #expect(actions.contains("case .pasteBack: .commandReturn"))
        #expect(overlay.contains("viewModel.launcherMatches"))
    }
}
