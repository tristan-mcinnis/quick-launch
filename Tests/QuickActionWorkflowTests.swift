import AppKit
import Testing
@testable import QuickLaunch

@Suite("Quick action workflow", .serialized)
@MainActor
struct QuickActionWorkflowTests {
    private let target = SelectionTarget(processIdentifier: 42, applicationName: "Editor")

    @Test func selectedTextFeedsActionPrompt() async {
        let selection = FakeSelectedTextService(text: "Long selected passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Short summary", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "tldr" })!
        await vm.perform(action: action)

        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("Long selected passage") == true)
        #expect(vm.output == "Short summary")
    }

    @Test func rewriteActionPreviewsThenExplicitlyReplacesSelection() async {
        let selection = FakeSelectedTextService(text: "rough words")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Polished words", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "grammar" })!
        await vm.perform(action: action)

        // Preview-first: the result stays on screen and never auto-writes.
        #expect(vm.output == "Polished words")
        #expect(selection.replacedText == nil)

        // The user's explicit Replace Selection writes back to the captured text.
        #expect(await vm.replaceOutputInCapturedSelection())
        #expect(selection.replacedText == "Polished words")
        #expect(selection.replacedContext?.text == "rough words")
    }

    @Test func fuzzyAliasRunsWithoutFullSpelling() async {
        let selection = FakeSelectedTextService(text: "A long passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Summary", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.input = "/smrz"

        await vm.submitResolvingFuzzyAlias()

        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("A long passage") == true)
        #expect(vm.output == "Summary")
    }

    @Test func missingPermissionProducesUsefulError() async {
        let selection = FakeSelectedTextService(text: nil, trusted: false)
        let vm = QuickViewModel(
            service: MockQuickService(),
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "tldr" })!
        await vm.perform(action: action)

        #expect(vm.errorMessage?.contains("Accessibility") == true)
    }

    @Test func streamCompletionRequestsInputFocus() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Answer", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        let vm = QuickViewModel(settings: settings, service: service)
        let before = vm.inputFocusRequest
        vm.input = "Question"

        await vm.submit()

        #expect(vm.inputFocusRequest > before)
    }

    @Test func resultCanPasteBackToPreviousApp() async {
        let selection = FakeSelectedTextService(text: nil)
        let vm = QuickViewModel(
            service: MockQuickService(),
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.output = "Paste this result"

        let pasted = await vm.pasteOutputToPreviousApp()

        #expect(pasted)
        #expect(selection.pastedText == "Paste this result")
        #expect(selection.pastedTarget == target)
    }

    @Test func snippetCanCopyPasteOrDoBoth() async {
        let selection = FakeSelectedTextService(text: nil)
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(
            service: MockQuickService(),
            selectedTextService: selection,
            pasteboard: pasteboard
        )
        vm.rememberSelectionTarget(target)
        vm.prepareForExternalAction = { selection.externalActionPrepared = true }
        let item = LauncherCatalogItem(
            kind: .snippet,
            itemID: "greeting",
            title: "Greeting",
            detail: "Test",
            value: "Hello there"
        )

        await vm.copyLauncherItem(item)
        #expect(pasteboard.string == "Hello there")
        #expect(await vm.pasteLauncherItem(item))
        #expect(selection.pastedText == "Hello there")
        #expect(selection.wasPreparedWhenPasted)
        #expect(await vm.copyAndPasteLauncherItem(item))
        #expect(pasteboard.string == "Hello there")
    }

    @Test func blockedSnippetPasteReportsAccessibilityAndRestoresOverlay() async {
        let selection = FakeSelectedTextService(text: nil, trusted: false)
        selection.pasteSucceeds = false
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        var recovered = false
        vm.prepareForExternalAction = { selection.externalActionPrepared = true }
        vm.recoverFromExternalActionFailure = { recovered = true }
        let item = LauncherCatalogItem(
            kind: .snippet,
            itemID: "blocked",
            title: "Blocked",
            detail: "Test",
            value: "Private value"
        )

        #expect(!(await vm.pasteLauncherItem(item)))
        #expect(recovered)
        #expect(vm.errorMessage?.contains("Accessibility") == true)
    }

    @Test func windowCommandTargetsPreviousWindowAfterDismissingOverlay() {
        let windows = FakeWindowManager()
        let vm = QuickViewModel(windowManager: windows)
        vm.rememberSelectionTarget(target)
        vm.prepareForExternalAction = { windows.externalActionPrepared = true }
        let item = vm.systemCommands.first { $0.itemID == "window.centerThird" }!

        vm.performSystemCommand(item)

        #expect(windows.appliedLayout == .centerThird)
        #expect(windows.appliedTarget == target)
        #expect(windows.wasPreparedWhenApplied)
    }

    @Test func caffeinateCommandTogglesAndPersistsIntent() {
        let caffeine = FakeCaffeinateManager()
        let vm = QuickViewModel(caffeinateManager: caffeine)
        vm.persistSettings = { _ in }
        let item = vm.systemCommands.first { $0.itemID == "caffeinate.toggle" }!

        vm.performSystemCommand(item)
        #expect(vm.isCaffeinating)
        #expect(vm.settings.caffeinateEnabled)
        #expect(caffeine.isEnabled)

        vm.performSystemCommand(vm.systemCommands.first { $0.itemID == "caffeinate.toggle" }!)
        #expect(!vm.isCaffeinating)
        #expect(!vm.settings.caffeinateEnabled)
    }

    // MARK: - Launch-scoped background selection

    @Test func captureLaunchSelectionSnapshotsBackgroundText() {
        let selection = FakeSelectedTextService(text: "background passage")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)

        vm.captureLaunchSelection()

        #expect(vm.launchSelection?.text == "background passage")
        #expect(vm.launchSelection?.appName == "Editor")
        #expect(vm.launchSelectionTitle == "Selected text from Editor")
    }

    @Test func captureLaunchSelectionIsSilentWhenNoSelection() {
        let selection = FakeSelectedTextService(text: nil)
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)

        vm.captureLaunchSelection()

        #expect(vm.launchSelection == nil)
    }

    @Test func backgroundSelectionReachesAdHocRequest() async {
        let selection = FakeSelectedTextService(text: "background passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Parsed", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.input = "What does this say?"

        await vm.submit()

        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("background passage") == true)
        #expect(messages.last?.content.contains("What does this say?") == true)
    }

    @Test func backgroundSelectionIsConsumedAfterFirstRequest() async {
        let selection = FakeSelectedTextService(text: "background passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Parsed", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        #expect(vm.launchSelection != nil)
        vm.input = "What does this say?"

        await vm.submit()

        #expect(vm.launchSelection == nil)

        // A follow-up in the same chat must not re-attach the selection.
        vm.output = "Parsed"
        vm.isStreaming = false
        vm.input = "And again?"
        await vm.submit()
        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("background passage") == false)
    }

    @Test func adHocWithoutSelectionSendsNoContext() async {
        let selection = FakeSelectedTextService(text: nil)
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Hi", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.input = "Hello"

        await vm.submit()

        let messages = await service.lastMessages
        #expect(messages.last?.content == "Hello")
    }

    @Test func freshLaunchReplacesStaleSnapshot() {
        let selection = FakeSelectedTextService(text: "first selection")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        #expect(vm.launchSelection?.text == "first selection")

        // A fresh launch re-captures and invalidates the old snapshot.
        selection.selectedText = "second selection"
        vm.captureLaunchSelection()
        #expect(vm.launchSelection?.text == "second selection")

        // A launch with no selection clears the stale snapshot entirely.
        selection.selectedText = nil
        vm.captureLaunchSelection()
        #expect(vm.launchSelection == nil)
    }

    @Test func removingLaunchSelectionDropsContext() async {
        let selection = FakeSelectedTextService(text: "background passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Parsed", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.clearLaunchSelection()
        vm.input = "Hello"

        await vm.submit()

        let messages = await service.lastMessages
        #expect(messages.last?.content == "Hello")
    }

    @Test func launchSelectionFeedsSavedActionSource() async {
        let selection = FakeSelectedTextService(text: "background passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Polished", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "grammar" })!
        await vm.perform(action: action)

        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("background passage") == true)
        #expect(vm.launchSelection == nil)
    }

    @Test func performActionNeverUsesStaleOutputAsSource() async {
        let selection = FakeSelectedTextService(text: "current selection")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Answer", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        // A previous answer is on screen - it must never become the source.
        vm.output = "an earlier, unrelated answer"

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "tldr" })!
        await vm.perform(action: action)

        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("current selection") == true)
        #expect(messages.last?.content.contains("an earlier, unrelated answer") == false)
    }

    // MARK: - Review findings

    @Test func typedAliasContextBeatsLaunchSnapshot() async {
        let selection = FakeSelectedTextService(text: "auto snapshot")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Fixed", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: service, selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.input = "/improve typed words"

        await vm.submit()

        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("typed words") == true)
        #expect(messages.last?.content.contains("auto snapshot") == false)
    }

    @Test func performTypedInputBeatsLaunchSnapshot() async {
        let selection = FakeSelectedTextService(text: "auto snapshot")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Fixed", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: service, selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.input = "typed words"

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "improve" })!
        await vm.perform(action: action)

        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("typed words") == true)
        #expect(messages.last?.content.contains("auto snapshot") == false)
    }

    @Test func launchCaptureRetainsContextForResultReplacement() async {
        let selection = FakeSelectedTextService(text: "rough words")
        // The launch read succeeds once; any later re-read would go nil.
        selection.capturesRemaining = 1
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Polished", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection,
            pasteboard: pasteboard
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "grammar" })!
        await vm.perform(action: action)

        // Preview-first: no auto-write, the result stays on screen.
        #expect(selection.replacedText == nil)
        // Fail closed: the live selection cannot be re-read (capture is nil), so
        // we copy instead of risking overwriting text we cannot confirm is the
        // original. Nothing is written back through the service.
        #expect(!(await vm.replaceOutputInCapturedSelection()))
        #expect(pasteboard.string == "Polished")
        #expect(selection.replacedText == nil)
    }

    @Test func removingChipSuppressesSavedActionRecapture() async {
        let selection = FakeSelectedTextService(text: "old selection")
        let service = MockQuickService()
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: service, selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.clearLaunchSelection()

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "improve" })!
        await vm.perform(action: action)

        #expect(vm.errorMessage?.isEmpty == false)
        #expect(await service.sendCallCount == 0)
    }

    @Test func savedActionHonorsExplicitContextWithoutDuplicatingSelection() async {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "Done", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: service)
        var context = CaptureContext(appName: "Safari", selectedText: "sel text", appText: "readable text")
        vm.pendingContext = context

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "improve" })!
        await vm.perform(action: action)

        let message = (await service.lastMessages).last?.content ?? ""
        #expect(message.contains("Context from Safari") == true)
        #expect(message.contains("readable text") == true)
        #expect(message.contains("sel text") == true)
        // The selection appears exactly once (as the {selection} source), and
        // the preamble does not repeat a "Selected text:" block.
        #expect(message.components(separatedBy: "sel text").count - 1 == 1)
        #expect(message.contains("Selected text:") == false)
    }

    @Test func commandActionConsumesLaunchChip() async {
        let selection = FakeSelectedTextService(text: "command input")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.settings.savedPrompts.append(SavedPrompt(
            alias: "cmd",
            prompt: "run",
            commandExecutable: "/bin/echo",
            commandArguments: ["{input}"]
        ))
        vm.input = "/cmd"

        await vm.submit()

        #expect(vm.launchSelection == nil)
    }

    @Test func performCommandConsumesLaunchChip() async {
        let selection = FakeSelectedTextService(text: "command input")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.settings.savedPrompts.append(SavedPrompt(
            alias: "cmd",
            prompt: "run",
            commandExecutable: "/bin/echo",
            commandArguments: ["{input}"]
        ))
        let action = vm.settings.savedPrompts.first(where: { $0.alias == "cmd" })!

        await vm.perform(action: action)

        // perform() stashed the snapshot in pendingActionSource; the command
        // branch must still consume the chip.
        #expect(vm.launchSelection == nil)
    }

    @Test func removeThenExplicitAttachReArmsSelection() {
        let selection = FakeSelectedTextService(text: "fresh selection")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        // Removing the chip suppresses automatic re-capture and invalidates
        // the cached context.
        vm.clearLaunchSelection()
        #expect(vm.launchSelection == nil)

        let attached = vm.attachSelectedText()

        // An explicit Selected Text capture re-arms the read and works.
        #expect(attached)
        #expect(vm.pendingContext?.selectedText == "fresh selection")
        #expect(vm.launchSelection == nil)
    }

    @Test func resetAttachmentsClearsLaunchScopedState() {
        let selection = FakeSelectedTextService(text: "sel")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        #expect(vm.launchSelection != nil)

        vm.reset([.attachments])

        #expect(vm.launchSelection == nil)
        #expect(vm.selectedTextContext == nil)
    }

    @Test func clearAttachmentsClearsLaunchScopedState() {
        let selection = FakeSelectedTextService(text: "sel")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()

        vm.clearAttachments()

        #expect(vm.launchSelection == nil)
        #expect(vm.selectedTextContext == nil)
    }

    @Test func freshLaunchReArmsSelectionAfterDismissal() {
        let selection = FakeSelectedTextService(text: "fresh")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.clearLaunchScopedState()
        #expect(vm.launchSelection == nil)

        vm.captureLaunchSelection()

        #expect(vm.launchSelection?.text == "fresh")
    }

    @Test func newChatDoesNotReattachConsumedSelection() async {
        let selection = FakeSelectedTextService(text: "background passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "A", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: service, selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.input = "Q1"
        await vm.submit()
        #expect(vm.launchSelection == nil)

        vm.startNewConversation()
        vm.input = "Q2"
        await vm.submit()

        let messages = await service.lastMessages
        #expect(messages.last?.content.contains("background passage") == false)
    }

    // MARK: - Preview-first rewrite actions

    @Test func builtInRewriteActionsPreviewNeverAutoWrite() async {
        for alias in ["shorter", "bullets", "improve"] {
            let selection = FakeSelectedTextService(text: "long text to rewrite")
            let service = MockQuickService()
            await service.setResponses([StreamDelta(text: "rewritten", finishReason: "stop")])
            var settings = QuickSettings()
            settings.autoCopy = false
            settings.historyEnabled = false
            let vm = QuickViewModel(
                settings: settings,
                service: service,
                selectedTextService: selection
            )
            vm.rememberSelectionTarget(target)
            vm.captureLaunchSelection()

            let action = vm.settings.savedPrompts.first(where: { $0.alias == alias })!
            await vm.perform(action: action)

            #expect(vm.output == "rewritten", "\(alias) should stay on screen")
            #expect(selection.replacedText == nil, "\(alias) must not auto-write")
        }
    }

    @Test func customReplaceSelectionActionStillAutoWrites() async {
        let selection = FakeSelectedTextService(text: "raw text")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "fixed", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.settings.savedPrompts.append(SavedPrompt(
            alias: "myrewrite",
            prompt: "Rewrite this:\n\n{selection}",
            outputBehavior: .replaceSelection
        ))

        let action = vm.settings.savedPrompts.first(where: { $0.alias == "myrewrite" })!
        await vm.perform(action: action)

        // A custom action outside the preview-first set keeps its auto-write.
        #expect(selection.replacedText == "fixed")
    }

    @Test func customReplaceActionFailsClosedWhenLiveSelectionUnreadable() async {
        let selection = FakeSelectedTextService(text: "original")
        // The launch read succeeds once; the validation re-read goes nil.
        selection.capturesRemaining = 1
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "fixed", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let pasteboard = FakePasteboard()
        settings.savedPrompts = [SavedPrompt(
            alias: "myrewrite",
            prompt: "Rewrite: {selection}",
            outputBehavior: .replaceSelection
        )]
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection,
            pasteboard: pasteboard
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        let action = vm.settings.savedPrompts.first(where: { $0.alias == "myrewrite" })!
        await vm.perform(action: action)

        // A custom auto-write still fails closed: it cannot confirm the live
        // selection, so it copies instead of writing.
        #expect(selection.replacedText == nil)
        #expect(pasteboard.string == "fixed")
        #expect(vm.errorMessage?.contains("Could not read the current selection") == true)
    }

    @Test func customReplaceActionFailsClosedWhenSelectionChanged() async {
        let selection = FakeSelectedTextService(text: "original")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "fixed", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let pasteboard = FakePasteboard()
        settings.savedPrompts = [SavedPrompt(
            alias: "myrewrite",
            prompt: "Rewrite: {selection}",
            outputBehavior: .replaceSelection
        )]
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection,
            pasteboard: pasteboard
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        // The selection changed after the snapshot: the auto-write copies.
        selection.selectedText = "changed"
        let action = vm.settings.savedPrompts.first(where: { $0.alias == "myrewrite" })!
        await vm.perform(action: action)

        #expect(selection.replacedText == nil)
        #expect(pasteboard.string == "fixed")
        #expect(vm.errorMessage?.contains("selection changed") == true)
    }

    @Test func sameAliasCustomActionHonorsStoredReplaceBehavior() async {
        let selection = FakeSelectedTextService(text: "raw")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "fixed", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        // Only the user's customized improve is present, so the alias resolves
        // to it (no stock default to shadow). Alias-only preview would force a
        // preview; the stored behavior must win.
        settings.savedPrompts = [SavedPrompt(
            alias: "improve",
            prompt: "Custom improve: {selection}",
            outputBehavior: .replaceSelection
        )]
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        let action = vm.settings.savedPrompts.first(where: { $0.alias == "improve" })!
        await vm.perform(action: action)

        #expect(selection.replacedText == "fixed")
    }

    @Test func replaceSelectionActionOfferedForRetainedContext() async {
        let selection = FakeSelectedTextService(text: "long text")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "short", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        let action = vm.settings.savedPrompts.first(where: { $0.alias == "shorter" })!
        await vm.perform(action: action)

        // The precise destination (replace the captured selection) is offered
        // first, and both destination rows name their app.
        #expect(vm.resultActions.first == .replaceSelection)
        #expect(vm.resultActions.contains(.pasteBack))
        #expect(vm.resultActionDetail(.replaceSelection) == "Replace in Editor")
        #expect(vm.resultActionDetail(.pasteBack) == "Paste into Editor")
    }

    @Test func followUpDoesNotOfferReplaceSelectionForPriorTransform() async {
        let selection = FakeSelectedTextService(text: "background text")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "short", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        let action = vm.settings.savedPrompts.first(where: { $0.alias == "shorter" })!
        await vm.perform(action: action)
        #expect(vm.resultActions.contains(.replaceSelection))

        // A follow-up in the same chat must not offer to replace the prior
        // transform's selection — the answer is not a rewrite of that text.
        vm.output = "short"
        vm.isStreaming = false
        vm.input = "And then?"
        await vm.submit()
        #expect(!vm.resultActions.contains(.replaceSelection))
    }

    @Test func replaceFailsSafeToCopyWhenSelectionChanged() async {
        let selection = FakeSelectedTextService(text: "original")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "short", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection,
            pasteboard: pasteboard
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        let action = vm.settings.savedPrompts.first(where: { $0.alias == "shorter" })!
        await vm.perform(action: action)
        #expect(vm.output == "short")

        // The user edited the selection elsewhere: fail safe to Copy.
        selection.selectedText = "changed"
        let replaced = await vm.replaceOutputInCapturedSelection()
        #expect(!replaced)
        #expect(pasteboard.string == "short")
        #expect(vm.errorMessage?.contains("selection changed") == true)
    }

    // MARK: - Chip transform routing

    @Test func chipTransformOptionsListTheRewriteSet() {
        let selection = FakeSelectedTextService(text: "some text")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()

        let options = vm.chipTransformOptions
        #expect(options.count == 5)
        #expect(options[0].title == "Make Shorter")
        #expect(options.last?.id == "translator")
        for option in options {
            if case .saved(let id) = option.kind {
                #expect(vm.settings.savedPrompts.contains { $0.id == id })
            }
        }
    }

    @Test func chipTransformOptionsEmptyWithoutLaunchSelection() {
        let selection = FakeSelectedTextService(text: nil)
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        #expect(vm.chipTransformOptions.isEmpty)
    }

    @Test func runChipTransformRunsSavedRewriteAction() async {
        let selection = FakeSelectedTextService(text: "some text")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "short", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()

        let shorter = vm.chipTransformOptions.first { $0.title == "Make Shorter" }!
        await vm.runChipTransform(shorter)
        #expect(vm.output == "short")
        #expect(selection.replacedText == nil)
    }

    @Test func runChipTransformRoutesTranslateToTranslator() async {
        let selection = FakeSelectedTextService(text: "some text")
        let vm = QuickViewModel(selectedTextService: selection)
        let recorder = RecordingOverlayPresenter()
        vm.overlayPresenter = recorder
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()

        let translate = vm.chipTransformOptions.first { $0.id == "translator" }!
        await vm.runChipTransform(translate)
        #expect(recorder.openedTranslator)
        #expect(recorder.handedOffSelection == "some text")
    }

    @Test func chipTransformUsesSnapshotNotTypedInput() async {
        let selection = FakeSelectedTextService(text: "selected passage")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "shrunk", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.input = "unrelated typed text"
        let shorter = vm.chipTransformOptions.first { $0.title == "Make Shorter" }!
        await vm.runChipTransform(shorter)

        let messages = await service.lastMessages
        // The transform acts on the captured selection, never on typed input.
        #expect(messages.last?.content.contains("selected passage") == true)
        #expect(messages.last?.content.contains("unrelated typed text") == false)
    }

    @Test func transformChooserOpenMoveWrapAndEscape() {
        let selection = FakeSelectedTextService(text: "para")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()

        vm.openTransformChooser()
        #expect(vm.isTransformChooserPresented)
        #expect(vm.transformChooserIndex == 0)
        vm.moveTransformChooserSelection(1)
        #expect(vm.transformChooserIndex == 1)
        vm.moveTransformChooserSelection(-2)
        #expect(vm.transformChooserIndex == vm.chipTransformOptions.count - 1)

        // Escape walks the same layer stack and closes the chooser.
        #expect(vm.popTopLayer())
        #expect(!vm.isTransformChooserPresented)

        // The shortcut toggles it back open.
        vm.toggleTransformChooser()
        #expect(vm.isTransformChooserPresented)
    }

    @Test func transformChooserRunClosesAndExecutesSelected() async {
        let selection = FakeSelectedTextService(text: "para")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "short", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.openTransformChooser()
        vm.transformChooserIndex = 0  // Make Shorter (saved rewrite action)
        await vm.runTransformChooserSelection()
        #expect(!vm.isTransformChooserPresented)
        #expect(vm.output == "short")
    }

    @Test func transformRequiresSelection() async {
        let selection = FakeSelectedTextService(text: nil)
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        let action = vm.settings.savedPrompts.first(where: { $0.alias == "improve" })!
        await vm.performTransform(action: action)
        #expect(vm.errorMessage?.isEmpty == false)
    }

    @Test func transformChooserShortcutToggles() {
        let selection = FakeSelectedTextService(text: "para")
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        let flags = NSEvent.ModifierFlags([.command, .option])
        #expect(vm.performShortcut(characters: "t", keyCode: 17, modifiers: flags))
        #expect(vm.isTransformChooserPresented)
        #expect(vm.performShortcut(characters: "t", keyCode: 17, modifiers: flags))
        #expect(!vm.isTransformChooserPresented)
    }

    @Test func transformShortcutDoesNotReuseReservedPanelKeys() {
        // ⌘⇧D is the panel's screenshot-display key and ⌘⇧T the translator
        // global hotkey; both are consumed before `performShortcut`, so the
        // chooser must not use them. Guard against a regression back onto a
        // reserved combo (the AppDelegate routing is exercised via the panel's
        // `performKeyEquivalent`, which sends non-reserved combos to
        // `performShortcut`).
        let screenshotDisplay = KeyShortcut.commandShift("d")
        let translator = KeyShortcut.commandShift("t")
        #expect(screenshotDisplay.matches(characters: "d", keyCode: 2, modifiers: [.command, .shift]))
        #expect(translator.matches(characters: "t", keyCode: 17, modifiers: [.command, .shift]))
        #expect(QuickViewModel.transformChooserShortcut == .commandOption("t"))
        #expect(QuickViewModel.transformChooserShortcut != screenshotDisplay)
        #expect(QuickViewModel.transformChooserShortcut != translator)
    }

    @Test func returnRunsFocusedTransformWhenChooserOpen() async {
        let selection = FakeSelectedTextService(text: "para")
        let service = MockQuickService()
        await service.setResponses([StreamDelta(text: "short", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let vm = QuickViewModel(
            settings: settings,
            service: service,
            selectedTextService: selection
        )
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        vm.openTransformChooser()
        vm.transformChooserIndex = 0
        await vm.submitResolvingFuzzyAlias()
        #expect(vm.output == "short")
        #expect(!vm.isTransformChooserPresented)
    }

    @Test func translatorHandoffSurvivesLaunchStateClear() {
        let selection = FakeSelectedTextService(text: "launch snapshot")
        let vm = QuickViewModel(selectedTextService: selection)
        let recorder = RecordingOverlayPresenter()
        vm.overlayPresenter = recorder
        vm.rememberSelectionTarget(target)
        vm.captureLaunchSelection()
        #expect(vm.launchSelection?.text == "launch snapshot")

        vm.openTranslatorWithSelection()
        // The retained selection is handed to the presenter before any
        // dismissal beats it; a destructive clear of launch-scoped state (as
        // hideOverlay does) cannot take it back.
        #expect(recorder.handedOffSelection == "launch snapshot")
        vm.clearLaunchScopedState()
        #expect(vm.launchSelection == nil)
        #expect(recorder.handedOffSelection == "launch snapshot")
    }
}

@MainActor
private final class FakeWindowManager: WindowManaging {
    var isAccessibilityTrusted = true
    var externalActionPrepared = false
    var wasPreparedWhenApplied = false
    var appliedLayout: WindowLayout?
    var appliedTarget: SelectionTarget?

    func apply(_ layout: WindowLayout, to target: SelectionTarget) -> Bool {
        wasPreparedWhenApplied = externalActionPrepared
        appliedLayout = layout
        appliedTarget = target
        return true
    }

    var appliedMove: WindowMove?

    func move(_ move: WindowMove, target: SelectionTarget) -> Bool {
        wasPreparedWhenApplied = externalActionPrepared
        appliedMove = move
        appliedTarget = target
        return true
    }
}

@MainActor
private final class FakeCaffeinateManager: CaffeinateManaging {
    var isEnabled = false
    func setEnabled(_ enabled: Bool) -> Bool {
        isEnabled = enabled
        return true
    }
}

@MainActor
private final class FakeSelectedTextService: SelectedTextServicing {
    var isAccessibilityTrusted: Bool
    var selectedText: String?
    var replacedText: String?
    var replacedContext: SelectedTextContext?
    var pastedText: String?
    var pastedTarget: SelectionTarget?
    var externalActionPrepared = false
    var wasPreparedWhenPasted = false
    var pasteSucceeds = true
    var openedSettings = false
    /// Number of future `capture(from:)` calls that still return a selection.
    /// Default `.max` keeps existing behaviour; set to 1 to model a capture
    /// that succeeds once (the launch read) and then goes nil.
    var capturesRemaining = Int.max

    init(text: String?, trusted: Bool = true) {
        selectedText = text
        isAccessibilityTrusted = trusted
    }

    func currentExternalTarget() -> SelectionTarget? { nil }

    func capture(
        from target: SelectionTarget,
        promptForPermission: Bool
    ) -> SelectedTextContext? {
        guard isAccessibilityTrusted, let selectedText else { return nil }
        guard capturesRemaining > 0 else { return nil }
        capturesRemaining -= 1
        return SelectedTextContext(target: target, text: selectedText)
    }

    func replace(_ text: String, in context: SelectedTextContext) async -> Bool {
        replacedText = text
        replacedContext = context
        return true
    }

    func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        wasPreparedWhenPasted = externalActionPrepared
        pastedText = text
        pastedTarget = target
        return pasteSucceeds
    }

    func openAccessibilitySettings() { openedSettings = true }
}

@MainActor
private final class RecordingOverlayPresenter: OverlayPresenting {
    var presented = false
    var dismissed = false
    var openedTranslator = false
    var handedOffSelection: String?
    func presentOverlay() { presented = true }
    func dismissOverlay() { dismissed = true }
    func openSettings() {}
    func openTranslator() { openedTranslator = true }
    func openTranslator(retainedSelection: String?) {
        openedTranslator = true
        handedOffSelection = retainedSelection
    }
    func openTypeToClick() {}
}
