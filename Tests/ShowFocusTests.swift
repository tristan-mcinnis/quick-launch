import AppKit
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Show focus", .serialized)
@MainActor
struct ShowFocusTests {
    private struct Host: View {
        var fields = 1
        @State var text = ""
        var body: some View {
            VStack {
                ForEach(0..<fields, id: \.self) { _ in TextField("Ask", text: $text) }
            }
        }
    }

    private func window(fields: Int) -> NSWindow {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: Host(fields: fields))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return window
    }

    @Test func theLauncherFieldTakesFirstResponderInTheSameTurn() throws {
        let window = window(fields: 1)
        #expect(ShowFocus.focusInput(in: window))
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        // A key typed now reaches the field, not the panel.
        editor.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        #expect(editor.string == "a")
    }

    @Test func aFieldAlreadyHoldingTheKeysIsLeftAlone() throws {
        let window = window(fields: 1)
        #expect(ShowFocus.focusInput(in: window))
        let editor = try #require(window.firstResponder)
        #expect(!ShowFocus.focusInput(in: window))
        #expect(window.firstResponder === editor)
    }

    @Test func twoCandidatesLeaveFocusForTheFallback() {
        let window = window(fields: 2)
        #expect(!ShowFocus.focusInput(in: window))
    }

    @Test func noFieldLeavesFocusForTheFallback() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSView()
        #expect(!ShowFocus.focusInput(in: window))
    }

    @Test func theRealOverlayShowsOneFieldInLauncherAndQuickAI() throws {
        for quickAI in [false, true] {
            let vm = QuickViewModel(settings: QuickSettings(), service: MockQuickService(), pasteboard: FakePasteboard())
            vm.isQuickAIPresented = quickAI
            let size = CGSize(width: PanelSizing.panelWidth, height: 500)
            let host = NSHostingView(rootView: OverlayView(viewModel: vm).frame(width: size.width, height: size.height))
            host.frame = NSRect(origin: .zero, size: size)
            let native = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            native.isReleasedWhenClosed = false
            native.contentView = host
            host.layoutSubtreeIfNeeded()
            #expect(ShowFocus.focusInput(in: native), "quickAI=\(quickAI)")
            native.close()
        }
    }
}
