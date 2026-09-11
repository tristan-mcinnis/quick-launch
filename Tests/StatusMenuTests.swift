// StatusMenuTests: the menu-bar status menu shows the launcher hotkey the
// user set (not a fixed ⌃Space), follows a change, and lists AI Chat right
// after Open Quick Launch. Also the Keep on Top glyph, which is not the pin
// that marks a pinned chat.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Status menu and Keep on Top glyph")
@MainActor
struct StatusMenuTests {

    private func menu(
        _ configure: (inout QuickSettings) -> Void = { _ in },
        isCaffeinating: Bool = false
    ) -> NSMenu {
        var settings = QuickSettings()
        configure(&settings)
        return StatusMenu.make(
            StatusMenu.State(
                settings: settings,
                isCaffeinating: isCaffeinating,
                screenHistory: ScreenHistoryStatusPresentation.make(status: nil),
                version: "1.5.0"
            ),
            target: nil,
            action: nil
        )
    }

    @Test func openQuickLaunchShowsTheDefaultOptionSpace() throws {
        let open = try #require(menu().items.first)
        #expect(open.title == "Open Quick Launch")
        #expect(open.keyEquivalent == " ")
        #expect(open.keyEquivalentModifierMask == .option, "the default is ⌥Space, not ⌃Space")
    }

    @Test func openQuickLaunchFollowsTheConfiguredHotkey() throws {
        // ⌘⇧K, then a change to ⌃F5: the menu is built from settings each time.
        let first = try #require(menu {
            $0.hotkeyKeyCode = 40
            $0.hotkeyModifiers = NSEvent.ModifierFlags([.command, .shift]).rawValue
        }.items.first)
        #expect(first.keyEquivalent == "k")
        #expect(first.keyEquivalentModifierMask == [.command, .shift])

        let changed = try #require(menu {
            $0.hotkeyKeyCode = 96
            $0.hotkeyModifiers = NSEvent.ModifierFlags.control.rawValue
        }.items.first)
        #expect(changed.keyEquivalent == String(Character(UnicodeScalar(NSF5FunctionKey)!)))
        #expect(changed.keyEquivalentModifierMask == .control)
    }

    @Test func aKeyTheMenuCannotDrawShowsNoKeyRatherThanAWrongOne() throws {
        let open = try #require(menu {
            $0.hotkeyKeyCode = 200
            $0.hotkeyModifiers = NSEvent.ModifierFlags.option.rawValue
        }.items.first)
        #expect(open.keyEquivalent.isEmpty)
    }

    @Test func aiChatSitsRightAfterOpenQuickLaunch() {
        let titles = menu().items.filter { !$0.isSeparatorItem }.prefix(4).map(\.title)
        #expect(titles == ["Open Quick Launch", "AI Chat", "Settings…", "Turn Caffeinate On"])
        #expect(menu(isCaffeinating: true).items[3].title == "Turn Caffeinate Off")
        #expect(menu(isCaffeinating: true).items[3].state == .on)
    }

    @Test func everyActionItemCarriesItsCommand() {
        let items = menu().items.filter { $0.tag != 0 }
        let commands = items.compactMap { StatusMenu.Command(rawValue: $0.tag) }
        #expect(Set(commands) == Set(StatusMenu.Command.allCases))
        #expect(commands.first == .openQuickLaunch)
        #expect(commands[1] == .openAIChat)
    }

    @Test func aStoppedScreenHistoryControlIsDisabled() throws {
        let menu = menu()
        #expect(!menu.autoenablesItems)
        let stop = try #require(menu.items.first { $0.tag == StatusMenu.Command.stopScreenHistory.rawValue })
        #expect(!stop.isEnabled)
    }

    // MARK: - Keep on Top

    @Test func keepOnTopIsNotThePinGlyph() {
        let pinGlyphs: Set<String> = ["pin", "pin.fill", "pin.slash"]
        for action in [QuickAISurfaceAction.keepOnTop, .stopKeepingOnTop] {
            #expect(!pinGlyphs.contains(action.systemImage), "\(action) must not read as a pinned chat")
            #expect(
                NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil) != nil,
                "\(action.systemImage) exists on this macOS"
            )
        }
        #expect(QuickAISurfaceAction.keepOnTop.systemImage == QuickAISurfaceAction.keepOnTopSymbol)
        #expect(ResultAction.pinChat.systemImage == "pin", "the pin stays with pinned chats")
    }

    /// g2- proof: the AI Chat header while the window is kept on top, the
    /// layers glyph beside the new-chat glyph.
    @Test func rendersTheKeptOnTopHeader() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            var settings = QuickSettings()
            settings.appearance = appearance == .darkAqua ? .dark : .light
            settings.autoCopy = false
            settings.historyEnabled = false
            let service = MockQuickService()
            let chat = QuickViewModel(settings: settings, service: service, pasteboard: FakePasteboard())
            let suite = "StatusMenuTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let window = AIChatWindowModel(chat: chat, defaults: defaults)
            window.isAlwaysOnTop = true
            await service.setResponses([StreamDelta(text: "Friday after lunch.", finishReason: "stop")])
            chat.input = "when does it ship?"
            await chat.submit()

            let size = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
            let host = NSHostingView(rootView: AIChatWindowView(model: window).frame(width: size.width, height: size.height))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let dir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent("g2-ai-chat-keep-on-top-\(suffix).png"))
        }
    }
}
