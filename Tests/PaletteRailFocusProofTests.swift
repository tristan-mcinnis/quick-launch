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

    /// Add Context and the Capture chooser each open a search field that
    /// owns the keyboard: typing lands in the pane's query, not in the
    /// composer draft behind it.
    @Test func openingAChooserMovesTypingIntoItsOwnSearch() async throws {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        settings.appearance = .dark
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
        vm.rememberSelectionTarget(SelectionTarget(processIdentifier: 42, applicationName: "Editor"))
        let size = CGSize(width: PanelSizing.panelWidth, height: PanelSizing.quickAIHeight + 220)
        let host = NSHostingView(rootView: OverlayView(viewModel: vm).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let native = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        native.isReleasedWhenClosed = false
        native.contentView = host
        native.makeKeyAndOrderFront(nil)
        defer { native.orderOut(nil); native.close() }
        try await settle(host)

        // The composer holds the keys at rest.
        let composer = try #require(native.firstResponder as? NSTextView)
        composer.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
        try await settle(host)
        #expect(vm.input == "draft")

        // Add Context opens and its own field takes the keyboard.
        vm.openAddContextMenu()
        try await settle(host)
        let addContextEditor = try #require(native.firstResponder as? NSTextView)
        addContextEditor.insertText("link", replacementRange: NSRange(location: 0, length: 0))
        try await settle(host)
        #expect(vm.addContextQuery == "link")
        #expect(vm.input == "draft", "the half-typed question is untouched")
        #expect(vm.addContextRows == [.link])

        // Escape closes the pane and the composer gets its place back.
        #expect(vm.handleEscapeKey())
        try await settle(host)
        let restored = try #require(native.firstResponder as? NSTextView)
        restored.insertText(" more", replacementRange: NSRange(location: restored.string.count, length: 0))
        try await settle(host)
        #expect(vm.input == "draft more", "Escape restores the composer")
        #expect(vm.addContextQuery.isEmpty)

        // The Capture chooser is the same.
        vm.openCaptureChooser()
        try await settle(host)
        let captureEditor = try #require(native.firstResponder as? NSTextView)
        captureEditor.insertText("selected", replacementRange: NSRange(location: 0, length: 0))
        try await settle(host)
        #expect(vm.captureChooserQuery == "selected")
        #expect(vm.captureChooserOptions == [.selectedText, .selectedArea])
        #expect(vm.input == "draft more", "the draft is still untouched")
    }

    /// The same chooser in the AI Chat window: its floating panes take the
    /// keyboard from the window's composer the same way.
    @Test func theAIChatWindowChooserSearchTakesTheKeyboardToo() async throws {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
        vm.rememberSelectionTarget(SelectionTarget(processIdentifier: 42, applicationName: "Editor"))
        let suite = "ChooserSearchAIChatFocus.\\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AIChatWindowModel(chat: vm, defaults: defaults)
        defer { withExtendedLifetime(model) {} }

        let size = CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
        let host = NSHostingView(rootView: AIChatWindowView(model: model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let native = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        native.isReleasedWhenClosed = false
        native.contentView = host
        native.makeKeyAndOrderFront(nil)
        defer { native.orderOut(nil); native.close() }
        try await settle(host)

        let composer = try #require(native.firstResponder as? NSTextView)
        composer.insertText("draft", replacementRange: NSRange(location: 0, length: 0))
        try await settle(host)
        #expect(vm.input == "draft")

        vm.openAddContextMenu()
        try await settle(host)
        let editor = try #require(native.firstResponder as? NSTextView)
        editor.insertText("link", replacementRange: NSRange(location: 0, length: 0))
        try await settle(host)
        #expect(vm.addContextQuery == "link")
        #expect(vm.input == "draft", "the window composer draft is untouched")
        #expect(vm.addContextRows == [.link])
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
    }
}
