import AppKit
import Darwin
import SwiftUI
import HouseDesign

extension AppDelegate {
    // MARK: - Click-outside dismissal

    func registerMouseDismissMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible else { return }
                let clickPoint = event.locationInWindow
                let screenPoint: NSPoint
                if let window = event.window {
                    screenPoint = window.convertPoint(toScreen: clickPoint)
                } else {
                    screenPoint = clickPoint
                }
                // Ignore clicks in the menu bar region (status item clicks are
                // handled separately by handleStatusItemClick)
                if ScreenPlacement.isInMenuBarRegion(
                    screenPoint,
                    frames: NSScreen.screens.map(\.frame)
                ) {
                    return
                }
                if !panel.frame.contains(screenPoint) {
                    self.hideOverlay()
                }
            }
        }
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.imagePosition = .imageOnly
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
    }

    func syncStatusItemVisibilityAndPresentation(viewModel: QuickViewModel) {
        if viewModel.settings.showMenuBar {
            setupStatusItem()
        } else if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            return
        }

        guard let button = statusItem?.button else { return }
        // Status item (DESIGN.md): the app-icon glyph as a template image at
        // `Control.statusGlyph`, medium weight; outline idle, `.fill` = on.
        let image = NSImage(
            systemSymbolName: Self.statusGlyphName,
            accessibilityDescription: Self.statusAccessibilityName
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: House.Control.statusGlyph, weight: .medium)
        )
        image?.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(Self.statusAccessibilityName)
    }

    /// The status item's one glyph, and what VoiceOver reads for it.
    static let statusGlyphName = "bolt"

    static let statusAccessibilityName = "Quick Launch"

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleOverlay()
            return
        }
        if event.type == .rightMouseUp {
            let menu = buildContextMenu()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        } else {
            toggleOverlay()
        }
    }

    /// Built on every right-click, so it shows the current hotkey and
    /// Caffeinate state (`StatusMenu`).
    private func buildContextMenu() -> NSMenu {
        StatusMenu.make(
            StatusMenu.State(
                settings: viewModel?.settings ?? QuickSettings(),
                isCaffeinating: viewModel?.isCaffeinating == true,
                hasCaffeinateSession: viewModel?.hasCaffeinateSession == true,
                version: Bundle.main.shortVersion
            ),
            target: self,
            action: #selector(performStatusMenuCommand(_:))
        )
    }

    @objc private func performStatusMenuCommand(_ sender: NSMenuItem) {
        switch StatusMenu.Command(rawValue: sender.tag) {
        case .openQuickLaunch: showOverlayFromMenu()
        case .openAIChat: showAIChatFromMenu()
        case .openSettings: openSettingsFromMenu()
        case .toggleCaffeinate: toggleCaffeinateFromMenu()
        case .openWebsite: openWebsite()
        case .quit: NSApp.terminate(nil)
        case nil: break
        }
    }

    @objc private func showOverlayFromMenu() {
        showOverlay()
    }

    @objc private func openSettingsFromMenu() {
        showSettingsPanel()
    }

    @objc private func toggleCaffeinateFromMenu() {
        guard let viewModel,
              let item = viewModel.systemCommands.first(where: {
                  $0.itemID == "caffeinate.toggle"
              }) else { return }
        viewModel.performSystemCommand(item)
    }

    @objc private func openWebsite() {
        if let url = URL(string: "https://github.com/tristan-mcinnis/quick-launch") {
            NSWorkspace.shared.open(url)
        }
    }
}
