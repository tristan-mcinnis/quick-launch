import AppKit

/// The menu bar while the AI Chat window is open.
///
/// Quick Launch is a menu-bar app with no main menu, so a normal window had
/// no Edit menu (copy, paste, select all, and undo in the composer), no
/// Window menu, and no Quit. This menu is installed when the window opens
/// and removed when it closes, so the launcher panel keeps its own keys.
/// Quit, Hide, and the window items act only while the chat window is key;
/// the launcher panel can be key at the same time.
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
        app.addItem(item("Quit Quick Launch", #selector(quit), "q"))

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

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
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

    private var chatWindow: NSWindow? { controller?.chatWindow }
    private var chatIsKey: Bool { chatWindow != nil && NSApp.keyWindow === chatWindow }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(about), #selector(openSettings):
            return true
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
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func find() { controller?.model.openFind() }
    @objc private func toggleChatList() { controller?.model.toggleRail() }
    @objc private func minimize() { chatWindow?.performMiniaturize(nil) }
    @objc private func zoom() { chatWindow?.performZoom(nil) }
    @objc private func close() { chatWindow?.performClose(nil) }
    @objc private func toggleKeepOnTop() { controller?.model.isAlwaysOnTop.toggle() }
}
