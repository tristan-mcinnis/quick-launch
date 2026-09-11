import AppKit

/// The menu bar while the AI Chat window is open.
///
/// Quick Launch is a menu-bar app with no main menu, so a normal window had
/// no Edit menu (copy, paste, select all, and undo in the composer), no
/// Window menu, and no Quit. This menu is installed when the window opens
/// and removed once no normal window is open (`AppActivation`), so the
/// launcher panel keeps its own keys.
///
/// `⌘Q` closes AI Chat, not the app: the launcher and its hotkey must
/// survive a stray `⌘Q`. Quit Quick Launch is `⌥⌘Q`. The chat items act
/// only while the chat window is key; Hide and the window items act on the
/// key window when it is a normal one (AI Chat or Settings). The launcher
/// panel can be key at the same time, and then none of them act.
@MainActor
final class AIChatMenu: NSObject, NSMenuItemValidation {
    private weak var controller: AIChatWindowController?

    init(controller: AIChatWindowController) {
        self.controller = controller
        super.init()
    }

    func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = submenu(in: main, title: "Quick Launch")
        app.addItem(item("About Quick Launch", #selector(about), ""))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(openSettings), ","))
        app.addItem(.separator())
        app.addItem(item("Hide Quick Launch", #selector(hideApp), "h"))
        app.addItem(.separator())
        app.addItem(item(Self.closeChatTitle, #selector(closeChat), "q"))
        app.addItem(item(Self.quitTitle, #selector(quit), "q", [.command, .option]))

        let edit = submenu(in: main, title: "Edit")
        edit.addItem(responderItem("Undo", Selector(("undo:")), "z"))
        edit.addItem(responderItem("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(responderItem("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(responderItem("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(responderItem("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(responderItem("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        edit.addItem(item("Find in Chat", #selector(find), "f"))

        let view = submenu(in: main, title: "View")
        view.addItem(item("Show Chat List", #selector(toggleChatList), "\\"))

        let window = submenu(in: main, title: "Window")
        window.addItem(item("Minimize", #selector(minimize), "m"))
        window.addItem(item("Zoom", #selector(zoom), ""))
        window.addItem(item("Keep on Top", #selector(toggleKeepOnTop), ""))
        window.addItem(.separator())
        window.addItem(item("Close", #selector(close), "w"))
        return main
    }

    // MARK: - Building

    private func submenu(in main: NSMenu, title: String) -> NSMenu {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private func item(
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    /// An Edit item that goes to the first responder, the focused text field.
    private func responderItem(
        _ title: String,
        _ action: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    // MARK: - Actions

    static let closeChatTitle = "Close AI Chat"
    static let quitTitle = "Quit Quick Launch"

    private var chatWindow: NSWindow? { controller?.chatWindow }
    private var chatIsKey: Bool { chatWindow != nil && NSApp.keyWindow === chatWindow }
    /// The key window when it is a normal, titled one: AI Chat or Settings.
    private var normalKeyWindow: NSWindow? {
        guard let key = NSApp.keyWindow, key.styleMask.contains(.titled) else { return nil }
        return key
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(about), #selector(openSettings), #selector(quit):
            return true
        case #selector(hideApp), #selector(minimize), #selector(zoom), #selector(close):
            return normalKeyWindow != nil
        case #selector(toggleChatList):
            menuItem.title = controller?.model.isRailVisible == true ? "Hide Chat List" : "Show Chat List"
            return chatIsKey
        case #selector(toggleKeepOnTop):
            menuItem.state = controller?.model.isAlwaysOnTop == true ? .on : .off
            return chatIsKey
        default:
            return chatIsKey
        }
    }

    @objc private func about() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func openSettings() { controller?.openSettings() }
    @objc private func hideApp() { NSApp.hide(nil) }
    @objc private func closeChat() { controller?.closeWindow() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func find() { controller?.model.openFind() }
    @objc private func toggleChatList() { controller?.model.toggleRail() }
    @objc private func minimize() { normalKeyWindow?.performMiniaturize(nil) }
    @objc private func zoom() { normalKeyWindow?.performZoom(nil) }
    @objc private func close() { normalKeyWindow?.performClose(nil) }
    @objc private func toggleKeepOnTop() { controller?.model.isAlwaysOnTop.toggle() }
}
