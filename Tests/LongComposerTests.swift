import AppKit
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Long composer drafts", .serialized)
@MainActor
struct LongComposerTests {
    private func model(_ text: String) -> QuickViewModel {
        var settings = QuickSettings()
        settings.historyEnabled = false
        settings.autoCopy = false
        let model = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
        model.isQuickAIPresented = true
        model.input = text
        return model
    }

    private func composerHeight(_ text: String, fullWindow: Bool = false) -> CGFloat {
        let view = QuickAIComposer(viewModel: model(text), multiline: fullWindow)
            .frame(width: PanelSizing.panelWidth)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: PanelSizing.panelWidth, height: PanelSizing.quickAIHeight)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @Test func quickComposerWrapsPastedParagraphsAndCapsItsHeight() {
        let short = composerHeight("One short question")
        let long = composerHeight(String(repeating: "A paragraph that should wrap and remain editable. ", count: 20))
        let huge = composerHeight(String(repeating: "A paragraph that should wrap and remain editable. ", count: 400))
        #expect(long > short + House.Control.pill, "Long text must be visible on multiple lines in Quick AI")
        #expect(abs(huge - long) < House.Spacing.xxs, "After four lines the editor must scroll, not keep growing")
    }

    @Test func quickComposerGrowsForChineseAndUnbrokenText() {
        let short = composerHeight("Short")
        for draft in [String(repeating: "这是一段需要逐行阅读和编辑的中文。", count: 40), String(repeating: "abcdefghij", count: 160)] {
            #expect(composerHeight(draft) > short + House.Control.pill)
        }
    }

    @Test func largeMultilineDraftMovesToAIChatWithoutSendingOrTruncation() {
        let draft = String(repeating: "English paragraph.\n中文段落。\n\n", count: 500)
        let quick = model(draft)
        let full = model("")
        let handoff = quick.makeAIChatHandoff()
        full.adoptAIChatHandoff(handoff)
        #expect(full.input == draft)
        #expect(!full.isStreaming)
        #expect(full.conversationMessages.isEmpty)
    }
    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    @Test func nativeQuickComposerKeepsNewlinesAndDraftNavigation() throws {
        let vm = model("First paragraph\nSecond paragraph")
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let editor = NSTextView(frame: .zero)
        editor.string = vm.input
        panel.contentView = editor
        panel.composerModel = vm
        #expect(panel.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(panel.performKeyEquivalent(with: try key("\r", code: 36, modifiers: [.shift])))
        #expect(editor.string == "First\n paragraph\nSecond paragraph")
        #expect(vm.composerSubmitTask == nil, "Shift–Return must not send the draft")
        #expect(panel.performKeyEquivalent(with: try key("", code: 126, modifiers: [.command])))
        #expect(editor.selectedRange().location == 0)
        #expect(panel.performKeyEquivalent(with: try key("", code: 125, modifiers: [.command])))
        #expect(editor.selectedRange().location == (editor.string as NSString).length)
        #expect(vm.threadScrollRequest == nil)
    }

    @Test func nativeQuickComposerReturnSubmitsTheWholeMultilineDraft() async throws {
        let draft = "Summarize this code:\n\tlet answer = 42\n\tprint(answer)"
        let vm = model(draft)
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let editor = NSTextView(frame: .zero)
        editor.string = draft
        panel.contentView = editor
        panel.composerModel = vm
        #expect(panel.makeFirstResponder(editor))
        panel.sendEvent(try key("\r", code: 36, modifiers: []))
        let submission = try #require(vm.composerSubmitTask)
        await submission.value
        #expect(vm.conversationMessages.first(where: { $0.role == .user })?.content == draft)
    }

    @Test func pastingCodeEndingInAtSignKeepsEveryCharacter() {
        let draft = String(repeating: "\tprint(\"hello\")\n", count: 100) + " @"
        let vm = model(draft)
        vm.quickAIComposerDidChange(draft, allowsContextTrigger: false)
        #expect(vm.input == draft)
        #expect(!vm.isAddContextMenuPresented)
        vm.input = "Ask @"
        vm.quickAIComposerDidChange(vm.input, allowsContextTrigger: true)
        #expect(vm.isAddContextMenuPresented)
        #expect(vm.input == "Ask ")
    }

    @Test func clickingTheDisplayedStopActionStopsInsteadOfQueueingTheDraft() {
        let vm = model("A draft to keep")
        vm.isStreaming = true
        vm.output = "Partial response"
        #expect(vm.quickAIComposerAction.behavior == .stop)
        vm.performComposerPrimaryAction()
        #expect(!vm.isStreaming)
        #expect(vm.input == "A draft to keep")
        #expect(!vm.isFollowUpQueued)
    }

    @Test func clickingAskUsesTheSameSubmitPathAsReturn() async throws {
        let vm = model("Please summarize this paragraph")
        #expect(vm.quickAIComposerAction.behavior == .submit)
        vm.performComposerPrimaryAction()
        let submission = try #require(vm.composerSubmitTask)
        await submission.value
        #expect(vm.conversationMessages.first(where: { $0.role == .user })?.content == "Please summarize this paragraph")
    }

    @Test func inputMethodCompositionKeepsItsReturn() throws {
        let vm = model("ni")
        let editor = NSTextView(frame: .zero)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!QuickAIComposerEditing.handle(try key("\r", code: 36, modifiers: []), editor: editor, model: vm))
        #expect(vm.composerSubmitTask == nil)
    }

    @Test func rendersLongDraftsOnBothSurfacesInBothAppearances() throws {
        let drafts = [
            ("english", String(repeating: "Please summarize this passage and keep its important details. ", count: 40)),
            ("chinese", String(repeating: "请总结这段内容，保留关键的信息。\n这是下一段，应该可以逐行阅读和修改。\n", count: 10)),
            ("unbroken", String(repeating: "abcdefghij", count: 240)),
        ]
        for (appearance, scheme, suffix) in [(NSAppearance.Name.darkAqua, ColorScheme.dark, "dark"), (.aqua, .light, "light")] {
            for (name, draft) in drafts {
                let vm = model(draft)
                try save(OverlayView(viewModel: vm).preferredColorScheme(scheme),
                         size: NSSize(width: PanelSizing.panelWidth, height: PanelSizing.quickAIHeight),
                         appearance: appearance, name: "composer-quick-\(name)-\(suffix)")
                let suite = "LongComposerTests.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let full = AIChatWindowModel(chat: vm, defaults: defaults)
                try save(AIChatWindowView(model: full).preferredColorScheme(scheme),
                         size: NSSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight),
                         appearance: appearance, name: "composer-full-\(name)-\(suffix)")
            }
        }
    }

    @Test func longDraftAndAttachmentsKeepTheEntireAttachMenuInsideTheWindow() async throws {
        for (appearance, scheme, suffix) in [(NSAppearance.Name.darkAqua, ColorScheme.dark, "dark"), (.aqua, .light, "light")] {
            for fullWindow in [false, true] {
                var settings = QuickSettings()
                settings.historyEnabled = false
                let vm = QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard(), attachmentExtractor: FakeAttachmentExtractor())
                vm.openQuickAI()
                vm.input = String(repeating: "Please compare these references carefully.\n", count: 20)
                vm.launchSelection = .init(text: "A selected passage that also stays attached to this draft.", appName: "Finder")
                vm.rememberSelectionTarget(.init(processIdentifier: 42, applicationName: "Finder"))
                vm.attachmentTray.add(.file(URL(fileURLWithPath: "/tmp/Composer reference.txt")))
                await vm.attachmentTray.waitUntilRead()
                let suite = "LongComposerStress.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let full = fullWindow ? AIChatWindowModel(chat: vm, defaults: defaults) : nil
                vm.openAddContextMenu()
                vm.attachmentTray.finderIsBehind = true
                #expect(vm.addContextRows.count == 7)
                let width = fullWindow ? House.Layout.chatMinWidth : PanelSizing.panelWidth
                let height = fullWindow ? House.Layout.chatMinHeight : PanelSizing.quickAIHeight
                let header = fullWindow ? AIChatWindowView.titleBarHeight : QuickAIView.headerHeight
                let composer = NSHostingView(rootView: QuickAIComposer(viewModel: vm, multiline: fullWindow).frame(width: width))
                let composerHeight = composer.fittingSize.height
                let remaining = height - composerHeight - header - House.Spacing.xs
                let pane = NSHostingView(rootView: QuickAIFloatingChooser(viewModel: vm, composerHeight: 0)
                    .environment(\.composerPaneMaximumHeight, remaining).frame(width: width))
                #expect(pane.fittingSize.height <= remaining, "The menu must scroll within the space above the entire composer")
                if let full {
                    try save(AIChatWindowView(model: full).preferredColorScheme(scheme), size: NSSize(width: width, height: height), appearance: appearance, name: "composer-stress-full-\(suffix)")
                } else {
                    try save(OverlayView(viewModel: vm).preferredColorScheme(scheme), size: NSSize(width: width, height: height), appearance: appearance, name: "composer-stress-quick-\(suffix)")
                }
                vm.closeAddContextMenu()
                vm.toggleActionPalette()
                let actions = NSHostingView(rootView: QuickActionPalette(viewModel: vm)
                    .environment(\.composerPaneMaximumHeight, remaining).frame(width: PanelSizing.actionPaletteWidth))
                #expect(actions.fittingSize.height <= remaining, "Action search and hints must fit above the composer too")
                if let full {
                    try save(AIChatWindowView(model: full).preferredColorScheme(scheme), size: NSSize(width: width, height: height), appearance: appearance, name: "composer-actions-stress-full-\(suffix)")
                } else {
                    try save(OverlayView(viewModel: vm).preferredColorScheme(scheme), size: NSSize(width: width, height: height), appearance: appearance, name: "composer-actions-stress-quick-\(suffix)")
                }
            }
        }
    }

    private func save<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name, name: String) throws {
        let host = NSHostingView(rootView: view.background(House.ColorToken.surface))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent(name + ".png"))
    }

}
