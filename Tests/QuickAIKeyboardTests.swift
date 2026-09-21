// QuickAIKeyboardTests — keyboard routing proof for the Quick AI overlay.
//
// Every other suite that covers a shortcut calls the view-model method the key
// is supposed to reach (`performShortcut`, `handleEscapeKey`, `handleTab`).
// That proves the destination works and proves nothing about the routing.
//
// This suite builds a real `KeyablePanel` wired with the closures
// `AppDelegate.makePanel` installs (Sources/App/AppDelegate.swift:514-544),
// builds real `NSEvent`s, and pushes them through the panel's own
// `performKeyEquivalent(with:)` / `sendEvent(_:)`. Assertions read only
// observable state: which layer is on top, what the action list holds, what
// the composer holds, what the fake pasteboard or selection service received.
//
// Three key sources cannot be driven from a real `NSEvent` in-process, because
// they are SwiftUI handlers on the composer's `TextField`, not window-level key
// handling:
//   * Tab (OverlayView.swift:53-55) calls `viewModel.handleTab()`
//   * the `@` trigger (OverlayView.swift:125-131) calls
//     `viewModel.addContextTriggerDidChange(newValue)`
//   * plain Return (OverlayView.swift:52 `.onSubmit`) calls
//     `viewModel.submitResolvingFuzzyAlias()`. The panel's `returnHandler` is
//     only reached by ⇧↩ with no translation direction (AppDelegate.swift:67-77),
//     which lands on that identical entry point — one test proves that route
//     with a real event.
// Those are driven at that call, with the same argument the view passes, which
// is one level below the key press. Everything else in this suite is a real
// event through the real panel.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import QuickLaunch

@Suite("Quick AI keyboard routing", .serialized)
@MainActor
struct QuickAIKeyboardTests {

    // MARK: - Fixtures

    private let target = SelectionTarget(processIdentifier: 4242, applicationName: "Editor")

    /// Test defaults: no auto-copy so a copied answer is only ever the one the
    /// key asked for, and no history file so nothing leaks between runs.
    private func settings(_ configure: (inout QuickSettings) -> Void = { _ in }) -> QuickSettings {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        configure(&settings)
        return settings
    }

    /// A panel sitting on a finished answer, the state every answer-layer
    /// shortcut is defined against.
    private func answered(
        reply: String = "An answer.",
        settings configure: (inout QuickSettings) -> Void = { _ in }
    ) async throws -> (KeyboardOverlay, MockQuickService) {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        let overlay = KeyboardOverlay(settings: settings(configure), service: service)
        overlay.viewModel.input = "what happened"
        await overlay.viewModel.submit()
        #expect(overlay.viewModel.topLayer == .answer)
        return (overlay, service)
    }

    /// The panel's handlers start async work in `Task { @MainActor … }` closures,
    /// exactly as the running overlay does. Wait for the observable outcome to
    /// land rather than assuming a scheduling order; the deadline reports a
    /// failure instead of hanging.
    private func waitFor(
        _ timeout: Duration = .seconds(15),
        _ condition: @MainActor () async -> Bool
    ) async -> Bool {
        // Generous on purpose: this box may be running several builds and
        // suites at once, and a correct test that waits longer costs nothing.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        if await condition() { return true }
        // Say the timeout out loud. A silent give-up lets the caller's own
        // assertions report the symptom instead of the wait that failed.
        Issue.record("waitFor timed out after \(timeout)")
        return false
    }

    // MARK: - 1. Answer-layer shortcuts

    @Test func shiftCommandROpensTheRegenerateModelChooser() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel

        #expect(try overlay.press("r", keyCode: 15, [.command, .shift]))
        #expect(await waitFor { viewModel.isModelChooserPresented })

        #expect(viewModel.modelChooserPurpose == .regenerate)
        #expect(viewModel.topLayer == .modelChooser)
        #expect(!viewModel.modelChooserOptions.isEmpty)
        #expect(viewModel.output == "An answer.", "opening the chooser changes nothing else")
    }

    @Test func commandShiftOOpensChangeModelWithoutAskingAgain() async throws {
        let (overlay, service) = try await answered()
        let viewModel = overlay.viewModel

        #expect(try overlay.press("o", keyCode: 31, [.command, .shift]))
        #expect(await waitFor { viewModel.isModelChooserPresented })

        #expect(viewModel.modelChooserPurpose == .change)
        #expect(viewModel.topLayer == .modelChooser)
        #expect(await service.sendCallCount == 1, "Change Model picks, it never re-asks")
    }

    @Test func optionCommandVRunsReplaceSelectionOnTheRetainedSelection() async throws {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "shorter text", finishReason: "stop")])
        let overlay = KeyboardOverlay(
            settings: settings(),
            service: service,
            selectionText: "a much longer passage"
        )
        let viewModel = overlay.viewModel
        viewModel.rememberSelectionTarget(target)
        viewModel.captureLaunchSelection()
        viewModel.input = "/shorter"
        await overlay.submitLikeReturn()
        #expect(viewModel.resultActions.contains(.replaceSelection), "the selection is still replaceable")
        let answer = viewModel.output

        // `⇧⌘V` was the key until it turned out to be Clipboard History's
        // global hotkey, which wins system-wide. It is dead here now.
        #expect(!(try overlay.press("v", keyCode: 9, [.command, .shift])))
        #expect(overlay.selection.replacedText == nil, "the old key writes nothing back")

        #expect(try overlay.press("v", keyCode: 9, [.command, .option]))

        #expect(await waitFor { overlay.selection.replacedText == answer })
        #expect(overlay.selection.replacedText == answer)
        #expect(viewModel.output == answer)
    }

    @Test func commandRRegeneratesOnTheSameModel() async throws {
        let (overlay, service) = try await answered()
        let viewModel = overlay.viewModel
        let model = viewModel.activeModelDisplay
        await service.setResponses([StreamDelta(text: "Second answer.", finishReason: "stop")])

        #expect(try overlay.press("r", keyCode: 15, [.command]))

        #expect(await waitFor { await service.sendCallCount == 2 })
        #expect(await waitFor { viewModel.output == "Second answer." })
        #expect(await service.lastPrompt == "what happened", "the same question goes out again")
        #expect(viewModel.activeModelDisplay == model, "⌘R stays on the model in use")
    }

    @Test func commandNStartsANewChatOnTheSurface() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel

        #expect(try overlay.press("n", keyCode: 45, [.command]))

        #expect(await waitFor { viewModel.currentConversation == nil })
        #expect(viewModel.output.isEmpty)
        #expect(viewModel.isQuickAIPresented, "a new chat starts in Quick AI, not in root search")
        #expect(viewModel.topLayer == .answer)
        #expect(viewModel.quickAITitle == "Quick AI")
    }

    @Test func commandBracketsStepThroughChats() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel
        let current = try #require(viewModel.currentConversation)
        let older = QuickConversation(
            updatedAt: current.updatedAt.addingTimeInterval(-120),
            providerID: InferenceProvider.deepSeekID,
            model: "older-model",
            messages: [
                QuickMessage(role: .user, content: "older question"),
                QuickMessage(role: .assistant, content: "older answer"),
            ]
        )
        viewModel.history = [older, current]
        #expect(viewModel.resultActions.contains(.previousChat))
        #expect(viewModel.resultActions.contains(.nextChat))

        #expect(try overlay.press("[", keyCode: 33, [.command]))
        #expect(await waitFor { viewModel.currentConversation?.id == older.id })
        #expect(viewModel.output == "older answer", "the older chat's answer comes with it")
        #expect(viewModel.activeModelDisplay == "older-model")

        #expect(try overlay.press("]", keyCode: 30, [.command]))
        #expect(await waitFor { viewModel.currentConversation?.id == current.id })
        #expect(viewModel.output == "An answer.")
    }

    @Test func commandPOpensAndClosesRecentChats() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel

        #expect(try overlay.press("p", keyCode: 35, [.command]))
        #expect(viewModel.isRecentChatsPresented)
        #expect(viewModel.isQuickAIPresented, "Recent Chats lives inside the Quick AI window")
        #expect(viewModel.topLayer == .recentChats)
        #expect(!viewModel.conversationMessages.isEmpty)
        #expect(viewModel.currentPanelWidth == PanelSizing.panelWidth, "one column, no split view")

        #expect(try overlay.press("p", keyCode: 35, [.command]))
        #expect(!viewModel.isRecentChatsPresented)
        #expect(viewModel.isQuickAIPresented, "back to the thread")
        #expect(viewModel.output == "An answer.", "leaving the list keeps the thread")
        #expect(viewModel.currentConversation != nil)
    }

    @Test func commandKOpensAndClosesTheActionPanel() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel

        #expect(try overlay.press("k", keyCode: 40, [.command]))
        #expect(viewModel.isActionPalettePresented)
        #expect(viewModel.topLayer == .actionPalette)
        #expect(viewModel.paletteResultActions.contains(.regenerate))
        #expect(viewModel.paletteResultActions.contains(.newChat))

        #expect(try overlay.press("k", keyCode: 40, [.command]))
        #expect(!viewModel.isActionPalettePresented)
        #expect(viewModel.output == "An answer.")
    }

    // MARK: - 2. Escape closes exactly one layer

    @Test func escapeClosesTheModelChooserFirstAndNothingElse() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel
        #expect(try overlay.press("r", keyCode: 15, [.command, .shift]))
        #expect(await waitFor { viewModel.topLayer == .modelChooser })

        try overlay.pressEscape()

        #expect(!viewModel.isModelChooserPresented)
        #expect(viewModel.topLayer == .answer, "the answer layer was underneath all along")
        #expect(viewModel.output == "An answer.")
        #expect(viewModel.currentConversation != nil)
        #expect(overlay.presenter.dismissCount == 0, "Escape never reaches past the top layer")
    }

    @Test func escapeClosesACommandKItemPane() async throws {
        let overlay = KeyboardOverlay(
            settings: settings(),
            applicationCatalog: KeyboardApplicationCatalog()
        )
        let viewModel = overlay.viewModel
        viewModel.input = "saf"
        #expect(!viewModel.launcherMatches.isEmpty)

        #expect(try overlay.press("k", keyCode: 40, [.command]))
        #expect(viewModel.isItemActionPanePresented)
        #expect(viewModel.topLayer == .itemActionPane)
        #expect(viewModel.focusedItemActions.map(\.title).contains("Set Alias…"))

        try overlay.pressEscape()

        #expect(!viewModel.isItemActionPanePresented)
        #expect(!viewModel.launcherMatches.isEmpty, "the list underneath is untouched")
        #expect(viewModel.input == "saf")
        #expect(overlay.presenter.dismissCount == 0)
    }

    @Test func escapeLeavesAFormBackOnTheActionListBeforeClosingThePane() async throws {
        let overlay = KeyboardOverlay(
            settings: settings(),
            applicationCatalog: KeyboardApplicationCatalog()
        )
        let viewModel = overlay.viewModel
        viewModel.input = "saf"
        #expect(try overlay.press("k", keyCode: 40, [.command]))
        #expect(try overlay.press("a", keyCode: 0, [.command, .shift]))
        #expect(viewModel.activeItemActionForm == .alias)
        #expect(viewModel.topLayer == .itemActionForm)

        try overlay.pressEscape()

        #expect(viewModel.activeItemActionForm == nil)
        #expect(viewModel.isItemActionPanePresented, "the pane, and its action list, survive")
        #expect(viewModel.topLayer == .itemActionPane)
        #expect(viewModel.focusedItemActions.map(\.title).contains("Set Hotkey…"))

        try overlay.pressEscape()

        #expect(!viewModel.isItemActionPanePresented)
        #expect(viewModel.input == "saf", "the typed query is still in the composer")
        #expect(viewModel.topLayer == .typedText)
        #expect(overlay.presenter.dismissCount == 0)
    }

    @Test func escapeClosesRecentChatsAndKeepsTheThread() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel
        #expect(try overlay.press("p", keyCode: 35, [.command]))
        #expect(viewModel.topLayer == .recentChats)

        try overlay.pressEscape()

        #expect(!viewModel.isRecentChatsPresented)
        #expect(viewModel.isQuickAIPresented)
        #expect(viewModel.output == "An answer.")
        #expect(viewModel.currentConversation != nil)
        #expect(overlay.presenter.dismissCount == 0)
    }

    @Test func escapeWalksTheWholeStackOneLayerAtATimeAndNeverRestartsTheChat() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel
        let conversation = try #require(viewModel.currentConversation)

        #expect(try overlay.press("p", keyCode: 35, [.command]))
        #expect(try overlay.press("r", keyCode: 15, [.command, .shift]))
        #expect(await waitFor { viewModel.topLayer == .modelChooser })

        try overlay.pressEscape()
        #expect(viewModel.topLayer == .recentChats, "the chooser goes, the list stays")

        try overlay.pressEscape()
        #expect(!viewModel.isRecentChatsPresented)
        #expect(viewModel.topLayer == .answer, "the list goes, the thread stays")
        #expect(viewModel.currentConversation?.id == conversation.id)

        try overlay.pressEscape()
        #expect(!viewModel.isQuickAIPresented, "the surface goes, root search is back")
        #expect(viewModel.topLayer == .root)
        #expect(overlay.presenter.dismissCount == 0)
        #expect(viewModel.output == "An answer.", "Escape never discards the thread")
        #expect(viewModel.currentConversation?.id == conversation.id)

        try overlay.pressEscape()
        #expect(overlay.presenter.dismissCount == 1, "only the last Escape hides the overlay")
        #expect(viewModel.currentConversation?.id == conversation.id)
    }

    @Test func escapeOnAnAnswerReturnsToRootSearchAndKeepsTheThread() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel
        #expect(viewModel.topLayer == .answer)

        try overlay.pressEscape()

        #expect(overlay.presenter.dismissCount == 0, "the first Escape leaves the surface, not the window")
        #expect(!viewModel.isQuickAIPresented)
        #expect(viewModel.topLayer == .root)
        #expect(viewModel.output == "An answer.", "the thread is kept")
        #expect(!viewModel.launcherMatches.isEmpty, "root search shows its rows again")

        try overlay.pressEscape()
        #expect(overlay.presenter.dismissCount == 1, "the second Escape hides the overlay")
        #expect(overlay.presenter.presentCount == 0)
    }

    @Test func escapeWhileStreamingStopsAndStaysOnTheSurface() async throws {
        let service = MockQuickService()
        let overlay = KeyboardOverlay(settings: settings(), service: service)
        let viewModel = overlay.viewModel
        viewModel.isStreaming = true
        viewModel.streamingStatus = "Thinking…"
        #expect(viewModel.isQuickAIPresented, "streaming presents the surface")
        #expect(viewModel.quickAIComposerAction == .init(label: "Stop", keys: ["esc"], behavior: .stop))

        try overlay.pressEscape()

        #expect(!viewModel.isStreaming)
        #expect(viewModel.isQuickAIPresented, "stopping keeps the surface open")
        #expect(overlay.presenter.dismissCount == 0)
    }

    @Test func escapeAtAnEmptyRootHidesTheOverlay() throws {
        let overlay = KeyboardOverlay(settings: settings())
        #expect(overlay.viewModel.topLayer == .root)

        try overlay.pressEscape()

        #expect(overlay.presenter.dismissCount == 1)
        #expect(overlay.viewModel.topLayer == .root)
    }

    // MARK: - 3. The `@` trigger

    /// The composer routes every keystroke through `.onChange(of: viewModel.input)`
    /// (OverlayView.swift:125-131), which calls `addContextTriggerDidChange`
    /// with the new field value. A test cannot type into the SwiftUI field
    /// editor, so the trigger is driven with the value the view would pass.
    @discardableResult
    private func type(_ text: String, into viewModel: QuickViewModel) -> Bool {
        viewModel.input = text
        return viewModel.addContextTriggerDidChange(text)
    }

    @Test func typingAtOpensTheContextMenuAndDropsTheAt() throws {
        let overlay = KeyboardOverlay(settings: settings())
        let viewModel = overlay.viewModel
        viewModel.input = "summarize this "

        #expect(type("summarize this @", into: viewModel))

        #expect(viewModel.isAddContextMenuPresented)
        #expect(viewModel.topLayer == .addContextMenu)
        #expect(viewModel.input == "summarize this ", "the @ is a trigger, not content")
        #expect(viewModel.addContextOptions == AddContextEntry.allCases)
        #expect(viewModel.addContextOptions.map(\.title) == [
            "Focused Window", "Selected Text", "Selected Area", "Entire Screen",
        ])
    }

    @Test func anAtInsideAWordOrAddressNeverOpensTheMenu() throws {
        let overlay = KeyboardOverlay(settings: settings())
        let viewModel = overlay.viewModel

        for typed in ["me@", "alice@", "user@", "a@b", "https://example.com/@", "https://x.com?q=@"] {
            viewModel.input = ""
            #expect(!type(typed, into: viewModel), "\(typed) must not open Add Context")
            #expect(!viewModel.isAddContextMenuPresented)
            #expect(viewModel.input == typed, "\(typed) keeps its @")
        }
    }

    @Test func anAtOnItsOwnIsStillATrigger() throws {
        let overlay = KeyboardOverlay(settings: settings())
        let viewModel = overlay.viewModel

        #expect(type("@", into: viewModel))
        #expect(viewModel.isAddContextMenuPresented)
        #expect(viewModel.input.isEmpty)
    }

    // MARK: - 4. Tab in root search

    /// Tab arrives from the composer's `.onKeyPress(.tab)` (OverlayView.swift:53-55),
    /// which calls `handleTab()` and consumes the key when it returns true.
    @Test func tabCompletesAFuzzySavedPromptAliasWhenOneMatches() throws {
        let overlay = KeyboardOverlay(settings: settings())
        let viewModel = overlay.viewModel
        viewModel.input = "/gr"
        #expect(!viewModel.savedPromptMatches.isEmpty)

        #expect(viewModel.handleTab())

        #expect(viewModel.inputMode == nil, "completion does not switch to Ask AI")
        #expect(viewModel.input.hasPrefix("/grammar"))
        #expect(viewModel.topLayer != .inputMode)
    }

    @Test func tabOpensQuickAIAndSubmitsTheTypedText() async throws {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Hello.", finishReason: "stop")])
        let overlay = KeyboardOverlay(settings: settings(), service: service)
        let viewModel = overlay.viewModel
        viewModel.input = "hi"

        #expect(viewModel.handleTab())

        #expect(viewModel.isQuickAIPresented, "the surface opens in the same gesture")
        #expect(viewModel.launcherMatches.isEmpty, "the launcher rows step aside")
        #expect(viewModel.currentPanelWidth == PanelSizing.panelWidth)
        #expect(viewModel.estimatedWindowHeight == PanelSizing.quickAIHeight)
        await viewModel.tabSubmitTask?.value
        #expect(await service.sendCallCount == 1, "Tab submits; nothing is staged for editing")
        #expect(await service.lastPrompt == "hi")
        #expect(viewModel.output == "Hello.")
        #expect(viewModel.input.isEmpty, "the composer is spent by the submit")
        #expect(viewModel.topLayer == .answer)
    }

    @Test func tabOpensQuickAIEmptyFromAnEmptyField() throws {
        let overlay = KeyboardOverlay(settings: settings())
        let viewModel = overlay.viewModel
        viewModel.input = ""

        #expect(viewModel.handleTab())

        #expect(viewModel.isQuickAIPresented)
        #expect(viewModel.input.isEmpty)
        #expect(viewModel.tabSubmitTask == nil, "nothing to send")
        #expect(viewModel.output.isEmpty)
        #expect(viewModel.quickAITitle == "Quick AI")
        #expect(viewModel.topLayer == .answer)
        #expect(viewModel.quickAIComposerAction == .init(label: "Ask", keys: ["↩"]))
        #expect(viewModel.currentPanelWidth == PanelSizing.panelWidth)
        #expect(viewModel.estimatedWindowHeight == PanelSizing.quickAIHeight)
    }

    // MARK: - 5. The Tab hint

    @Test func theTabHintFollowsTheSettingAndTabStillEntersAskAIWhenHidden() throws {
        let overlay = KeyboardOverlay(settings: settings { $0.tabShortcutHintVisible = true })
        let viewModel = overlay.viewModel

        #expect(viewModel.showsTabShortcutHint)
        #expect(viewModel.askAIItem(query: "").detail.contains("⇥"))
        let withHint = try renderRoot(viewModel)

        viewModel.updateSettings { $0.tabShortcutHintVisible = false }

        #expect(!viewModel.showsTabShortcutHint)
        #expect(!viewModel.askAIItem(query: "").detail.contains("⇥"))
        #expect(!viewModel.askAIItem(query: "").detail.contains("switches to AI"))
        let withoutHint = try renderRoot(viewModel)
        #expect(withHint != withoutHint, "the search row draws differently with the hint off")

        // The hint is a hint: Tab opens Quick AI either way.
        viewModel.input = ""
        #expect(viewModel.handleTab())
        #expect(viewModel.isQuickAIPresented)
        #expect(viewModel.topLayer == .answer)
    }

    /// The root search surface as it is actually drawn, so "which control is
    /// drawn" is checked on pixels rather than on a flag.
    private func renderRoot(_ viewModel: QuickViewModel) throws -> Data {
        let width = viewModel.currentPanelWidth
        let host = NSHostingView(rootView: OverlayView(viewModel: viewModel).frame(width: width))
        host.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: max(host.fittingSize.height, 200))
        )
        host.layoutSubtreeIfNeeded()
        let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        return try #require(representation.representation(using: .png, properties: [:]))
    }

    // MARK: - 6. Return runs the configured primary action

    @Test func returnCopiesWhenCopyIsThePrimaryAction() async throws {
        let (overlay, _) = try await answered { $0.quickAIPrimaryAction = .copyToClipboard }
        let viewModel = overlay.viewModel
        let answer = viewModel.output

        await overlay.submitLikeReturn()

        #expect(overlay.pasteboard.string == answer)
        #expect(overlay.selection.pastedText == nil, "copy never pastes")
        #expect(viewModel.output == answer, "the answer stays on screen")
        #expect(viewModel.topLayer == .answer)
    }

    @Test func returnPastesWhenPasteIsThePrimaryAction() async throws {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "An answer.", finishReason: "stop")])
        let overlay = KeyboardOverlay(
            settings: settings { $0.quickAIPrimaryAction = .pasteToActiveApp },
            service: service
        )
        let viewModel = overlay.viewModel
        viewModel.rememberSelectionTarget(target)
        viewModel.input = "what happened"
        await viewModel.submit()
        let answer = viewModel.output

        await overlay.submitLikeReturn()

        #expect(overlay.selection.pastedText == answer)
        #expect(overlay.selection.pastedTarget == target)
        #expect(overlay.presenter.dismissCount == 1, "a successful paste closes the overlay")
        #expect(overlay.pasteboard.string == nil, "a successful paste does not also copy")
    }

    @Test func returnWithTypedTextSubmitsAFollowUpInstead() async throws {
        let (overlay, service) = try await answered()
        let viewModel = overlay.viewModel
        await service.setResponses([StreamDelta(text: "Follow-up.", finishReason: "stop")])
        viewModel.input = "and then?"

        await overlay.submitLikeReturn()

        #expect(await waitFor { viewModel.output == "Follow-up." })
        #expect(await service.sendCallCount == 2)
        #expect(await service.lastPrompt == "and then?")
        #expect(overlay.pasteboard.string == nil, "the primary action never ran")
        #expect(overlay.selection.pastedText == nil)
        #expect(viewModel.input.isEmpty, "the composer is spent by the submit")
    }

    /// The panel's own route to that same entry point: ⇧↩ with no translation
    /// direction installed falls through `translateHandler` to `returnHandler`
    /// (AppDelegate.swift:67-77). This is a real key event through the real
    /// panel, so the wiring above `submitResolvingFuzzyAlias` is proven here.
    @Test func shiftReturnFallsThroughToTheSameSubmitEntryPoint() async throws {
        let (overlay, _) = try await answered { $0.quickAIPrimaryAction = .copyToClipboard }
        let viewModel = overlay.viewModel
        let answer = viewModel.output
        #expect(viewModel.translationDirection == nil, "nothing to translate on an empty composer")

        try await overlay.pressShiftReturn()
        #expect(await waitFor { overlay.pasteboard.string == answer })

        #expect(overlay.pasteboard.string == answer)
    }

    /// A ⇧↩ with no handler installed is not swallowed: routing answers
    /// false, so the key falls through to the responder chain instead of
    /// being consumed with nothing to do. Regression for AppDelegate's
    /// shift-Return branch returning true when both handlers were nil.
    @Test func shiftReturnWithNoHandlerFallsThrough() throws {
        let overlay = KeyboardOverlay(service: MockQuickService())
        overlay.panel.translateHandler = nil
        overlay.panel.returnHandler = nil

        #expect(try overlay.press("\r", keyCode: VirtualKey.return.rawValue, [.shift]) == false)
    }

    // MARK: - 7. Show more and Collapse

    private func longAnswer(lines: Int) -> String {
        (1...lines).map { "line \($0) and a little more text to be sure" }.joined(separator: "\n")
    }

    /// A panel sitting on the answer to `question`.
    private func asked(_ question: String, reply: String) async -> KeyboardOverlay {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: reply, finishReason: "stop")])
        let overlay = KeyboardOverlay(settings: settings(), service: service)
        overlay.viewModel.input = question
        await overlay.viewModel.submit()
        return overlay
    }

    @Test func showMoreAndCollapseSwapOnALongQuestionAndTheShortcutFlipsThem() async throws {
        let text = longAnswer(lines: 14)
        let overlay = await asked(text, reply: "Short.")
        let viewModel = overlay.viewModel
        let message = try #require(viewModel.conversationMessages.first { $0.role == .user })
        #expect(viewModel.keyboardToggleMessageID == message.id, "the long question is the target")

        #expect(viewModel.collapseState(for: message).isCollapsed)
        #expect(viewModel.collapseState(for: message).controlTitle == "Show more")
        #expect(viewModel.collapseState(for: message).displayedText.hasPrefix(text.prefix(40)))
        #expect(viewModel.collapseState(for: message).displayedText.count < text.count)

        #expect(try overlay.press("m", keyCode: 46, [.command, .shift]))
        #expect(viewModel.collapseState(for: message).controlTitle == "Collapse")
        #expect(!viewModel.collapseState(for: message).isCollapsed)
        #expect(viewModel.collapseState(for: message).displayedText == text)
        #expect(viewModel.threadScrollRequest?.messageID == message.id, "Show more brings the head to the top")
        let expandRevision = try #require(viewModel.threadScrollRequest?.revision)

        #expect(try overlay.press("m", keyCode: 46, [.command, .shift]))
        #expect(viewModel.collapseState(for: message).controlTitle == "Show more")
        #expect(viewModel.collapseState(for: message).isCollapsed)
        #expect(viewModel.threadScrollRequest?.messageID == message.id, "Collapse uses the same anchor")
        #expect(viewModel.threadScrollRequest?.revision == expandRevision + 1, "a second request scrolls again")
    }

    @Test func aLongAnswerNeverCollapsesAndTheShortcutLeavesItAlone() async throws {
        let text = longAnswer(lines: 14)
        let (overlay, _) = try await answered(reply: text)
        let viewModel = overlay.viewModel
        let answer = try #require(viewModel.conversationMessages.last)
        #expect(answer.role == .assistant)
        #expect(MessageCollapsePolicy.shouldCollapse(answer.content), "long enough to fold if the user had sent it")

        #expect(!viewModel.collapseState(for: answer).isCollapsible)
        #expect(viewModel.collapseState(for: answer).controlTitle == nil)
        #expect(viewModel.collapseState(for: answer).displayedText == text)
        #expect(viewModel.keyboardToggleMessageID == nil)
        #expect(try overlay.press("m", keyCode: 46, [.command, .shift]) == false,
                "nothing to fold, so the key reaches the field editor")
        #expect(!viewModel.toggleTranscriptMessage(answer.id), "a click cannot fold an answer either")
        #expect(viewModel.threadScrollRequest == nil)
    }

    @Test func aShortAnswerDrawsNeitherControlAndTheShortcutDoesNothing() async throws {
        let (overlay, _) = try await answered(reply: "Short.")
        let viewModel = overlay.viewModel
        let message = try #require(viewModel.conversationMessages.last)

        #expect(!MessageCollapsePolicy.shouldCollapse(message.content))
        #expect(viewModel.collapseState(for: message).controlTitle == nil, "no control at all")
        #expect(!viewModel.collapseState(for: message).isCollapsible)
        #expect(viewModel.keyboardToggleMessageID == nil)

        #expect(try overlay.press("m", keyCode: 46, [.command, .shift]) == false,
                "an unconsumed key still reaches the field editor")
        #expect(viewModel.collapseState(for: message).controlTitle == nil)
        #expect(viewModel.collapseState(for: message).displayedText == "Short.")
    }

    // MARK: - 8. Copy Chat and Change Model keys

    @Test func optionCommandCCopiesTheLabelledChatAndKeepsTheSurface() async throws {
        let (overlay, _) = try await answered(reply: "Everything went to plan.")
        let viewModel = overlay.viewModel
        let model = try #require(viewModel.currentConversation?.model)

        #expect(try overlay.press("c", keyCode: 8, [.command, .option]))
        #expect(await waitFor { overlay.pasteboard.string != nil })
        #expect(overlay.pasteboard.string == """
        You: what happened

        \(ModelProfile.displayName(forModelID: model)): Everything went to plan.
        """)
        #expect(overlay.presenter.dismissCount == 0, "the surface stays open")
        #expect(viewModel.isQuickAIPresented)
        #expect(viewModel.composerConfirmation == "Chat copied")
    }

    @Test func shiftCommandCCopiesTheAnswerAndKeepsTheSurface() async throws {
        let (overlay, _) = try await answered(reply: "Just the answer.")
        #expect(try overlay.press("c", keyCode: 8, [.command, .shift]))
        #expect(await waitFor { overlay.pasteboard.string == "Just the answer." })
        #expect(overlay.presenter.dismissCount == 0, "Copy Answer no longer closes the window")
        #expect(overlay.viewModel.composerConfirmation == "Copied")
    }

    @Test func shiftCommandOChangesTheModelOnTheEmptySurface() throws {
        let overlay = KeyboardOverlay(settings: settings(), service: MockQuickService())
        let viewModel = overlay.viewModel
        viewModel.input = ""
        #expect(viewModel.handleTab())
        #expect(viewModel.isQuickAIPresented)
        #expect(viewModel.output.isEmpty, "no answer yet")

        #expect(try overlay.press("o", keyCode: 31, [.command, .shift]))
        #expect(viewModel.isModelChooserPresented, "the key the empty surface names works before the first answer")
        #expect(viewModel.modelChooserPurpose == .change)
    }

    // MARK: - 6. Phase A2: the thread's keys, Stop and ⌘R, Recent Chats rows

    @Test func commandAndOptionArrowsScrollTheThreadNotTheChats() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel
        let chat = try #require(viewModel.currentConversation)
        viewModel.history = [chat, QuickConversation(
            providerID: InferenceProvider.deepSeekID,
            model: "older-model",
            messages: [QuickMessage(role: .user, content: "older"), QuickMessage(role: .assistant, content: "Older.")]
        )]

        #expect(try overlay.press("\u{F700}", keyCode: VirtualKey.upArrow.rawValue, [.command]))
        #expect(viewModel.threadScrollRequest?.target == .top, "⌘↑ jumps to the top")
        #expect(try overlay.press("\u{F701}", keyCode: VirtualKey.downArrow.rawValue, [.command]))
        #expect(viewModel.threadScrollRequest?.target == .bottom, "⌘↓ jumps to the bottom")
        #expect(try overlay.press("\u{F700}", keyCode: VirtualKey.upArrow.rawValue, [.option]))
        #expect(viewModel.threadScrollRequest?.target == .pageUp, "⌥↑ pages up")
        #expect(try overlay.press("\u{F701}", keyCode: VirtualKey.downArrow.rawValue, [.option]))
        #expect(viewModel.threadScrollRequest?.target == .pageDown, "⌥↓ pages down")
        #expect(try overlay.press("\u{F72D}", keyCode: VirtualKey.pageDown.rawValue, [.function]) == false,
                "an unmodified PageDown reaches the composer's own key handler")
        #expect(viewModel.currentConversation?.id == chat.id, "no arrow switched the chat")
    }

    @Test func commandRAfterStopAsksTheStoppedQuestionAgain() async throws {
        let gated = GatedQuickService(head: "Half an", tail: " answer.")
        let overlay = KeyboardOverlay(settings: settings(), service: gated)
        let viewModel = overlay.viewModel
        viewModel.openQuickAI()
        viewModel.input = "explain the plan"
        let submit = Task { await viewModel.submit() }
        await gated.waitUntilHolding()
        #expect(await waitFor { viewModel.output == "Half an" })

        try overlay.pressEscape()
        await submit.value
        #expect(viewModel.conversationMessages.map(\.content) == ["explain the plan", "Half an"],
                "Escape stopped and kept the question with what arrived")

        #expect(try overlay.press("r", keyCode: 15, [.command]))
        #expect(await waitFor { gated.sendCallCount == 2 })
        #expect(await waitFor { viewModel.output == "The follow-up answer." })
        // Wait on the list this asserts, not only on `output`. The answer is
        // appended to the thread after the streamed output settles, so checking
        // the messages straight after the output check can land in the gap
        // between the two and read a thread holding only the question.
        #expect(await waitFor {
            viewModel.conversationMessages.map(\.content) == ["explain the plan", "The follow-up answer."]
        })
        #expect(viewModel.conversationMessages.map(\.content) == ["explain the plan", "The follow-up answer."])
        #expect(gated.sentMessages.last?.last?.content == "explain the plan", "the same turn went out again")
    }

    @Test func commandKAndShiftCommandPInRecentChatsActOnTheHighlightedRow() async throws {
        let (overlay, _) = try await answered()
        let viewModel = overlay.viewModel
        let open = try #require(viewModel.currentConversation)
        let other = QuickConversation(
            updatedAt: open.updatedAt.addingTimeInterval(-120),
            providerID: InferenceProvider.deepSeekID,
            model: "older-model",
            messages: [QuickMessage(role: .user, content: "other chat"), QuickMessage(role: .assistant, content: "Other.")]
        )
        viewModel.history = [open, other]
        #expect(try overlay.press("p", keyCode: 35, [.command]))
        viewModel.moveRecentChatsSelection(1)
        #expect(viewModel.recentChatItems[viewModel.recentChatsIndex].itemID == other.id.uuidString)

        #expect(try overlay.press("p", keyCode: 35, [.command, .shift]))
        #expect(viewModel.history.first { $0.id == other.id }?.isPinned == true, "⇧⌘P pinned the highlighted chat")
        #expect(viewModel.history.first { $0.id == open.id }?.isPinned == false, "not the open one")
        #expect(viewModel.recentChatItems[viewModel.recentChatsIndex].itemID == other.id.uuidString,
                "the highlight followed the chat to the top")

        #expect(try overlay.press("k", keyCode: 40, [.command]))
        #expect(viewModel.isCatalogActionPanePresented, "⌘K opens the row's pane")
        #expect(!viewModel.isActionPalettePresented, "not the open chat's answer palette")
        #expect(viewModel.focusedItemActions.contains { $0.title == "Unpin" }, "the pane is the pinned row's")
        try overlay.pressEscape()
        #expect(!viewModel.isCatalogActionPanePresented)
        #expect(viewModel.isRecentChatsPresented, "Escape closed the pane and nothing else")
    }

    // MARK: - Editing keys

    /// The launcher panel is key with no Edit menu, so ⌘A and ⌘C must reach
    /// the focused text view through the panel's own routing.
    private func editingPanel() -> (KeyablePanel, RecordingTextView) {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let editor = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        editor.isEditable = true
        editor.string = "the quick brown fox"
        panel.contentView = editor
        return (panel, editor)
    }

    private func editingKeyEvent(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @Test func commandASelectsAllInTheFocusedTextView() throws {
        let (panel, editor) = editingPanel()
        #expect(panel.makeFirstResponder(editor))

        #expect(try panel.performKeyEquivalent(with: editingKeyEvent("a", keyCode: 0)))
        #expect(
            editor.selectedRange() == NSRange(location: 0, length: (editor.string as NSString).length),
            "⌘A selected the whole field"
        )
    }

    @Test func commandCCopiesFromTheFocusedTextView() throws {
        let (panel, editor) = editingPanel()
        #expect(panel.makeFirstResponder(editor))

        #expect(try panel.performKeyEquivalent(with: editingKeyEvent("c", keyCode: 8)))
        #expect(editor.copyCount == 1, "⌘C reached the text view, not only the panel")
    }

    @Test func commandXCutsAnEditableFieldButNeverAnAnswer() throws {
        let (panel, editor) = editingPanel()
        #expect(panel.makeFirstResponder(editor))

        #expect(try panel.performKeyEquivalent(with: editingKeyEvent("x", keyCode: 7)))
        #expect(editor.cutCount == 1, "⌘X reached the editable field")

        // A read-only answer must never be cut: the guard falls through and
        // the panel does not consume the key.
        let answer = RecordingTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        answer.isEditable = false
        answer.string = "an answer"
        panel.contentView = answer
        #expect(panel.makeFirstResponder(answer))
        #expect(!(try panel.performKeyEquivalent(with: editingKeyEvent("x", keyCode: 7))))
        #expect(answer.cutCount == 0)
    }
}

// MARK: - Harness

/// The overlay's real panel, wired with the same closures `AppDelegate.makePanel`
/// installs, so a real `NSEvent` travels the same path the running overlay uses.
@MainActor
private final class KeyboardOverlay {
    let viewModel: QuickViewModel
    let panel: KeyablePanel
    let presenter: KeyboardOverlayPresenter
    let pasteboard: FakePasteboard
    let selection: KeyboardSelectedTextService

    private var pendingReturn: Task<Void, Never>?

    init(
        settings: QuickSettings = QuickSettings(),
        service: (any QuickService)? = nil,
        applicationCatalog: (any ApplicationCatalogServicing)? = nil,
        launcherCatalog: (any LauncherCatalogServicing)? = nil,
        selectionText: String? = nil
    ) {
        _ = NSApplication.shared
        let presenter = KeyboardOverlayPresenter()
        let pasteboard = FakePasteboard()
        let selection = KeyboardSelectedTextService(text: selectionText)
        let viewModel = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection,
            applicationCatalog: applicationCatalog,
            launcherCatalog: launcherCatalog,
            pasteboard: pasteboard
        )
        viewModel.overlayPresenter = presenter
        // Deliberately no content view controller: the assertions read the view
        // model, and `super.performKeyEquivalent` must not need a live window.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 120),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.presenter = presenter
        self.pasteboard = pasteboard
        self.selection = selection
        self.viewModel = viewModel
        self.panel = panel

        // Mirrors Sources/App/AppDelegate.swift:514-544.
        panel.commandKHandler = { [weak viewModel] in
            viewModel?.handleCommandK()
        }
        panel.commandCHandler = { [weak viewModel] in
            guard let viewModel, viewModel.catalogScope != nil else { return false }
            viewModel.copySelectedLauncherItem()
            return true
        }
        panel.screenshotHandler = { _ in }
        panel.shortcutHandler = { [weak viewModel] characters, keyCode, modifiers in
            viewModel?.performShortcut(
                characters: characters,
                keyCode: keyCode,
                modifiers: modifiers
            ) ?? false
        }
        panel.translateHandler = { [weak viewModel] in
            guard let viewModel, viewModel.translationDirection != nil else { return false }
            Task { @MainActor in await viewModel.translateInput() }
            return true
        }
        panel.backspaceHandler = { [weak viewModel] in
            viewModel?.popLayerForEmptyBackspace() ?? false
        }
        panel.escapeHandler = { [weak viewModel] in
            viewModel?.handleEscapeKey() ?? false
        }
        panel.returnHandler = { [weak self] in
            // AppDelegate spawns the same Task; holding it lets the test await
            // the outcome instead of guessing a scheduling order.
            guard let viewModel = self?.viewModel else { return }
            self?.pendingReturn = Task { @MainActor in await viewModel.submitResolvingFuzzyAlias() }
        }
    }

    /// Push a real key event through the panel's own routing. Returns whether
    /// routing consumed the key (`performKeyEquivalent`'s answer).
    @discardableResult
    func press(
        _ characters: String,
        keyCode: UInt16,
        _ modifiers: NSEvent.ModifierFlags = []
    ) throws -> Bool {
        panel.performKeyEquivalent(with: try keyEvent(characters, keyCode, modifiers))
    }

    /// Escape is caught in `sendEvent`, before the SwiftUI field editor can
    /// swallow it, so the event goes in that way.
    func pressEscape() throws {
        panel.sendEvent(try keyEvent("\u{1b}", VirtualKey.escape.rawValue, []))
    }

    /// Return is async in the running app; await the handler's own task.
    func pressShiftReturn() async throws {
        _ = try press("\r", keyCode: VirtualKey.return.rawValue, [.shift])
        let task = pendingReturn
        pendingReturn = nil
        await task?.value
    }

    /// Plain Return never reaches the panel at all: the composer's TextField
    /// delivers it through `.onSubmit { Task { await viewModel.submitResolvingFuzzyAlias() } }`
    /// (OverlayView.swift:52). A SwiftUI submit cannot be driven from a
    /// synthetic event in-process, so this calls that same entry point with the
    /// same Task the view spawns.
    func submitLikeReturn() async {
        let task = Task { @MainActor in await viewModel.submitResolvingFuzzyAlias() }
        await task.value
    }

    private func keyEvent(
        _ characters: String,
        _ keyCode: UInt16,
        _ modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

/// Counts overlay show/hide instead of posting system notifications.
@MainActor
private final class KeyboardOverlayPresenter: OverlayPresenting {
    private(set) var presentCount = 0
    private(set) var dismissCount = 0

    func presentOverlay() { presentCount += 1 }
    func dismissOverlay() { dismissCount += 1 }
    func openSettings() {}
    func openTranslator() {}
    func openTypeToClick() {}
}

/// Records what a keyboard-driven action copied, pasted, or replaced.
private final class KeyboardSelectedTextService: SelectedTextServicing {
    var isAccessibilityTrusted: Bool { true }
    var selectedText: String?
    private(set) var replacedText: String?
    private(set) var pastedText: String?
    private(set) var pastedTarget: SelectionTarget?

    init(text: String?) {
        selectedText = text
    }

    func currentExternalTarget() -> SelectionTarget? { nil }

    func capture(
        from target: SelectionTarget,
        promptForPermission: Bool
    ) -> SelectedTextContext? {
        guard let selectedText else { return nil }
        return SelectedTextContext(target: target, text: selectedText)
    }

    func replace(_ text: String, in context: SelectedTextContext) async -> Bool {
        replacedText = text
        return true
    }

    func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        pastedText = text
        pastedTarget = target
        return true
    }

    func openAccessibilitySettings() {}
}

/// One application, so ⌘K and ⌘⇧A have a real focused row to act on.
private final class KeyboardApplicationCatalog: ApplicationCatalogServicing {
    let applications = [
        LaunchableApplication(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            url: URL(fileURLWithPath: "/Applications/Safari.app")
        ),
    ]

    func launch(_ application: LaunchableApplication) -> Bool { true }
}

/// A text view that records Copy without touching the system pasteboard.
private final class RecordingTextView: NSTextView {
    private(set) var copyCount = 0
    private(set) var cutCount = 0

    override func copy(_ sender: Any?) {
        copyCount += 1
    }

    override func cut(_ sender: Any?) {
        cutCount += 1
    }
}
