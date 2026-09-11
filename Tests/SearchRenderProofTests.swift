// SearchRenderProofTests — render proofs for chat search and Find in Chat
// (spec section 4, WP-B) in both appearances, written to
// /tmp/quick-launch-render-proof/:
//   search-rail-{dark,light}.png          the AI Chat rail with a query: one
//                                         "Results" list, snippets under the
//                                         titles, the open chat's bar
//   search-rail-command-{dark,light}.png  the rail with ⌘ held: every ⌘1…⌘9
//                                         number, the open chat marked apart
//                                         from the highlight
//   search-recent-chats-{dark,light}.png  Recent Chats (⌘P) with snippets
//   search-chats-catalog-{dark,light}.png the root Chats catalog with a snippet
//   search-find-{dark,light}.png          Find in Chat on an answer: every hit
//                                         highlighted, one current, "2 of 5"

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Search render proof", .serialized)
@MainActor
struct SearchRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    private static func appearances() -> [(NSAppearance.Name, String)] {
        [(.darkAqua, "dark"), (.aqua, "light")]
    }

    private static func settings(_ appearance: NSAppearance.Name) -> QuickSettings {
        var settings = QuickSettings()
        settings.appearance = appearance == .darkAqua ? .dark : .light
        settings.autoCopy = false
        settings.historyEnabled = true
        settings.launcherLearningEnabled = false
        return settings
    }

    /// Five saved chats: two found by their title, three by their text.
    private static func history(now: Date = Date()) -> [QuickConversation] {
        let provider = QuickSettings().providers[0].id
        func past(
            _ question: String,
            _ answer: String,
            pinned: Bool = false,
            hours: Double,
            followUp: (String, String)? = nil
        ) -> QuickConversation {
            var messages = [
                QuickMessage(role: .user, content: question),
                QuickMessage(role: .assistant, content: answer),
            ]
            if let followUp {
                messages.append(QuickMessage(role: .user, content: followUp.0))
                messages.append(QuickMessage(role: .assistant, content: followUp.1))
            }
            return QuickConversation(
                updatedAt: now.addingTimeInterval(-hours * 3_600),
                providerID: provider,
                model: "model",
                messages: messages,
                isPinned: pinned
            )
        }
        return [
            past("Quarterly revenue review", "Up 4 percent on last quarter.", hours: 30),
            past(
                "Pricing notes for Oreo",
                "The list price stays. Rebates are paid each month.",
                pinned: true,
                hours: 50,
                followUp: ("does the quarterly revenue include the rebate or is it shown on its own line?", "It is netted out.")
            ),
            past(
                "Board deck outline",
                "Open with the market, then the plan. Slide four shows how the **revenue** splits by region, and slide five the costs.",
                hours: 4
            ),
            past("Kyoto trip in spring", "Three days: temples, gardens, and a day in Nara.", hours: 2),
            past("Revenue model for the new app", "Subscriptions first, then a team plan.", hours: 80),
            past(
                "Weekly sync notes",
                "Hiring is on track. Finance asked whether revenue from the pilot counts this quarter.",
                hours: 120
            ),
        ]
    }

    // MARK: - The AI Chat rail

    private func railWindow(_ appearance: NSAppearance.Name) -> AIChatWindowModel {
        let chat = QuickViewModel(settings: Self.settings(appearance), service: MockQuickService())
        let suite = "SearchRenderProofTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        chat.history = Self.history()
        return window
    }

    @Test func rendersTheRailWithAQueryAndSnippets() throws {
        for (appearance, suffix) in Self.appearances() {
            let window = railWindow(appearance)
            // Open the Kyoto chat, so its bar shows apart from the highlight.
            let kyoto = try #require(window.chat.history.first { $0.title.hasPrefix("Kyoto") })
            window.chat.continueConversation(itemID: kyoto.id.uuidString)
            window.showRail()
            window.railQuery = "revenue"
            #expect(window.isRailSearching)
            let items = window.railItems
            #expect(items.count == 5)
            #expect(items.prefix(2).map(\.title) == ["Quarterly revenue review", "Revenue model for the new app"])
            #expect(items.dropFirst(2).allSatisfy { $0.chatSnippet != nil }, "text hits carry a snippet")
            window.moveRailSelection(2)
            try Self.save(try Self.renderWindow(window, appearance: appearance), name: "search-rail-\(suffix).png")

            // ⌘ held: every number; the open chat keeps its bar.
            let held = railWindow(appearance)
            let heldKyoto = try #require(held.chat.history.first { $0.title.hasPrefix("Kyoto") })
            held.chat.continueConversation(itemID: heldKyoto.id.uuidString)
            held.showRail()
            held.moveRailSelection(3)
            held.isCommandHeld = true
            #expect(held.openChatItemID == heldKyoto.id.uuidString)
            #expect(held.highlightedRailItem?.itemID != heldKyoto.id.uuidString)
            try Self.save(try Self.renderWindow(held, appearance: appearance), name: "search-rail-command-\(suffix).png")
        }
    }

    // MARK: - Recent Chats and the Chats catalog

    @Test func rendersRecentChatsWithSnippets() throws {
        for (appearance, suffix) in Self.appearances() {
            let vm = QuickViewModel(settings: Self.settings(appearance), service: MockQuickService(), pasteboard: FakePasteboard())
            vm.history = Self.history()
            vm.input = ""
            vm.openRecentChats()
            vm.input = "revenue"
            vm.quickAIComposerDidChange(vm.input)
            let rows = vm.recentChatItems
            #expect(rows.count == 5)
            #expect(rows.contains { $0.chatSnippet?.label == "You:" })
            #expect(rows.contains { $0.chatSnippet?.label == "Answer:" })
            try Self.save(try Self.renderOverlay(vm, appearance: appearance), name: "search-recent-chats-\(suffix).png")
        }
    }

    @Test func rendersTheChatsCatalogWithASnippet() throws {
        for (appearance, suffix) in Self.appearances() {
            let vm = QuickViewModel(settings: Self.settings(appearance), service: MockQuickService(), pasteboard: FakePasteboard())
            vm.history = Self.history()
            vm.input = ""
            vm.enterCatalog(.chats)
            vm.input = "rebate"
            let rows = vm.catalogMatches
            #expect(rows.count == 1)
            #expect(rows.first?.chatSnippet?.label == "You:")
            try Self.save(try Self.renderOverlay(vm, appearance: appearance), name: "search-chats-catalog-\(suffix).png")
        }
    }

    // MARK: - Find in Chat

    @Test func rendersFindWithEveryHitHighlighted() async throws {
        for (appearance, suffix) in Self.appearances() {
            let service = MockQuickService()
            let chat = QuickViewModel(settings: Self.settings(appearance), service: service)
            let suite = "SearchRenderProofTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let window = AIChatWindowModel(chat: chat, defaults: defaults)
            await service.setResponses([StreamDelta(
                text: """
                The release has three parts. **Build** the app on Thursday, test the build with the team on Friday morning, and ship it after lunch.

                ```sh
                swift build -c release
                ./scripts/build-app.sh
                ```

                The notes go out with the build.
                """,
                finishReason: "stop"
            )])
            chat.input = "walk me through the build"
            await chat.submit()
            window.openFind()
            window.findQuery = "build"
            window.findNext()
            #expect(window.findStatus == "2 of 6")
            #expect(window.currentHit?.part == .segment(0))
            try Self.save(try Self.renderWindow(window, appearance: appearance), name: "search-find-\(suffix).png")
        }
    }

    // MARK: - Rendering

    private static func renderWindow(_ model: AIChatWindowModel, appearance: NSAppearance.Name) throws -> NSImage {
        let size = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
        let root = AIChatWindowView(model: model)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return try snapshot(host)
    }

    private static func renderOverlay(_ vm: QuickViewModel, appearance: NSAppearance.Name) throws -> NSImage {
        let width = vm.currentPanelWidth
        let height = vm.estimatedWindowHeight
        let root = OverlayView(viewModel: vm)
            .frame(width: width, height: height, alignment: .top)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        return try snapshot(host)
    }

    private static func snapshot(_ host: NSView) throws -> NSImage {
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
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    enum ProofError: Error { case noBitmap }
}
