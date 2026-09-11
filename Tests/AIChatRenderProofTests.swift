// AIChatRenderProofTests — render proofs for the AI Chat window (plan Phase
// B2) in both appearances: the window with the chat list hidden (the
// default), with it shown, and with the find bar on a match. PNGs land in
// /tmp/quick-launch-render-proof/b2-*.png for a reviewer to look at.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("AI Chat render proof", .serialized)
@MainActor
struct AIChatRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    private func makeWindow(appearance: AppearancePreference) async -> AIChatWindowModel {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.autoCopy = false
        settings.historyEnabled = true
        let service = MockQuickService()
        let chat = QuickViewModel(settings: settings, service: service)
        let suite = "AIChatRenderProofTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)

        let provider = settings.providers[0].id
        func past(_ title: String, _ answer: String, pinned: Bool = false, minutes: Double) -> QuickConversation {
            var conversation = QuickConversation(
                providerID: provider,
                model: "model",
                messages: [
                    QuickMessage(role: .user, content: title),
                    QuickMessage(role: .assistant, content: answer),
                ]
            )
            conversation.isPinned = pinned
            conversation.updatedAt = Date(timeIntervalSinceNow: -minutes * 60)
            return conversation
        }
        chat.history = [
            past("Weekly plan for the release", "Ship Friday.", pinned: true, minutes: 600),
            past("STE rewrite of the client note", "Done.", pinned: true, minutes: 1_400),
            past("Kyoto trip in spring", "Three days.", minutes: 90),
            past("Budget review questions", "Four questions.", minutes: 240),
            past("What is a context budget", "The trimmed history.", minutes: 2_000),
        ]

        await service.setResponses([StreamDelta(
            text: "The release has three parts. **Build** the app on Thursday, **test** it with the team on Friday morning, and **ship** it after lunch.\n\nThe notes go out with the build.",
            finishReason: "stop"
        )])
        chat.input = "walk me through the release plan"
        await chat.submit()
        await service.setResponses([StreamDelta(
            text: "Friday after lunch, once the team has tested the build.",
            finishReason: "stop"
        )])
        chat.input = "and when does it ship?"
        await chat.submit()
        chat.input = "Draft the release note.\nKeep it to three lines."
        return window
    }

    @Test func rendersTheAIChatWindowSet() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let preference: AppearancePreference = appearance == .darkAqua ? .dark : .light

            // The default: the chat list hidden, a two-line draft in the composer.
            let plain = await makeWindow(appearance: preference)
            #expect(!plain.isRailVisible)
            let plainImage = try Self.render(plain, appearance: appearance)
            try Self.save(plainImage, name: "b2-ai-chat-\(suffix).png")

            // ⌘\: the chat list, Pinned then Recent, the open chat highlighted.
            let rail = await makeWindow(appearance: preference)
            rail.showRail()
            rail.moveRailSelection(1)
            #expect(rail.pinnedRailItems.count == 2)
            let railImage = try Self.render(rail, appearance: appearance)
            try Self.save(railImage, name: "b2-ai-chat-rail-\(suffix).png")

            // ⌘F: the find bar on the second of two matches.
            let find = await makeWindow(appearance: preference)
            find.openFind()
            find.findQuery = "friday"
            find.findNext()
            #expect(find.findStatus == "2 of 2")
            let findImage = try Self.render(find, appearance: appearance)
            try Self.save(findImage, name: "b2-ai-chat-find-\(suffix).png")

            // The rail really is drawn, and the ground follows the appearance.
            let ground = try Self.averageBrightness(of: plainImage, x: 0.5, y: 0.5)
            #expect(appearance == .darkAqua ? ground < 0.3 : ground > 0.7)
        }
    }

    /// The Quick AI surface after its thread, composer, and title block
    /// became shared subviews: the same header (the expand glyph now
    /// continues in AI Chat), thread, and composer, drawn by the launcher
    /// proof's own ground renderer.
    @Test func rendersQuickAIOnTheSharedSubviews() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            var settings = QuickSettings()
            settings.appearance = appearance == .darkAqua ? .dark : .light
            settings.autoCopy = false
            settings.historyEnabled = false
            let service = MockQuickService()
            await service.setResponses([StreamDelta(
                text: "Raycast was co-founded by **Thomas Paul Mann** (CEO) and **Petr Nikolaev** (CTO) in 2020.",
                finishReason: "stop"
            )])
            let vm = QuickViewModel(settings: settings, service: service)
            vm.openQuickAI()
            vm.input = "raycast founder"
            await vm.submit()
            #expect(vm.conversationMessages.count == 2)
            let image = try OverlayRenderProofTests.renderOnGround(
                OverlayView(viewModel: vm),
                appearance: appearance,
                width: PanelSizing.panelWidth,
                height: PanelSizing.quickAIHeight + House.Spacing.xxxxl * 1.5
            )
            try Self.save(image, name: "b2-quick-ai-surface-\(suffix).png")
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

    /// The brightness of one pixel, at a fraction of the image's size.
    private static func averageBrightness(of image: NSImage, x: CGFloat, y: CGFloat) throws -> Double {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let color = rep.colorAt(x: Int(CGFloat(rep.pixelsWide) * x), y: Int(CGFloat(rep.pixelsHigh) * y))?
                .usingColorSpace(.sRGB)
        else { throw RenderError.noBitmap }
        return Double(color.redComponent + color.greenComponent + color.blueComponent) / 3
    }

    private enum RenderError: Error { case noBitmap }
}
