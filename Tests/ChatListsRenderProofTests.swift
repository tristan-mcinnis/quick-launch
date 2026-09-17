// ChatListsRenderProofTests — visual proof for the chat lists after the
// v1.5 consistency audit (group G1), in both appearances, written to
// /tmp/quick-launch-render-proof/:
//   g1-chats-catalog-{dark,light}.png              the root "Chats" catalog,
//                                                  rows typed "Chat"
//   g1-chats-catalog-row-actions-{dark,light}.png  ⌘K on a catalog row, with
//                                                  Open in AI Chat ⌘J
//   g1-recent-chats-row-actions-{dark,light}.png   ⌘K on a Recent Chats row:
//                                                  the same actions, and the
//                                                  header's Open in AI Chat
//   g1-more-menu-{dark,light}.png                  the ⋯ menu's chat entries
//   g1-palette-chat-group-{dark,light}.png         ⌘K on a chat: chat actions
//                                                  say what they do to the
//                                                  chat, never "Answer"
//
// The ⋯ menu is a system menu that only draws when it opens on screen, so
// its proof draws the same entries (`chatMenuEntries`, titles, glyphs, keys,
// and the enabled state) on a menu-shaped card with the house tokens.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Chat lists render proof", .serialized)
@MainActor
struct ChatListsRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    private static func appearances() -> [(NSAppearance.Name, String)] {
        [(.darkAqua, "dark"), (.aqua, "light")]
    }

    /// A view model with three saved chats, one pinned, and a window to
    /// open (so Open in AI Chat is offered). Nothing touches disk.
    private static func makeViewModel(_ appearance: NSAppearance.Name) -> (QuickViewModel, MockQuickService) {
        var settings = QuickSettings()
        settings.appearance = appearance == .darkAqua ? .dark : .light
        settings.autoCopy = false
        settings.historyEnabled = true
        settings.launcherLearningEnabled = false
        let mock = MockQuickService()
        let vm = QuickViewModel(settings: settings, service: mock, pasteboard: FakePasteboard())
        vm.aiChatOpener = { _ in }
        let now = Date()
        vm.history = [
            QuickConversation(
                updatedAt: now,
                providerID: InferenceProvider.deepSeekID,
                model: InferenceProvider.deepSeekDefaultModel,
                messages: [
                    QuickMessage(role: .user, content: "walk me through the release plan"),
                    QuickMessage(role: .assistant, content: "Three parts."),
                ]
            ),
            QuickConversation(
                updatedAt: now.addingTimeInterval(-3_600),
                providerID: InferenceProvider.deepSeekID,
                model: InferenceProvider.deepSeekDefaultModel,
                messages: [
                    QuickMessage(role: .user, content: "summarise the Q3 plan"),
                    QuickMessage(role: .assistant, content: "Three priorities."),
                    QuickMessage(role: .user, content: "and the budget"),
                    QuickMessage(role: .assistant, content: "Flat."),
                ],
                isPinned: true
            ),
            QuickConversation(
                updatedAt: now.addingTimeInterval(-7_200),
                providerID: InferenceProvider.deepSeekID,
                model: InferenceProvider.deepSeekDefaultModel,
                messages: [
                    QuickMessage(role: .user, content: "what is the capital of Peru"),
                    QuickMessage(role: .assistant, content: "Lima."),
                ]
            ),
        ]
        return (vm, mock)
    }

    @Test func rendersTheChatsCatalogAndItsRowActions() throws {
        for (appearance, suffix) in Self.appearances() {
            let (vm, _) = Self.makeViewModel(appearance)
            vm.input = ""
            vm.enterCatalog(.chats)
            #expect(vm.catalogScope?.title == "Chats")
            #expect(vm.launcherMatches.count == 3)
            try Self.save(try Self.render(vm, appearance: appearance), name: "g1-chats-catalog-\(suffix).png")

            vm.applicationSelectionIndex = 1
            vm.handleCommandK()
            #expect(vm.isCatalogActionPanePresented)
            #expect(vm.focusedItemActions.map(\.title)
                == ["Continue Chat", "Open in AI Chat", "Copy Last Answer", "Rename Chat", "Pin to Top", "Hide from Quick Launch", "Delete Chat"])
            try Self.save(try Self.render(vm, appearance: appearance), name: "g1-chats-catalog-row-actions-\(suffix).png")
        }
    }

    @Test func rendersRecentChatsRowActionsAndTheHeaderButton() throws {
        for (appearance, suffix) in Self.appearances() {
            let (vm, _) = Self.makeViewModel(appearance)
            vm.input = ""
            vm.openRecentChats()
            vm.recentChatsIndex = 1
            vm.handleCommandK()
            #expect(vm.isCatalogActionPanePresented)
            #expect(vm.focusedItemActions.map(\.title)
                == ["Continue Chat", "Open in AI Chat", "Copy Last Answer", "Rename Chat", "Pin to Top", "Hide from Quick Launch", "Delete Chat"])
            try Self.save(try Self.render(vm, appearance: appearance), name: "g1-recent-chats-row-actions-\(suffix).png")
        }
    }

    @Test func rendersTheMoreMenuChatEntries() throws {
        for (appearance, suffix) in Self.appearances() {
            let (vm, _) = Self.makeViewModel(appearance)
            #expect(vm.chatMenuEntries.map(\.title) == ["New Chat", "Recent Chats", "Open AI Chat"])
            let card = ChatMenuProofCard(
                entries: vm.chatMenuEntries,
                bindings: vm.shortcuts,
                isEnabled: vm.isChatMenuEntryEnabled
            )
            try Self.save(try Self.renderView(card, appearance: appearance), name: "g1-more-menu-\(suffix).png")
        }
    }

    @Test func rendersThePaletteWithTheChatGroup() async throws {
        for (appearance, suffix) in Self.appearances() {
            let (vm, mock) = Self.makeViewModel(appearance)
            await mock.setResponses([StreamDelta(text: "Three parts: scope, dates, owners.", finishReason: "stop")])
            vm.input = ""
            vm.openQuickAI()
            vm.input = "walk me through the release plan"
            await vm.submit()
            vm.handleCommandK()
            #expect(vm.isActionPalettePresented)
            // Scroll the palette to the chat actions: a query keeps them.
            vm.actionQuery = "chat"
            #expect(vm.paletteResultActions.contains(.newChat))
            try Self.save(try Self.render(vm, appearance: appearance), name: "g1-palette-chat-group-\(suffix).png")
        }
    }

    // MARK: - Helpers

    /// The overlay at the height the window gives it.
    private static func render(_ vm: QuickViewModel, appearance: NSAppearance.Name) throws -> NSImage {
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

    private static func renderView<V: View>(_ view: V, appearance: NSAppearance.Name) throws -> NSImage {
        let root = view
            .padding(House.Spacing.xl)
            .background(House.ColorToken.surface)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
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

/// The ⋯ menu's chat section as a menu draws it: glyph, title, and the key
/// on the right, a greyed entry when it has nothing to do. A stand-in for
/// the system menu, which cannot draw offscreen.
private struct ChatMenuProofCard: View {
    let entries: [ChatMenuEntry]
    /// The owner's resolved shortcut table, the same one the real menu draws.
    var bindings: ShortcutBindings = .defaults
    let isEnabled: (ChatMenuEntry) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                HStack(spacing: House.Spacing.xs) {
                    Image(systemName: entry.systemImage)
                        .font(AQDesign.TypeToken.label)
                        .frame(width: House.Control.keyCap)
                    Text(entry.title)
                        .font(AQDesign.TypeToken.label)
                    Spacer(minLength: House.Spacing.xl)
                    if let shortcut = entry.shortcut(bindings) {
                        KeyCapGroup(keys: shortcut.keyCaps)
                    }
                }
                .foregroundStyle(isEnabled(entry) ? AQDesign.ColorToken.textPrimary : AQDesign.ColorToken.textTertiary)
                .padding(.horizontal, House.Spacing.sm)
                .frame(height: House.Control.railRow)
            }
        }
        .padding(.vertical, House.Spacing.xxs)
        .frame(width: House.Layout.chatRail)
        .background(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .fill(House.ColorToken.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: House.Radius.md, style: .continuous)
                .strokeBorder(AQDesign.ColorToken.tileStroke, lineWidth: AQDesign.hairline)
        )
    }
}
