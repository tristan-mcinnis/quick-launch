// AIChatLifecycleRenderProofTests: render proofs for fix package W1: the
// AI Chat header in a normal window (room for the traffic lights) and in
// full screen (no traffic lights, so no room kept), in both appearances.
// PNGs land in /tmp/quick-launch-render-proof/w1-*.png.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("AI Chat lifecycle render proof", .serialized)
@MainActor
struct AIChatLifecycleRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    private func makeController(appearance: AppearancePreference) async -> AIChatWindowController {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.autoCopy = false
        settings.historyEnabled = false
        let service = MockQuickService()
        let chat = QuickViewModel(settings: settings, service: service)
        let suite = "AIChatLifecycleRenderProofTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AIChatWindowModel(chat: chat, defaults: defaults)
        await service.setResponses([StreamDelta(
            text: "The release has three parts: build on Thursday, test on Friday morning, ship after lunch.",
            finishReason: "stop"
        )])
        chat.input = "walk me through the release plan"
        await chat.submit()
        return AIChatWindowController(
            model: model,
            app: RecordingPresenter(),
            shell: FakeAIChatAppShell(),
            notifier: FakeAnswerNotifier(),
            frameAutosaveName: nil
        )
    }

    @Test func rendersTheHeaderInAWindowAndInFullScreen() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let preference: AppearancePreference = appearance == .darkAqua ? .dark : .light
            let controller = await makeController(appearance: preference)

            let windowed = try Self.render(controller.model, appearance: appearance)
            try Self.save(windowed, name: "w1-ai-chat-header-window-\(suffix).png")

            controller.windowWillEnterFullScreen(Notification(name: NSWindow.willEnterFullScreenNotification))
            #expect(controller.model.isWindowFullScreen)
            let fullScreen = try Self.render(controller.model, appearance: appearance)
            try Self.save(fullScreen, name: "w1-ai-chat-header-fullscreen-\(suffix).png")

            // The sidebar glyph, the header's first ink: past the traffic
            // lights in a window, at the leading edge in full screen.
            let windowedInk = try Self.firstInkColumn(windowed)
            let fullScreenInk = try Self.firstInkColumn(fullScreen)
            #expect(windowedInk >= AIChatWindowView.trafficLightInset)
            #expect(fullScreenInk < House.Spacing.xl)
        }
    }

    // MARK: - Rendering

    private static func render(_ model: AIChatWindowModel, appearance: NSAppearance.Name) throws -> NSImage {
        let size = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
        let root = AIChatWindowView(model: model)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw RenderError.noBitmap
        }
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
        else { throw RenderError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    /// In points from the leading edge: the first column along the header's
    /// middle line whose brightness differs from the ground's.
    private static func firstInkColumn(_ image: NSImage) throws -> CGFloat {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { throw RenderError.noBitmap }
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        let row = Int(AIChatWindowView.titleBarHeight / 2 * scale)
        func brightness(_ x: Int) -> CGFloat {
            guard let color = rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB) else { return 0 }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let ground = brightness(0)
        for x in 0..<rep.pixelsWide where abs(brightness(x) - ground) > 0.15 {
            return CGFloat(x) / scale
        }
        return image.size.width
    }

    private enum RenderError: Error { case noBitmap }
}
