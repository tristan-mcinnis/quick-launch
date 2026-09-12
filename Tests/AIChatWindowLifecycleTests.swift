// AIChatWindowLifecycleTests: the AI Chat window's life around its chat:
// ⌘Q closes the window and ⌥⌘Q quits, a quit keeps the question being
// answered, closing lets the answer finish and posts a notice, the draft
// keeps its caret keys, the window opens on the launcher's display, the
// menu bar stays while Settings is up, Keep on Top pauses for pi, and the
// window comes back after a capture. Fakes stand in for the app shell and
// the notification center, so nothing activates, installs a menu, or
// reaches the screen.

import AppKit
import Foundation
import Testing
import UserNotifications
@testable import QuickLaunch

/// The app around the window, recorded.
@MainActor
final class FakeAIChatAppShell: AIChatAppShell {
    var presents = 0
    var closes: [NSWindow] = []
    /// What `isOnScreen` answers.
    var onScreen = false
    func present(_ window: NSWindow, menu: () -> NSMenu) { presents += 1 }
    func windowWillClose(_ window: NSWindow) { closes.append(window) }
    func isOnScreen(_ window: NSWindow) -> Bool { onScreen }
}

@MainActor
final class FakeAnswerNotifier: AnswerNotifying {
    var onOpen: (() -> Void)?
    var posted: [AnswerNotice] = []
    func post(_ notice: AnswerNotice) async { posted.append(notice) }
}

@MainActor
final class FakeUserNotificationCenter: UserNotificationCentering {
    var onOpen: (() -> Void)?
    var status: UNAuthorizationStatus
    var grants: Bool
    var requests = 0
    var added: [(identifier: String, title: String, body: String)] = []

    init(status: UNAuthorizationStatus, grants: Bool = true) {
        self.status = status
        self.grants = grants
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAlertAuthorization() async -> Bool {
        requests += 1
        status = grants ? .authorized : .denied
        return grants
    }
    func add(identifier: String, title: String, body: String) async {
        added.append((identifier, title, body))
    }
}

/// Continue in pi without tmux or Ghostty: it notes the window's level at
/// the moment of the hand-off.
final class LevelProbePiHandoff: PiHandoffServicing {
    let openedGhostty: Bool
    let fails: Bool
    let probe: @MainActor @Sendable () -> Void

    init(openedGhostty: Bool = true, fails: Bool = false, probe: @escaping @MainActor @Sendable () -> Void) {
        self.openedGhostty = openedGhostty
        self.fails = fails
        self.probe = probe
    }

    func handOff(_ request: PiHandoffRequest) async throws -> PiHandoffResult {
        await probe()
        if fails { throw PiHandoffError.sessionFailed("test") }
        return PiHandoffResult(
            sessionName: "ql-test",
            threadFile: URL(fileURLWithPath: "/dev/null"),
            openedGhostty: openedGhostty
        )
    }
}

@Suite("AI Chat window lifecycle", .serialized)
@MainActor
struct AIChatWindowLifecycleTests {

    /// The app's wiring in memory: the launcher's and the window's view
    /// models on one store, the window model, and the real controller over
    /// a fake shell and a fake notifier.
    struct Rig {
        let launcher: QuickViewModel
        let chat: QuickViewModel
        let model: AIChatWindowModel
        let controller: AIChatWindowController
        let shell: FakeAIChatAppShell
        let notifier: FakeAnswerNotifier
        let presenter: RecordingPresenter
    }

    private func makeRig(
        service: any QuickService = MockQuickService(),
        piHandoff: (any PiHandoffServicing)? = nil,
        alwaysOnTop: Bool = false
    ) -> Rig {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let launcher = QuickViewModel(settings: settings, service: service)
        let presenter = RecordingPresenter()
        launcher.overlayPresenter = presenter
        let chat = QuickViewModel(store: launcher.store, service: service)
        chat.piHandoff = piHandoff
        let suite = "AIChatWindowLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = AIChatWindowModel(chat: chat, defaults: defaults)
        model.isAlwaysOnTop = alwaysOnTop
        let shell = FakeAIChatAppShell()
        let notifier = FakeAnswerNotifier()
        let controller = AIChatWindowController(
            model: model,
            app: presenter,
            shell: shell,
            notifier: notifier,
            frameAutosaveName: nil
        )
        return Rig(
            launcher: launcher, chat: chat, model: model, controller: controller,
            shell: shell, notifier: notifier, presenter: presenter
        )
    }

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

    /// Starts an ask in the window on a gated model and returns once its
    /// first words are on screen and the stream is held open.
    private func streaming(
        _ rig: Rig,
        _ gated: GatedQuickService,
        question: String = "tell me about Lima"
    ) async -> Task<Void, Never> {
        rig.chat.input = question
        let submit = Task { await rig.chat.submit() }
        await gated.waitUntilHolding()
        _ = await waitFor { rig.chat.output == gated.head }
        return submit
    }

    private func closeNotification(_ window: NSWindow) -> Notification {
        Notification(name: NSWindow.willCloseNotification, object: window)
    }

    // MARK: - 3. ⌘Q and quitting

    @Test func commandQClosesTheChatAndQuitIsOptionCommandQ() throws {
        let rig = makeRig()
        let menu = AIChatMenu(controller: rig.controller).makeMenu()
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        let plainQ = items.filter { $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask == [.command] }
        #expect(plainQ.map(\.title) == [AIChatMenu.closeChatTitle])
        let quit = try #require(items.first { $0.title == AIChatMenu.quitTitle })
        #expect(quit.keyEquivalent == "q")
        #expect(quit.keyEquivalentModifierMask == [.command, .option])
        #expect(!items.contains { $0.action == #selector(NSApplication.terminate(_:)) })
    }

    @Test func quitStaysAvailableAndCloseAIChatNeedsTheChatKey() throws {
        let rig = makeRig()
        let chatMenu = AIChatMenu(controller: rig.controller)
        let items = chatMenu.makeMenu().items.compactMap(\.submenu).flatMap(\.items)
        let quit = try #require(items.first { $0.title == AIChatMenu.quitTitle })
        let close = try #require(items.first { $0.title == AIChatMenu.closeChatTitle })
        // No window is key in a test: the chat items rest, Quit does not.
        #expect(chatMenu.validateMenuItem(quit))
        #expect(!chatMenu.validateMenuItem(close))
    }

    @Test func closeAIChatClosesTheWindowAndLeavesTheApp() throws {
        let rig = makeRig()
        let window = rig.controller.prepareWindow()
        let chatMenu = AIChatMenu(controller: rig.controller)
        let items = chatMenu.makeMenu().items.compactMap(\.submenu).flatMap(\.items)
        let close = try #require(items.first { $0.title == AIChatMenu.closeChatTitle })
        let action = try #require(close.action)
        #expect(NSApp.sendAction(action, to: close.target, from: close))
        #expect(rig.shell.closes.count == 1)
        #expect(rig.shell.closes.first === window)
    }

    @Test func quittingMidAnswerKeepsTheQuestionAndWhatArrived() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let gated = GatedQuickService(head: "Lima is the capital", tail: " of Peru.")
        let vm = QuickViewModel(settings: settings, service: gated, historyFileURL: file)
        vm.openQuickAI()
        vm.input = "tell me about Lima"
        let submit = Task { await vm.submit() }
        await gated.waitUntilHolding()
        _ = await waitFor { vm.output == "Lima is the capital" }

        AIChatWindowController.keepStreamForQuit(vm)
        QuickHistoryStore.waitForPendingWrites()
        await submit.value

        #expect(!vm.isStreaming)
        let saved = QuickHistoryStore.load(from: file, migratingFrom: nil)
        let messages = try #require(saved.first).messages
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.first?.content == "tell me about Lima")
        #expect(messages.last?.content == "Lima is the capital")
    }

    @Test func quittingBeforeAnyTextStillKeepsTheQuestion() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = true
        let gated = GatedQuickService(head: "")
        let vm = QuickViewModel(settings: settings, service: gated, historyFileURL: file)
        vm.openQuickAI()
        vm.input = "a question with no answer yet"
        let submit = Task { await vm.submit() }
        await gated.waitUntilHolding()
        _ = await waitFor { vm.isStreaming }

        AIChatWindowController.keepStreamForQuit(vm)
        QuickHistoryStore.waitForPendingWrites()
        await submit.value

        let saved = QuickHistoryStore.load(from: file, migratingFrom: nil)
        let messages = try #require(saved.first).messages
        #expect(messages.map(\.content) == ["a question with no answer yet"])
    }

    @Test func quittingWithNoStreamWritesNothing() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifecycle-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var settings = QuickSettings()
        settings.historyEnabled = true
        let vm = QuickViewModel(settings: settings, service: MockQuickService(), historyFileURL: file)
        vm.openQuickAI()
        AIChatWindowController.keepStreamForQuit(vm)
        QuickHistoryStore.waitForPendingWrites()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aQuitIsNotAnAnswerToAnnounce() async {
        let gated = GatedQuickService(head: "Lima is the capital")
        let rig = makeRig(service: gated)
        let window = rig.controller.prepareWindow()
        let submit = await streaming(rig, gated)
        rig.controller.windowWillClose(closeNotification(window))

        rig.controller.prepareForTermination()
        await submit.value

        #expect(!rig.chat.isStreaming)
        #expect(rig.chat.conversationMessages.last?.content == "Lima is the capital")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.notifier.posted.isEmpty)
    }

    // MARK: - 8. Closing does not stop the answer

    @Test func closingTheWindowLetsTheAnswerFinishAndSaysSo() async throws {
        let gated = GatedQuickService(head: "Lima is the capital", tail: " of Peru.")
        let rig = makeRig(service: gated)
        let window = rig.controller.prepareWindow()
        let submit = await streaming(rig, gated)

        rig.controller.windowWillClose(closeNotification(window))
        #expect(rig.chat.isStreaming)
        #expect(rig.shell.closes.count == 1)

        gated.release()
        await submit.value
        #expect(await waitFor { rig.notifier.posted.count == 1 })
        let conversation = try #require(rig.chat.currentConversation)
        #expect(rig.notifier.posted == [
            AnswerNotice(chatID: conversation.id, title: "Answer ready", body: rig.chat.title(of: conversation)),
        ])
        // Saved as it ended, in the store both views share.
        let stored = try #require(rig.launcher.history.first { $0.id == conversation.id })
        #expect(stored.messages.last?.content == "Lima is the capital of Peru.")

        // Reopening shows the finished answer.
        let presents = rig.shell.presents
        rig.model.open(handoff: nil)
        #expect(rig.chat.currentConversation?.id == conversation.id)
        #expect(rig.chat.conversationMessages.last?.content == "Lima is the capital of Peru.")
        #expect(rig.shell.presents == presents + 1)
    }

    @Test func anAnswerEndingWithTheWindowOpenPostsNothing() async {
        let gated = GatedQuickService(head: "Lima is the capital", tail: " of Peru.")
        let rig = makeRig(service: gated)
        rig.controller.prepareWindow()
        rig.shell.onScreen = true
        let submit = await streaming(rig, gated)
        gated.release()
        await submit.value
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.notifier.posted.isEmpty)
    }

    @Test func anAnswerThatFailsWhileClosedSaysItStopped() async throws {
        let gated = GatedQuickService(head: "Lima is")
        let rig = makeRig(service: gated)
        let window = rig.controller.prepareWindow()
        let submit = await streaming(rig, gated)
        rig.controller.windowWillClose(closeNotification(window))

        gated.fail()
        await submit.value
        #expect(await waitFor { rig.notifier.posted.count == 1 })
        #expect(rig.notifier.posted.first?.title == "Answer stopped")
    }

    @Test func clickingTheNoticeOpensTheChat() {
        let rig = makeRig()
        rig.notifier.onOpen?()
        #expect(rig.shell.presents == 1)
    }

    @Test func noticesAskForPermissionOnceThenPost() async throws {
        let center = FakeUserNotificationCenter(status: .notDetermined)
        var made = 0
        let notifier = UserNotificationAnswerNotifier { made += 1; return center }
        #expect(made == 0, "the center waits for the first notice")
        let notice = AnswerNotice(chatID: UUID(), title: "Answer ready", body: "Lima")
        await notifier.post(notice)
        await notifier.post(notice)
        #expect(made == 1)
        #expect(center.requests == 1)
        #expect(center.added.map(\.title) == ["Answer ready", "Answer ready"])
        #expect(center.added.first?.identifier == "AIChatAnswer.\(notice.chatID.uuidString)")
        #expect(center.added.first?.body == "Lima")
    }

    @Test func aRefusedOrDeniedPermissionPostsNothing() async {
        let refused = FakeUserNotificationCenter(status: .notDetermined, grants: false)
        let asked = UserNotificationAnswerNotifier { refused }
        await asked.post(AnswerNotice(chatID: UUID(), title: "Answer ready", body: "Lima"))
        #expect(refused.requests == 1)
        #expect(refused.added.isEmpty)

        let denied = FakeUserNotificationCenter(status: .denied)
        let notifier = UserNotificationAnswerNotifier { denied }
        await notifier.post(AnswerNotice(chatID: UUID(), title: "Answer ready", body: "Lima"))
        #expect(denied.requests == 0)
        #expect(denied.added.isEmpty)
    }

    @Test func theNoticeClickReachesTheCenterMadeLater() async {
        let center = FakeUserNotificationCenter(status: .authorized)
        let notifier = UserNotificationAnswerNotifier { center }
        var opened = 0
        notifier.onOpen = { opened += 1 }
        await notifier.post(AnswerNotice(chatID: UUID(), title: "Answer ready", body: "Lima"))
        center.onOpen?()
        #expect(opened == 1)
    }

    // MARK: - 16. The draft keeps its caret keys

    /// A bare AI Chat window whose first responder is a plain text view
    /// standing in for the composer's field editor.
    private func caretRig(input: String) throws -> (Rig, AIChatWindow, NSTextView) {
        let rig = makeRig()
        let window = AIChatWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.model = rig.model
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView = textView
        try #require(window.makeFirstResponder(textView))
        textView.string = input
        rig.chat.input = input
        rig.model.focus = .composer
        return (rig, window, textView)
    }

    private func key(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers.union(.function),
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private static let draft = "first line\nsecond line\nthird line"

    @Test func commandArrowsMoveTheCaretInADraftNotTheThread() throws {
        let (rig, window, textView) = try caretRig(input: Self.draft)
        textView.setSelectedRange(NSRange(location: 15, length: 0))
        #expect(window.performKeyEquivalent(with: try key(VirtualKey.upArrow.rawValue, [.command], in: window)))
        #expect(textView.selectedRange().location == 0)
        #expect(window.performKeyEquivalent(with: try key(VirtualKey.downArrow.rawValue, [.command], in: window)))
        #expect(textView.selectedRange().location == (Self.draft as NSString).length)
        #expect(rig.chat.threadScrollRequest == nil)
    }

    @Test func optionArrowsAndPageKeysGoToTheDraftThroughSendEvent() throws {
        let (rig, window, textView) = try caretRig(input: Self.draft)
        // Mid "second line": ⌥↑ goes to its start, ⌥↓ to its end.
        textView.setSelectedRange(NSRange(location: 15, length: 0))
        window.sendEvent(try key(VirtualKey.upArrow.rawValue, [.option], in: window))
        #expect(textView.selectedRange().location == 11)
        textView.setSelectedRange(NSRange(location: 15, length: 0))
        window.sendEvent(try key(VirtualKey.downArrow.rawValue, [.option], in: window))
        #expect(textView.selectedRange().location == 22)
        // A draft shorter than the field's page: PageUp and PageDown reach
        // its start and end.
        window.sendEvent(try key(VirtualKey.pageUp.rawValue, [], in: window))
        #expect(textView.selectedRange().location == 0)
        window.sendEvent(try key(VirtualKey.pageDown.rawValue, [], in: window))
        #expect(textView.selectedRange().location == (Self.draft as NSString).length)
        #expect(rig.chat.threadScrollRequest == nil)
    }

    @Test func anEmptyComposerStillScrollsTheThread() throws {
        let (rig, window, textView) = try caretRig(input: "")
        #expect(window.performKeyEquivalent(with: try key(VirtualKey.upArrow.rawValue, [.command], in: window)))
        #expect(rig.chat.threadScrollRequest?.target == .top)
        #expect(textView.selectedRange().location == 0)
    }

    @Test func aChooserOverTheComposerKeepsItsArrows() throws {
        let (rig, _, _) = try caretRig(input: Self.draft)
        #expect(ComposerCaretMove.composerKeepsKeys(rig.model))
        rig.chat.isModelChooserPresented = true
        #expect(!ComposerCaretMove.composerKeepsKeys(rig.model))
        rig.chat.isModelChooserPresented = false
        rig.model.focus = .find
        #expect(!ComposerCaretMove.composerKeepsKeys(rig.model))
    }

    @Test func onlyTheNamedKeysAreCaretMoves() {
        let up = VirtualKey.upArrow.rawValue
        let down = VirtualKey.downArrow.rawValue
        #expect(ComposerCaretMove(keyCode: up, modifiers: [.command]) == .documentStart)
        #expect(ComposerCaretMove(keyCode: down, modifiers: [.command]) == .documentEnd)
        #expect(ComposerCaretMove(keyCode: up, modifiers: [.option]) == .paragraphBackward)
        #expect(ComposerCaretMove(keyCode: down, modifiers: [.option]) == .paragraphForward)
        #expect(ComposerCaretMove(keyCode: VirtualKey.pageUp.rawValue, modifiers: []) == .pageUp)
        #expect(ComposerCaretMove(keyCode: VirtualKey.pageDown.rawValue, modifiers: []) == .pageDown)
        // Plain arrows are the composer's own routing; ⇧⌘↑ selects.
        #expect(ComposerCaretMove(keyCode: up, modifiers: []) == nil)
        #expect(ComposerCaretMove(keyCode: up, modifiers: [.command, .shift]) == nil)
        #expect(ComposerCaretMove(keyCode: VirtualKey.return.rawValue, modifiers: [.command]) == nil)
    }

    // MARK: - 19. The launcher's display

    private let displayA = ScreenArea(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
    )
    private let displayB = ScreenArea(
        frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1440, y: 60, width: 1920, height: 995)
    )

    @Test func aFrameOnAnotherDisplayMovesKeepingItsSize() throws {
        let saved = CGRect(x: 100, y: 100, width: 860, height: 620)
        #expect(AIChatWindowController.frame(saved, movedOnto: displayA) == nil)
        let moved = try #require(AIChatWindowController.frame(saved, movedOnto: displayB))
        #expect(moved.size == saved.size)
        // Centred, to the whole point.
        #expect(abs(moved.midX - displayB.visibleFrame.midX) <= 0.5)
        #expect(abs(moved.midY - displayB.visibleFrame.midY) <= 0.5)
    }

    @Test func aFrameTallerThanTheDisplayIsCutToFit() throws {
        let tall = CGRect(x: 2000, y: 0, width: 1000, height: 1000)
        let moved = try #require(AIChatWindowController.frame(tall, movedOnto: displayA))
        #expect(moved.size == CGSize(width: 1000, height: 875))
        #expect(displayA.visibleFrame.contains(moved))
    }

    @Test func openingMovesTheWindowToTheLaunchersDisplayOnce() {
        let rig = makeRig()
        let window = rig.controller.prepareWindow()
        window.setFrame(CGRect(x: 100, y: 100, width: 860, height: 620), display: false)
        rig.controller.openingScreen = displayB
        rig.model.open(handoff: nil)
        #expect(window.frame.size == CGSize(width: 860, height: 620))
        #expect(displayB.frame.contains(CGPoint(x: window.frame.midX, y: window.frame.midY)))
        #expect(rig.controller.openingScreen == nil)
        #expect(rig.shell.presents == 1)

        // A later show (a capture's recovery) leaves the frame alone.
        window.setFrame(CGRect(x: 100, y: 100, width: 860, height: 620), display: false)
        rig.controller.showWindow()
        #expect(window.frame.origin == CGPoint(x: 100, y: 100))
    }

    // MARK: - 21. The menu bar and other windows; full screen

    @Test func theMenuBarStaysWhileAnotherNormalWindowIsUp() {
        let settings = WindowPresence(isNormal: true, isShown: true)
        let hiddenSettings = WindowPresence(isNormal: true, isShown: false)
        let launcher = WindowPresence(isNormal: false, isShown: true)
        #expect(AppActivation.keepsRegularApp(otherWindows: [settings, launcher]))
        #expect(!AppActivation.keepsRegularApp(otherWindows: [hiddenSettings, launcher]))
        #expect(!AppActivation.keepsRegularApp(otherWindows: []))
    }

    @Test func onlyTitledWindowsCountAsNormal() {
        let titled = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        #expect(WindowPresence(titled) == WindowPresence(isNormal: true, isShown: false))
        #expect(WindowPresence(panel) == WindowPresence(isNormal: false, isShown: false))
    }

    @Test func closingHandsTheMenuBarDecisionToTheShell() {
        let rig = makeRig()
        let window = rig.controller.prepareWindow()
        rig.controller.windowWillClose(closeNotification(window))
        #expect(rig.shell.closes.first === window)
    }

    @Test func fullScreenDropsTheTrafficLightInset() {
        let rig = makeRig()
        let note = Notification(name: NSWindow.willEnterFullScreenNotification)
        #expect(!rig.model.isWindowFullScreen)
        rig.controller.windowWillEnterFullScreen(note)
        #expect(rig.model.isWindowFullScreen)
        rig.controller.windowWillExitFullScreen(note)
        #expect(!rig.model.isWindowFullScreen)
        rig.controller.windowWillEnterFullScreen(note)
        rig.controller.windowDidFailToEnterFullScreen(rig.controller.prepareWindow())
        #expect(!rig.model.isWindowFullScreen)
        // A window model without the app's window never reads full screen.
        let bare = AIChatWindowModel(chat: QuickViewModel(service: MockQuickService()))
        bare.window = FakeAIChatWindow()
        #expect(!bare.isWindowFullScreen)
    }

    // MARK: - 22. Keep on Top pauses for pi

    /// A chat with one answer, handed to a probe that notes the level.
    private func handOffRig(
        openedGhostty: Bool = true,
        fails: Bool = false,
        alwaysOnTop: Bool = true
    ) async -> (Rig, LevelBox) {
        let box = LevelBox()
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Lima is the capital of Peru.", finishReason: "stop")])
        let rig = makeRig(
            service: mock,
            piHandoff: LevelProbePiHandoff(openedGhostty: openedGhostty, fails: fails) { box.note() },
            alwaysOnTop: alwaysOnTop
        )
        box.window = rig.controller.prepareWindow()
        rig.controller.showWindow()
        rig.chat.input = "tell me about Lima"
        await rig.chat.submit()
        return (rig, box)
    }

    @Test func keepOnTopDropsWhileGhosttyOpensAndReturnsWithTheChat() async throws {
        let (rig, box) = await handOffRig()
        let window = try #require(box.window)
        #expect(window.level == .floating)

        await rig.chat.continueInPi()
        #expect(box.levels == [.normal])
        #expect(window.level == .normal, "Ghostty's window must not open under the chat")
        #expect(rig.model.isAlwaysOnTop, "the setting stays on")

        rig.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(window.level == .floating)
    }

    @Test func keepOnTopReturnsAtOnceWhenGhosttyDidNotOpen() async throws {
        let (rig, box) = await handOffRig(openedGhostty: false)
        await rig.chat.continueInPi()
        #expect(box.levels == [.normal])
        #expect(box.window?.level == .floating)

        let (failing, failingBox) = await handOffRig(fails: true)
        await failing.chat.continueInPi()
        #expect(failingBox.levels == [.normal])
        #expect(failingBox.window?.level == .floating)
    }

    @Test func withoutKeepOnTopTheHandOffLeavesTheLevelAlone() async {
        let (rig, box) = await handOffRig(alwaysOnTop: false)
        await rig.chat.continueInPi()
        #expect(box.levels == [.normal])
        #expect(!rig.controller.isKeepOnTopPaused)
    }

    @Test func turningKeepOnTopOffEndsThePause() async throws {
        let (rig, box) = await handOffRig()
        await rig.chat.continueInPi()
        rig.model.isAlwaysOnTop = false
        rig.model.isAlwaysOnTop = true
        #expect(!rig.controller.isKeepOnTopPaused)
        #expect(box.window?.level == .floating)
    }

    // MARK: - 2. Back after a capture

    @Test func theWindowComesBackAfterACapture() {
        let rig = makeRig()
        rig.controller.prepareWindow()
        // A restore with nothing hidden does nothing.
        rig.controller.restoreAfterExternalAction()
        #expect(rig.shell.presents == 0)

        rig.chat.prepareForExternalAction?()
        #expect(rig.controller.isHiddenForCapture)
        rig.controller.restoreAfterExternalAction()
        #expect(rig.shell.presents == 1)
        #expect(!rig.controller.isHiddenForCapture)
        rig.controller.restoreAfterExternalAction()
        #expect(rig.shell.presents == 1)
    }

    @Test func aFailedCaptureStillShowsTheWindow() {
        let rig = makeRig()
        rig.controller.prepareWindow()
        rig.chat.prepareForExternalAction?()
        rig.chat.recoverFromExternalActionFailure?()
        #expect(rig.shell.presents == 1)
        #expect(!rig.controller.isHiddenForCapture)
    }
}

/// The window level at each hand-off.
@MainActor
final class LevelBox {
    weak var window: NSWindow?
    var levels: [NSWindow.Level] = []
    func note() { levels.append(window?.level ?? .normal) }
}
