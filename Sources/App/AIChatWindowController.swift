import AppKit
import SwiftUI

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
        guard let key = VirtualKey(event: event) else { return false }
        if key == .escape, modifiers.isEmpty {
            return model.handleEscape()
        }
        guard key.isReturn else { return false }
        if modifiers.isEmpty {
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
}

/// Owns the AI Chat window: builds it once, shows it (joining ⌘Tab and the
/// Dock while it is open), keeps its frame, and floats it for Keep on Top.
/// It is the window's view model's presenter too: nothing an answer does
/// closes this window, and an area capture hides it only for the capture.
@MainActor
final class AIChatWindowController: NSObject, NSWindowDelegate, AIChatWindowPresenting, OverlayPresenting {
    static let frameAutosaveName = "QuickLaunch.AIChatWindow"

    let model: AIChatWindowModel
    /// The app's own presenter (Settings, the Translator, Type to Click).
    private weak var app: (any OverlayPresenting)?
    private var window: AIChatWindow?
    /// The window itself, for the menu bar's window items.
    var chatWindow: NSWindow? { window }
    /// The menu bar shown while the window is open.
    private lazy var menu = AIChatMenu(controller: self)

    init(model: AIChatWindowModel, app: any OverlayPresenting) {
        self.model = model
        self.app = app
        super.init()
        model.window = self
        model.chat.overlayPresenter = self
        model.chat.prepareForExternalAction = { [weak self] in self?.hideWindowForCapture() }
        model.chat.recoverFromExternalActionFailure = { [weak self] in self?.showWindow() }
    }

    var isVisible: Bool { window?.isVisible == true }

    // MARK: - AIChatWindowPresenting

    func showWindow() {
        let window = self.window ?? makeWindow()
        window.appearance = model.chat.settings.appearance.nsAppearance
        applyLevel(model.isAlwaysOnTop, to: window)
        // A normal window: in ⌘Tab, the Dock, and Mission Control while open.
        // A normal window gets a normal menu bar: Edit for the composer,
        // Window for minimise and close, and Quit.
        if NSApp.mainMenu == nil { NSApp.mainMenu = menu.makeMenu() }
        AppActivation.becomeRegularApp(showing: window)
    }

    func hideWindowForCapture() {
        window?.orderOut(nil)
    }

    func setAlwaysOnTop(_ onTop: Bool) {
        guard let window else { return }
        applyLevel(onTop, to: window)
    }

    private func applyLevel(_ onTop: Bool, to window: NSWindow) {
        // Floating sits under the launcher panel (floating + 1).
        window.level = onTop ? .floating : .normal
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

    // MARK: - Window

    private func makeWindow() -> AIChatWindow {
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
        toolbar.showsBaselineSeparator = false
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
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
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

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        // Back from the launcher: the chat as the store has it now (a
        // follow-up asked there, a rename, a pin, a delete).
        model.chat.refreshOpenChatFromStore()
    }

    func windowWillClose(_ notification: Notification) {
        // A stream belongs to the window; closing stops it and keeps what
        // arrived, as Escape does. The chat stays in the window for next time.
        if model.chat.isStreaming { model.chat.cancel() }
        model.closeFind()
        // Back to a menu-bar app once no normal window is open, with no menu
        // bar of its own (the launcher panel keeps its keys).
        NSApp.mainMenu = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
