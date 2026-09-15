import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

// This proof takes native keyboard focus. Run alone so other suites' windows
// cannot steal it: QUICK_LAUNCH_NATIVE_FOCUS_PROOF=1 swift test --filter PaletteRailFocusProofTests
@Suite("Palette rail focus proof", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["QUICK_LAUNCH_NATIVE_FOCUS_PROOF"] == "1"))
@MainActor
struct PaletteRailFocusProofTests {
    @Test func openingRowActionsMovesTypingIntoActionSearch() async throws {
        // The real SwiftUI rail in a native window: exercise focus ownership,
        // since directly setting railActionQuery cannot catch a lost cursor.
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.appearance = .dark
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
        vm.history = [QuickConversation(
            providerID: settings.providers[0].id,
            model: "test-model",
            messages: [QuickMessage(role: .user, content: "Example chat")],
            isPinned: true
        )]
        let suite = "PaletteRailFocusProofTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AIChatWindowModel(chat: vm, defaults: defaults)
        model.showRail()
        let size = CGSize(width: House.Layout.chatRail, height: House.Layout.chatHeight)
        let host = NSHostingView(rootView: AIChatRail(model: model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let native = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        native.isReleasedWhenClosed = false
        native.contentView = host
        native.makeKeyAndOrderFront(nil)
        defer { native.orderOut(nil); native.close() }
        try await settle(host)
        model.toggleRailActions()
        try await settle(host)
        let editor = try #require(native.firstResponder as? NSTextView)
        editor.insertText("UNPN", replacementRange: NSRange(location: 0, length: 0))
        try await settle(host)
        #expect(model.railActionQuery == "UNPN")
        #expect(model.railQuery.isEmpty)
        #expect(model.filteredRailActions == [.pin])
        #expect(model.focus == .rail)

        let folder = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            host.appearance = NSAppearance(named: appearance)
            try await settle(host)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("palette-rail-unpin-\(name).png"))
        }

        #expect(model.handleEscape())
        try await settle(host)
        let railEditor = try #require(native.firstResponder as? NSTextView)
        railEditor.insertText("Example", replacementRange: NSRange(location: 0, length: 0))
        try await settle(host)
        #expect(model.railQuery == "Example", "Escape restores the chat-list search")
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
    }
}
