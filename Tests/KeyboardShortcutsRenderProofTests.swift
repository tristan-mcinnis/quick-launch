// KeyboardShortcutsRenderProofTests — offscreen proofs of the Keyboard
// Shortcuts pane in both appearances, written to
// /tmp/quick-launch-render-proof/keyboard-shortcuts-*.png: the pane as it
// opens (every group, the built-in caps), the same pane with a rebind and a
// refused key, and the two read-only cards below it (the fixed keys and the
// global hotkeys).

import AppKit
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Keyboard shortcuts render proofs", .serialized)
@MainActor
struct KeyboardShortcutsRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
    private static let appearances: [(NSAppearance.Name, AppearancePreference, String)] = [
        (.darkAqua, .dark, "dark"),
        (.aqua, .light, "light"),
    ]
    /// The pane as the Settings window gives it.
    private static let paneSize = NSSize(
        width: SettingsView.windowSize.width - House.Layout.settingsRail - House.hairline,
        height: SettingsView.windowSize.height
    )

    private static func makeViewModel(_ appearance: AppearancePreference) -> QuickViewModel {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.autoCopy = false
        return QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
    }

    @Test func rendersThePaneAtItsOwnKeys() throws {
        for (appearance, preference, suffix) in Self.appearances {
            let vm = Self.makeViewModel(preference)
            try Self.save(
                try Self.render(KeyboardShortcutsSettingsView(viewModel: vm), appearance: appearance),
                name: "keyboard-shortcuts-\(suffix).png"
            )
        }
    }

    @Test func rendersThePaneWithARebind() throws {
        for (appearance, preference, suffix) in Self.appearances {
            let vm = Self.makeViewModel(preference)
            // One changed key, so the row shows Reset beside its recorder and
            // the count line at the foot of the card is not the empty state.
            vm.setShortcut(
                ActionHotkey(keyCode: 38, modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue),
                for: .newChat
            )
            vm.setShortcut(
                ActionHotkey(keyCode: 11, modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue),
                for: .openSource
            )
            try Self.save(
                try Self.render(KeyboardShortcutsSettingsView(viewModel: vm), appearance: appearance),
                name: "keyboard-shortcuts-rebound-\(suffix).png"
            )
        }
    }

    // MARK: - Rendering

    private static func render<V: View>(_ pane: V, appearance: NSAppearance.Name) throws -> NSImage {
        let root = pane
            .frame(width: paneSize.width, height: paneSize.height, alignment: .topLeading)
            .background(AQDesign.ColorToken.windowSurface)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: paneSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProofError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func save(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ProofError.noBitmap }
        // A blank or crashed render is still a PNG; the proof has to be of
        // something, so an empty one fails here rather than passing quietly.
        #expect(png.count > 20_000, "\(name) looks blank (\(png.count) bytes)")
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    enum ProofError: Error { case noBitmap }
}
