import Foundation
import Testing

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

    @Test("Command-comma routes to the real settings interface")
    func settingsRoute() throws {
        let source = try Self.source("Sources/App/ApfelQuickApp.swift")
        #expect(source.contains("SettingsView(viewModel: viewModel)"))
        #expect(source.contains("CommandGroup(replacing: .appSettings)"))
        #expect(source.contains("keyboardShortcut(\",\", modifiers: .command)"))
        #expect(!source.contains("Settings {\n            EmptyView()"))
    }

    @Test("Result actions use the shared 44-point control target")
    func resultActionTargets() throws {
        let overlay = try Self.source("Sources/Views/OverlayView.swift")
        let tokens = try Self.source("Sources/Views/DesignTokens.swift")
        #expect(tokens.contains("controlHeight: CGFloat = 44"))
        #expect(overlay.components(separatedBy: "minHeight: AQDesign.controlHeight").count == 4)
        #expect(overlay.contains("keyboardShortcut(\"c\", modifiers: [.command, .shift])"))
        #expect(overlay.contains("keyboardShortcut(\"v\", modifiers: [.command, .shift])"))
    }
}
