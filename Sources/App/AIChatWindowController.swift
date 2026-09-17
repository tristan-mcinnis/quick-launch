import AppKit
import Observation
import SwiftUI
import UserNotifications

/// The AI Chat window's NSWindow: keys first to the window model, then to
/// AppKit. Unmodified keys never reach `performKeyEquivalent`, and a text
/// view eats Return and Escape before SwiftUI sees them, so Return, `⇧↩`,
/// and Escape are taken in `sendEvent`, as the launcher panel does.
final class AIChatWindow: NSWindow {
    weak var model: AIChatWindowModel?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let model, handleKeyDown(event, model: model) {
            return
        }
        super.sendEvent(event)
    }

    private func handleKeyDown(_ event: NSEvent, model: AIChatWindowModel) -> Bool {
        let modifiers = event.modifierFlags.overlayRelevant
        let textView = firstResponder as? NSTextView
        // An input method's composition (pinyin, for one) owns Return and
        // Escape until it commits.
        if textView?.hasMarkedText() == true { return false }
        // The draft's own caret keys, before the thread's scrolling (the
        // composer's key routing) can take them.
        if routeComposerCaretKey(event, model: model) { return true }
        guard let key = VirtualKey(event: event) else { return false }
        if key == .escape, modifiers.isEmpty {
            return model.handleEscape()
        }
        guard key.isReturn else { return false }
        if modifiers.isEmpty {
            return model.handleReturn()
        }
        if modifiers == [.command] {
            // ⌘↩ always sends, whatever the composer holds.
            return model.handleReturn()
        }
        if modifiers == [.shift] {
            switch model.handleShiftReturn() {
            case .insertNewline:
                // At the caret, in the field editor or the text view alike.
                textView?.insertNewlineIgnoringFieldEditor(nil)
                return textView != nil
            case .handled:
                return true
            case .ignored:
                return false
            }
        }
        return false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.overlayRelevant
        if event.type == .keyDown, modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        // AppKit offers `⌘↑` and its kind here before `sendEvent`: the
        // draft keeps them, not the chat's thread shortcuts.
        if event.type == .keyDown, let model, (firstResponder as? NSTextView)?.hasMarkedText() != true,
           routeComposerCaretKey(event, model: model) {
            return true
        }
        if event.type == .keyDown, !modifiers.isEmpty, modifiers != [.shift],
           model?.handleKeyEquivalent(
               characters: event.charactersIgnoringModifiers,
               keyCode: event.keyCode,
               modifiers: modifiers
           ) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// `⌘↑` `⌘↓`, `⌥↑` `⌥↓`, and PageUp PageDown in the multi-line
    /// composer with text in it: the text view moves its caret, as in any
    /// text editor. The thread scrolls on these keys only when the draft is
    /// empty (the thread's own rule, `handleThreadKey`).
    private func routeComposerCaretKey(_ event: NSEvent, model: AIChatWindowModel) -> Bool {
        guard event.type == .keyDown,
              let move = ComposerCaretMove(keyCode: event.keyCode, modifiers: event.modifierFlags.overlayRelevant),
              ComposerCaretMove.composerKeepsKeys(model),
              let textView = firstResponder as? NSTextView
        else { return false }
        move.apply(to: textView)
        return true
    }
}

/// A caret key the AI Chat composer keeps while it holds a draft, and the
/// move it makes. The moves are the text system's own (its standard key
/// bindings), called on the text view directly, so no key routing above the
/// field sees the key on its way.
enum ComposerCaretMove: Equatable, Sendable {
    /// `⌘↑`: the start of the draft.
    case documentStart
    /// `⌘↓`: the end of the draft.
    case documentEnd
    /// `⌥↑`: the start of the paragraph, then the one before.
    case paragraphBackward
    /// `⌥↓`: the end of the paragraph, then the one after.
    case paragraphForward
    /// PageUp: a page up. The field holds eight lines, so a short draft's
    /// page is all of it: the caret goes to its start.
    case pageUp
    /// PageDown: a page down, or the end of a short draft.
    case pageDown

    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let key = VirtualKey(rawValue: keyCode)
        switch key {
        case .upArrow where modifiers == [.command]: self = .documentStart
        case .downArrow where modifiers == [.command]: self = .documentEnd
        case .upArrow where modifiers == [.option]: self = .paragraphBackward
        case .downArrow where modifiers == [.option]: self = .paragraphForward
        case .pageUp where modifiers.isEmpty: self = .pageUp
        case .pageDown where modifiers.isEmpty: self = .pageDown
        default: return nil
        }
    }

    /// The composer takes the key: it has the keyboard, it holds text, and
    /// nothing is over it (a chooser, the question card, the `⌘K` palette,
    /// or Recent Chats keeps its own arrows).
    @MainActor
    static func composerKeepsKeys(_ model: AIChatWindowModel) -> Bool {
        let chat = model.chat
        return model.focus == .composer
            && !chat.input.isEmpty
            && !chat.isRecentChatsPresented
            && !chat.isAskQuestionActive
            && !chat.isTransformChooserPresented
            && !chat.isModelChooserPresented
            && !chat.isAssistantChooserPresented
            && !chat.isAddContextMenuPresented
            && !chat.isActionPalettePresented
            && !chat.isItemActionPanePresented
    }

    @MainActor
    func apply(to textView: NSTextView) {
        switch self {
        case .documentStart:
            textView.moveToBeginningOfDocument(nil)
        case .documentEnd:
            textView.moveToEndOfDocument(nil)
        case .paragraphBackward:
            textView.moveBackward(nil)
            textView.moveToBeginningOfParagraph(nil)
        case .paragraphForward:
            textView.moveForward(nil)
            textView.moveToEndOfParagraph(nil)
        case .pageUp:
            if textView.enclosingScrollView != nil {
                textView.pageUp(nil)
            } else {
                textView.moveToBeginningOfDocument(nil)
            }
        case .pageDown:
            if textView.enclosingScrollView != nil {
                textView.pageDown(nil)
            } else {
                textView.moveToEndOfDocument(nil)
            }
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }
}

/// A display, as the window's placement needs it.
struct ScreenArea: Equatable, Sendable {
    var frame: CGRect
    var visibleFrame: CGRect

    init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    @MainActor
    init(_ screen: NSScreen) {
        frame = screen.frame
        visibleFrame = screen.visibleFrame
    }
}

/// What the window's view reads about the window itself.
@Observable @MainActor
final class AIChatWindowChrome {
    /// In full screen the title bar and its traffic lights are hidden, so
    /// the header drops the room it keeps for them.
    var isFullScreen = false
}

extension AIChatWindowModel {
    /// The window is in full screen: the header has no traffic lights to
    /// make room for. False for a window that is not the app's (tests).
    var isWindowFullScreen: Bool {
        (window as? AIChatWindowController)?.chrome.isFullScreen ?? false
    }
}

/// The app around the AI Chat window: activation, the menu bar, and what
/// is on screen. The app's own is `SystemAIChatAppShell`; tests pass a fake,
/// so nothing activates, installs a menu, or reaches the screen.
@MainActor
protocol AIChatAppShell: AnyObject {
    /// Turns the app into a normal app with `menu` as its menu bar (unless
    /// it has one) and brings `window` to the front with the keyboard.
    func present(_ window: NSWindow, menu: () -> NSMenu)
    /// Re-installs the menu bar from `menu` after an in-app shortcut was
    /// rebound. A shell with no menu bar of its own does nothing.
    func refreshMenu(_ menu: () -> NSMenu)
    /// `window` is closing: back to a menu-bar app unless another normal
    /// window is still up.
    func windowWillClose(_ window: NSWindow)
    /// Whether `window` is on screen now.
    func isOnScreen(_ window: NSWindow) -> Bool
}

extension AIChatAppShell {
    /// A test shell has no menu bar; a rebind has nothing to refresh.
    func refreshMenu(_ menu: () -> NSMenu) {}
}

@MainActor
final class SystemAIChatAppShell: AIChatAppShell {
    func present(_ window: NSWindow, menu: () -> NSMenu) {
        // A normal window gets a normal menu bar: Edit for the composer,
        // Window for minimise and close, and Quit.
        if NSApp.mainMenu == nil { NSApp.mainMenu = menu() }
        AppActivation.becomeRegularApp(showing: window)
    }

    func windowWillClose(_ window: NSWindow) {
        AppActivation.settleAfterClosing(window)
    }

    func isOnScreen(_ window: NSWindow) -> Bool { window.isVisible }

    func refreshMenu(_ menu: () -> NSMenu) {
        // Only while this app still owns a menu bar. As a menu-bar app it has
        // none, and nothing is installed.
        guard NSApp.mainMenu != nil else { return }
        NSApp.mainMenu = menu()
    }
}

/// A notice that an answer finished while the AI Chat window was closed.
struct AnswerNotice: Equatable, Sendable {
    /// The chat it belongs to; a later notice for the same chat replaces it.
    let chatID: UUID
    let title: String
    let body: String
}

/// Posts `AnswerNotice`s. The app's own is `UserNotificationAnswerNotifier`.
@MainActor
protocol AnswerNotifying: AnyObject {
    /// Called when the user clicks a posted notice.
    var onOpen: (() -> Void)? { get set }
    func post(_ notice: AnswerNotice) async
}

/// Answer notices as macOS notifications. Nothing is asked of the user
/// until the first answer finishes with the window closed; then macOS asks
/// once for permission. Denied, nothing is ever shown. A notice is one
/// line in Notification Center: no sound, no badge.
@MainActor
final class UserNotificationAnswerNotifier: AnswerNotifying {
    var onOpen: (() -> Void)? {
        didSet { center?.onOpen = onOpen }
    }
    private let makeCenter: () -> any UserNotificationCentering
    /// Made on the first notice, never before: the system center needs an
    /// app bundle, and most runs never post one.
    private var center: (any UserNotificationCentering)?

    init(center makeCenter: @escaping () -> any UserNotificationCentering = { SystemUserNotificationCenter() }) {
        self.makeCenter = makeCenter
    }

    func post(_ notice: AnswerNotice) async {
        let center = self.center ?? makeCenter()
        if self.center == nil {
            center.onOpen = onOpen
            self.center = center
        }
        switch await center.authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            guard await center.requestAlertAuthorization() else { return }
        case .denied:
            return
        @unknown default:
            return
        }
        await center.add(
            identifier: "AIChatAnswer.\(notice.chatID.uuidString)",
            title: notice.title,
            body: notice.body
        )
    }
}

/// The part of the notification center answer notices use.
@MainActor
protocol UserNotificationCentering: AnyObject {
    /// Called when the user clicks a notice.
    var onOpen: (() -> Void)? { get set }
    func authorizationStatus() async -> UNAuthorizationStatus
    /// Asks for banners only (no sound, no badge). True when allowed.
    func requestAlertAuthorization() async -> Bool
    /// Shows a notice now. The same identifier replaces the last one.
    func add(identifier: String, title: String, body: String) async
}

/// `UNUserNotificationCenter`, and its delegate so a click opens the chat.
@MainActor
final class SystemUserNotificationCenter: NSObject, UserNotificationCentering, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?
    private let center: UNUserNotificationCenter

    override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAlertAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert])) == true
    }

    func add(identifier: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { self.onOpen?() }
    }
}

/// Continue in pi from the AI Chat window. With Keep on Top on, the window
/// drops to a normal level before Ghostty opens, so the new terminal is
/// not under it. The level comes back when the user returns to the chat,
/// or at once when Ghostty did not open.
struct KeepOnTopPausingPiHandoff: PiHandoffServicing {
    let inner: any PiHandoffServicing
    let willHandOff: @MainActor @Sendable () -> Void
    let didHandOff: @MainActor @Sendable (_ openedGhostty: Bool) -> Void

    func handOff(_ request: PiHandoffRequest) async throws -> PiHandoffResult {
        await willHandOff()
        do {
            let result = try await inner.handOff(request)
            await didHandOff(result.openedGhostty)
            return result
        } catch {
            await didHandOff(false)
            throw error
        }
    }
}

/// Owns the AI Chat window: builds it once, shows it (joining ⌘Tab and the
/// Dock while it is open), keeps its frame, and floats it for Keep on Top.
/// It is the window's view model's presenter too: nothing an answer does
/// closes this window, and an area capture hides it only for the capture.
///
/// The view model outlives the window: `⌘W` closes the window and an
/// answer still streaming goes on, is saved as it ends, and, when it ends
/// with the window still closed, posts a notice (`AnswerNotifying`).
@MainActor
final class AIChatWindowController: NSObject, NSWindowDelegate, AIChatWindowPresenting, OverlayPresenting {
    static let frameAutosaveName = "QuickLaunch.AIChatWindow"

    let model: AIChatWindowModel
    /// What the view reads about the window (full screen).
    let chrome = AIChatWindowChrome()
    /// The app's own presenter (Settings, the Translator, Type to Click).
    private weak var app: (any OverlayPresenting)?
    private let shell: any AIChatAppShell
    private let notifier: any AnswerNotifying
    private let autosaveName: String?
    private var window: AIChatWindow?
    /// The window itself, for the menu bar's window items.
    var chatWindow: NSWindow? { window }
    /// The menu bar shown while the window is open.
    private lazy var menu = AIChatMenu(controller: self)

    /// The display the next open lands on: the launcher's, or the one under
    /// the pointer. A frame saved on another display moves here, keeping
    /// its size. Set just before an open; the open uses it once.
    var openingScreen: ScreenArea?
    /// Keep on Top is paused for a Continue in pi hand-off (the setting
    /// itself stays on).
    private(set) var isKeepOnTopPaused = false
    /// The window is ordered out for an area capture, not closed.
    private(set) var isHiddenForCapture = false
    /// Watches the stream so an answer that ends with the window closed
    /// posts a notice.
    private var streamWatch: Task<Void, Never>?
    /// Rebuilds the menu bar after an in-app shortcut is rebound.
    private var menuRefreshTask: Task<Void, Never>?

    init(
        model: AIChatWindowModel,
        app: any OverlayPresenting,
        shell: any AIChatAppShell = SystemAIChatAppShell(),
        notifier: any AnswerNotifying = UserNotificationAnswerNotifier(),
        frameAutosaveName: String? = AIChatWindowController.frameAutosaveName
    ) {
        self.model = model
        self.app = app
        self.shell = shell
        self.notifier = notifier
        self.autosaveName = frameAutosaveName
        super.init()
        model.window = self
        model.chat.overlayPresenter = self
        model.chat.prepareForExternalAction = { [weak self] in self?.hideWindowForCapture() }
        model.chat.recoverFromExternalActionFailure = { [weak self] in self?.showWindow() }
        if let piHandoff = model.chat.piHandoff {
            model.chat.piHandoff = KeepOnTopPausingPiHandoff(
                inner: piHandoff,
                willHandOff: { [weak self] in self?.pauseKeepOnTopForHandoff() },
                didHandOff: { [weak self] opened in
                    // Ghostty came up: the level comes back when the user
                    // returns to the chat (`windowDidBecomeKey`).
                    if !opened { self?.resumeKeepOnTop() }
                }
            )
        }
        notifier.onOpen = { [weak self] in self?.model.open(handoff: nil) }
        menuRefreshTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .shortcutBindingsChanged) {
                guard let self else { return }
                // The menu bar is built once per regular-app session, so a
                // rebind has to re-install it or the old key equivalent stays
                // live in the menu while the router already answers the new one.
                self.shell.refreshMenu { self.menu.makeMenu() }
            }
        }
        watchStream()
    }

    isolated deinit {
        streamWatch?.cancel()
        menuRefreshTask?.cancel()
    }

    var isVisible: Bool { window.map(shell.isOnScreen) ?? false }

    // MARK: - AIChatWindowPresenting

    func showWindow() {
        let window = prepareWindow()
        isHiddenForCapture = false
        window.appearance = model.chat.settings.appearance.nsAppearance
        applyLevel(to: window)
        if let screen = openingScreen {
            openingScreen = nil
            place(window, on: screen)
        }
        shell.present(window) { menu.makeMenu() }
    }

    func hideWindowForCapture() {
        guard let window else { return }
        isHiddenForCapture = true
        window.orderOut(nil)
    }

    /// The view model calls this after an external action that hid the
    /// window ends well: a Selected Area capture that attached its image.
    /// The window comes back with the keyboard, as it does after a failure
    /// (`recoverFromExternalActionFailure`). Nothing happens when no capture
    /// hid the window. The view model's `restoreAfterExternalAction`
    /// callback is wired to this.
    func restoreAfterExternalAction() {
        guard isHiddenForCapture else { return }
        showWindow()
    }

    func setAlwaysOnTop(_ onTop: Bool) {
        // A change of the setting ends a pause for a hand-off.
        isKeepOnTopPaused = false
        guard let window else { return }
        applyLevel(to: window)
    }

    private func applyLevel(to window: NSWindow) {
        // Floating sits under the launcher panel (floating + 1).
        window.level = model.isAlwaysOnTop && !isKeepOnTopPaused ? .floating : .normal
    }

    /// A hand-off to pi is about to open Ghostty.
    func pauseKeepOnTopForHandoff() {
        guard model.isAlwaysOnTop else { return }
        isKeepOnTopPaused = true
        if let window { applyLevel(to: window) }
    }

    /// Keep on Top back as the setting says.
    func resumeKeepOnTop() {
        guard isKeepOnTopPaused else { return }
        isKeepOnTopPaused = false
        if let window { applyLevel(to: window) }
    }

    // MARK: - OverlayPresenting (the window's view model)

    func presentOverlay() { showWindow() }
    /// The window stays: a copy, a hand-off to pi, or a Read Aloud never
    /// closes it. `⌘W` and the close button do.
    func dismissOverlay() {}
    func openSettings() { app?.openSettings() }
    func openTranslator() { app?.openTranslator() }
    func openTranslator(retainedSelection: String?) { app?.openTranslator(retainedSelection: retainedSelection) }
    func openTypeToClick() { app?.openTypeToClick() }

    // MARK: - Closing and quitting

    /// `⌘Q` in the chat's menu bar: the window closes, the launcher stays.
    func closeWindow() {
        window?.performClose(nil)
    }

    /// The app is quitting: the watch stops (a quit is not an answer to
    /// announce), and a stream in either view stops, keeping its question
    /// and what arrived. The caller then waits for the history file.
    func prepareForTermination() {
        streamWatch?.cancel()
        streamWatch = nil
        Self.keepStreamForQuit(model.chat)
    }

    /// Stops `chat`'s stream as Escape does (the text that arrived becomes
    /// the answer) and saves the chat, so the question is kept even when no
    /// text had arrived. A chat with no turn yet (a web search still running
    /// before the question became one) is not saved empty.
    static func keepStreamForQuit(_ chat: QuickViewModel) {
        guard chat.isStreaming else { return }
        chat.cancel()
        guard chat.currentConversation?.messages.isEmpty == false else { return }
        chat.persistCurrentConversation()
    }

    // MARK: - Answer notices

    private func watchStream() {
        let chat = model.chat
        streamWatch = Task { [weak self] in
            var wasStreaming = chat.isStreaming
            for await isStreaming in Observations({ chat.isStreaming }) {
                if wasStreaming, !isStreaming { await self?.answerDidEnd() }
                wasStreaming = isStreaming
            }
        }
    }

    /// An answer ended. Open, the window shows it; closed (or minimised,
    /// or the app hidden), a notice says so.
    private func answerDidEnd() async {
        guard !isVisible, !isHiddenForCapture, let notice = Self.notice(for: model.chat) else { return }
        await notifier.post(notice)
    }

    /// The notice for the chat's last answer, or nil when the chat has no
    /// answer to announce (a stop before any text).
    static func notice(for chat: QuickViewModel) -> AnswerNotice? {
        guard let conversation = chat.currentConversation else { return nil }
        let title = chat.title(of: conversation)
        if chat.threadError != nil {
            return AnswerNotice(chatID: conversation.id, title: "Answer stopped", body: title)
        }
        guard conversation.messages.last?.role == .assistant else { return nil }
        return AnswerNotice(chatID: conversation.id, title: "Answer ready", body: title)
    }

    // MARK: - Window

    /// The window, built on first use. Building it shows nothing.
    @discardableResult
    func prepareWindow() -> AIChatWindow {
        if let window { return window }
        let size = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
        let window = AIChatWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.model = model
        window.title = "AI Chat"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title-bar row as tall as the
        // header, so the traffic lights centre on the header's row; the
        // content runs up under it (`ignoresSafeArea` in the view).
        let toolbar = NSToolbar(identifier: "AIChatWindow")
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // A normal window moves by its title-bar row only; selecting text in
        // the thread must not drag it (the header carries the drag).
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenPrimary]
        window.contentMinSize = NSSize(width: House.Layout.chatMinWidth, height: House.Layout.chatMinHeight)
        window.delegate = self
        let hosting = NSHostingController(rootView: AIChatWindowView(model: model))
        // The window sizes the view, not the other way round: the frame is
        // the user's (autosaved), from the minimum up.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(size)
        if let autosaveName {
            if !window.setFrameUsingName(autosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(autosaveName)
        } else {
            window.center()
        }
        // A frame saved smaller than today's minimum comes back at the
        // standard size.
        let content = window.contentRect(forFrameRect: window.frame).size
        if content.width < House.Layout.chatMinWidth || content.height < House.Layout.chatMinHeight {
            window.setContentSize(size)
            window.center()
        }
        self.window = window
        return window
    }

    /// Moves `window` onto `screen` when its frame is on another display,
    /// keeping its size. A full-screen window keeps its own space.
    private func place(_ window: NSWindow, on screen: ScreenArea) {
        guard !window.styleMask.contains(.fullScreen),
              let frame = Self.frame(window.frame, movedOnto: screen)
        else { return }
        window.setFrame(frame, display: false)
    }

    /// `frame` centred in `screen`'s visible frame, at its own size (cut to
    /// fit a smaller display), or nil when its centre is already on that
    /// display.
    static func frame(_ frame: CGRect, movedOnto screen: ScreenArea) -> CGRect? {
        guard !screen.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        let visible = screen.visibleFrame
        let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        return CGRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // Back from pi's terminal: Keep on Top again.
        resumeKeepOnTop()
        // Back from the launcher: the chat as the store has it now (a
        // follow-up asked there, a rename, a pin, a delete).
        model.chat.aiChatWindowDidBecomeKey()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        chrome.isFullScreen = true
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        chrome.isFullScreen = false
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        chrome.isFullScreen = false
    }

    func windowWillClose(_ notification: Notification) {
        // An answer still streaming goes on: the view model lives on, the
        // answer is saved as it ends, and a notice says when it is ready.
        // The chat stays in the window for next time.
        model.closeFind()
        chrome.isFullScreen = false
        guard let window else { return }
        // Back to a menu-bar app once no other normal window is open.
        shell.windowWillClose(window)
    }
}
