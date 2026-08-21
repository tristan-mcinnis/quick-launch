import SwiftUI
import AppKit

@main
struct QuickLaunchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Settings {
            if let viewModel = appDelegate.viewModel {
                SettingsView(viewModel: viewModel)
            } else {
                ProgressView("Starting Quick Launch…")
                    .frame(width: 600, height: 560)
            }
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
