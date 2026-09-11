// AIChatBehaviourRenderProofTests — render proofs for package W2 (AI Chat
// behaviour) in both appearances: ⌘K › Copy Message on its list of every
// question and answer, the thread's line after a chat was deleted while it
// answered, and Add Context in a window that knows no app in front. PNGs
// land in /tmp/quick-launch-render-proof/w2-*.png for a reviewer.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("AI Chat behaviour render proof", .serialized)
@MainActor
struct AIChatBehaviourRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    /// A window on a two-turn chat.
    private func makeWindow(appearance: AppearancePreference) async -> (AIChatWindowModel, MockQuickService) {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.autoCopy = false
        settings.historyEnabled = true
        let service = MockQuickService()
        let chat = QuickViewModel(settings: settings, service: service)
        chat.modelPreferences = ModelPreferenceStore(fileURL: nil)
        chat.announce = { _ in }
        let suite = "AIChatBehaviourRenderProofTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        window.open(handoff: nil)
        await service.setResponses([StreamDelta(
            text: "The release has three parts: build on Thursday, test on Friday morning, ship after lunch.",
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
        return (window, service)
    }

    @Test func rendersTheW2Set() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let preference: AppearancePreference = appearance == .darkAqua ? .dark : .light

            // ⌘K › Copy Message: every question and answer, newest first.
            let (palette, _) = await makeWindow(appearance: preference)
            palette.chat.memoryCapture = RenderProofMemory()
            palette.chat.handleCommandK()
            palette.chat.performQuickAISurfaceAction(.copyMessage)
            #expect(palette.chat.paletteMessageRows.count == 4)
            try Self.save(try Self.render(palette, appearance: appearance), name: "w2-copy-message-\(suffix).png")

            // The line a chat deleted while it answered leaves.
            let (deleted, _) = await makeWindow(appearance: preference)
            let id = try #require(deleted.chat.currentConversation?.id)
            deleted.chat.store.deletedChatIDs.insert(id)
            deleted.chat.history.removeAll { $0.id == id }
            deleted.chat.persistAnsweredConversation()
            #expect(deleted.chat.threadNotice == QuickViewModel.deletedWhileAnsweringNotice)
            try Self.save(try Self.render(deleted, appearance: appearance), name: "w2-deleted-notice-\(suffix).png")

            // Add Context with no app known in front: two entries.
            let (context, _) = await makeWindow(appearance: preference)
            context.chat.openAddContextMenu()
            #expect(context.chat.addContextOptions == [.selectedArea, .entireScreen])
            try Self.save(try Self.render(context, appearance: appearance), name: "w2-add-context-\(suffix).png")
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

    private enum RenderError: Error { case noBitmap }
}

/// Capture to Memory that goes nowhere, so the palette offers it.
private struct RenderProofMemory: MemoryCapturing {
    func remember(_ text: String) async throws {}
}
