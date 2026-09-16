import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// The in-app shortcut registry: the built-in keys, the overrides and their
/// normalization, the collision rules in both directions, and what a rebind
/// does to the routers, the row actions, the hints, and the AppKit surfaces.
///
/// There is no process-wide table, so nothing here has to reset shared state:
/// a view model's keys come from its own settings and cannot reach another's.
@Suite("Shortcut registry", .serialized)
@MainActor
struct ShortcutRegistryTests {

    // MARK: - Built-in keys

    @Test func everyActionHasAUsableBuiltInKey() {
        for action in ShortcutAction.allCases {
            let hotkey = action.defaultHotkey
            #expect(
                hotkey.isValidShortcut,
                "\(action.rawValue) must include Ctrl, Option, or Cmd"
            )
            // The recorded form and the character form must name the same key,
            // or the footer hint and the recorder would disagree.
            #expect(
                QuickSettings.keyName(for: hotkey.keyCode) == action.defaultShortcut.keyCaps.last,
                "\(action.rawValue): \(QuickSettings.keyName(for: hotkey.keyCode)) vs \(action.defaultShortcut.keyCaps)"
            )
        }
    }

    @Test func theTwoTablesAgreeInBothDirections() {
        for action in ResultAction.allCases {
            let shortcut = ShortcutAction.forResultAction(action)
            #expect(shortcut.resultAction == action, "\(action.rawValue) round trip")
            #expect(shortcut.defaultShortcut == action.defaultShortcut, "\(action.rawValue) default")
        }
        for action in ShortcutAction.allCases where action.resultAction != nil {
            #expect(ShortcutAction.forResultAction(action.resultAction!) == action)
        }
    }

    @Test func builtInKeysAreUniqueWithinAScope() {
        for (index, action) in ShortcutAction.allCases.enumerated() {
            for other in ShortcutAction.allCases.dropFirst(index + 1) {
                guard action.scope.overlaps(other.scope) else { continue }
                #expect(
                    action.defaultHotkey != other.defaultHotkey,
                    "\(action.rawValue) and \(other.rawValue) share \(action.defaultHotkey.displayName)"
                )
            }
        }
    }

    /// Every shipped key is one the app may actually use: not a fixed key,
    /// and not one of the shipped global hotkeys. This is the regression for
    /// Replace Selection, which shipped on `⇧⌘V` while Clipboard History
    /// (a global hotkey, which wins system-wide) was already there.
    @Test func noBuiltInKeyIsFixedOrGlobal() {
        let defaults = QuickSettings()
        let globals: [(String, ActionHotkey)] = [
            ("the main Quick Launch hotkey", ActionHotkey(
                keyCode: defaults.hotkeyKeyCode,
                modifiers: defaults.hotkeyModifiers
            )),
            ("the Clipboard History hotkey", defaults.clipboardHistoryHotkey),
            ("the Translator hotkey", defaults.translatorHotkey),
            ("the Type to Click hotkey", defaults.typeToClickHotkey),
        ] + defaults.savedPrompts.compactMap { prompt in
            prompt.hotkey.map { ("the \(prompt.name) quick action", $0) }
        } + defaults.launcherItemConfigurations.compactMap { configuration in
            configuration.hotkey.map { ("the \(configuration.itemID) launcher hotkey", $0) }
        }

        for action in ShortcutAction.allCases {
            // An action may ship on a launcher row's key (⌘E renames a chat
            // and edits a row), which is why recording the built-in key is a
            // reset. A shared fixed key it may never ship on.
            if let fixed = ReservedShortcut.matching(action.defaultHotkey) {
                #expect(
                    fixed.scope == .launcher,
                    "\(action.rawValue) ships on \(fixed.label), a shared fixed key"
                )
            }
            for (name, hotkey) in globals {
                #expect(
                    action.defaultHotkey != hotkey.normalized,
                    "\(action.rawValue) ships on \(name)"
                )
            }
            // And the app itself accepts every shipped key.
            var settings = QuickSettings()
            #expect(
                settings.setShortcut(action.defaultHotkey, for: action) == nil,
                "\(action.rawValue) cannot even be set to its own built-in key"
            )
        }
    }

    @Test func replaceSelectionMovedOffTheClipboardHotkey() {
        let settings = QuickSettings()
        #expect(ShortcutAction.replaceSelection.defaultHotkey
            == ActionHotkey(keyCode: 9, modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue))
        #expect(ShortcutAction.replaceSelection.defaultShortcut.keyCaps == ["⌥", "⌘", "V"])
        // The global default is untouched: only the in-app key moved.
        #expect(settings.clipboardHistoryHotkey
            == ActionHotkey(keyCode: 9, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue))
        // Nothing else may take the clipboard key either.
        var other = QuickSettings()
        #expect(other.setShortcut(settings.clipboardHistoryHotkey, for: .newChat) != nil)
    }

    /// The menu spells a recorded key as a character. Every default the AI
    /// Chat menu can show has one.
    @Test func theMenuCanSpellAKeyEquivalent() {
        #expect(KeyCodes.menuEquivalent(for: 3) == "f")            // ⌘F, Find in Chat
        #expect(KeyCodes.menuEquivalent(for: 1) == "s")            // ⌃⌘S, the chat list
        #expect(KeyCodes.menuEquivalent(for: 126) == "\u{F700}")   // ↑
        #expect(KeyCodes.menuEquivalent(for: 200) == nil)          // nothing the menu owns
    }

    // MARK: - Persistence and normalization

    @Test func aBlobWithoutOverridesUsesEveryBuiltInKey() throws {
        var object = try jsonObject(of: QuickSettings())
        object.removeValue(forKey: "shortcutOverrides")
        let decoded = try JSONDecoder().decode(
            QuickSettings.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.shortcutOverrides.isEmpty)
        #expect(decoded.shortcuts == .defaults)
        for action in ShortcutAction.allCases {
            #expect(decoded.shortcutHotkey(for: action) == action.defaultHotkey)
        }
    }

    @Test func overridesRoundTripThroughUserDefaults() {
        let name = "ShortcutRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var settings = QuickSettings()
        #expect(settings.setShortcut(ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option])), for: .newChat) == nil)
        settings.save(to: defaults)

        let loaded = QuickSettings.load(from: defaults)
        #expect(loaded.shortcutOverrides["newChat"] == ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option])))
        #expect(loaded.shortcutHotkey(for: .newChat) == ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option])))
        #expect(loaded.shortcutHotkey(for: .openSource) == ShortcutAction.openSource.defaultHotkey)
    }

    @Test func unknownAndUnusableStoredEntriesAreDropped() throws {
        var object = try jsonObject(of: QuickSettings())
        object["shortcutOverrides"] = [
            // Known id, extra modifier noise: kept, normalized.
            "openSource": ["keyCode": 5, "modifiers": modifiers([.command, .capsLock, .function])],
            // Known id, a key that is not a shortcut: dropped.
            "readAloud": ["keyCode": 37, "modifiers": modifiers([.shift])],
            // Known id, the built-in value: dropped, so it stays a default.
            "newChat": ["keyCode": 45, "modifiers": modifiers([.command])],
            // An id this build does not know: dropped.
            "notAnAction": ["keyCode": 1, "modifiers": modifiers([.command])],
        ]
        let decoded = try JSONDecoder().decode(
            QuickSettings.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.shortcutOverrides["openSource"] == ActionHotkey(keyCode: 5, modifiers: modifiers([.command])))
        #expect(decoded.shortcutOverrides["readAloud"] == nil)
        #expect(decoded.shortcutOverrides["newChat"] == nil)
        #expect(decoded.shortcutOverrides["notAnAction"] == nil)
        #expect(decoded.shortcuts.isCustomized(.openSource))
        #expect(!decoded.shortcuts.isCustomized(.newChat))
    }

    @Test func recordingTheBuiltInKeyIsAReset() {
        var settings = QuickSettings()
        settings.setShortcut(ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option])), for: .newChat)
        #expect(settings.isShortcutCustomized(.newChat))
        settings.setShortcut(ShortcutAction.newChat.defaultHotkey, for: .newChat)
        #expect(!settings.isShortcutCustomized(.newChat))
        #expect(settings.shortcutOverrides.isEmpty)
        // And nil is the same reset.
        settings.setShortcut(ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option])), for: .newChat)
        settings.setShortcut(nil, for: .newChat)
        #expect(settings.shortcutHotkey(for: .newChat) == ShortcutAction.newChat.defaultHotkey)
    }

    /// A recorder assignment carries only the device-independent modifier
    /// bits, so fn, caps lock, and the numeric keypad's bit never reach the
    /// stored key or a comparison.
    @Test func modifiersAreNormalizedOnTheWayIn() {
        let noisy = ActionHotkey(keyCode: 40, modifiers: modifiers([.command, .capsLock, .function, .numericPad]))
        #expect(noisy.normalized == ActionHotkey(keyCode: 40, modifiers: modifiers([.command])))
        #expect(noisy.matches(keyCode: 40, modifiers: [.command, .capsLock]))
        #expect(!noisy.matches(keyCode: 40, modifiers: [.command, .shift]))

        // ⌘I is free, so the stored value is the key and nothing else.
        var settings = QuickSettings()
        #expect(settings.setShortcut(
            ActionHotkey(keyCode: 34, modifiers: modifiers([.command, .capsLock, .function])),
            for: .newChat
        ) == nil)
        #expect(settings.shortcutOverrides["newChat"]?.modifiers == modifiers([.command]))
        #expect(settings.shortcutOverrides["newChat"]?.keyCode == 34)
    }

    // MARK: - Collisions

    @Test func aRebindCannotTakeAnotherActionsKey() {
        var settings = QuickSettings()
        let message = settings.setShortcut(
            ShortcutAction.tools.defaultHotkey,   // ⌥⌘K, Tools
            for: .commandPalette
        )
        #expect(message == "This conflicts with Tools.")
        #expect(settings.shortcutOverrides.isEmpty, "a refused rebind writes nothing")
    }

    @Test func aRebindCannotTakeAFixedKey() {
        var settings = QuickSettings()
        #expect(settings.setShortcut(ActionHotkey(keyCode: 8, modifiers: modifiers([.command])), for: .newChat)
            == "That key is fixed: Copy (⌘C), a key used on both surfaces.")
        #expect(settings.setShortcut(ActionHotkey(keyCode: 13, modifiers: modifiers([.command])), for: .newChat)
            == "That key is fixed: Close Window (⌘W), a key used on both surfaces.")
        #expect(settings.setShortcut(ActionHotkey(keyCode: 48, modifiers: modifiers([.command])), for: .newChat)
            == "That key is fixed: Switch apps (⌘⇥), a key used on both surfaces.")
        #expect(settings.shortcutOverrides.isEmpty)
    }

    /// The launcher row's own keys are fixed: a chat action may ship on one
    /// (`⌘E`, `⇧⌘P`, `⌃X`, `⇧⌘A`, `⇧⌘N`, `⇧⌘C`), but no rebind may land on
    /// one and shadow the row.
    @Test func aRebindCannotTakeAFixedLauncherRowKey() {
        let rowKeys: [ActionHotkey] = [
            .init(defaulting: .command("e")),
            .init(defaulting: .commandShift("p")),
            .init(defaulting: .control("x")),
            .init(defaulting: .commandShift("a")),
            .init(defaulting: .commandShift("n")),
            .init(defaulting: .commandShift("c")),
        ]
        for key in rowKeys {
            var settings = QuickSettings()
            let message = settings.setShortcut(key, for: .readAloud)
            #expect(message?.hasPrefix("That key is fixed:") == true, "\(key.displayName) must be reserved")
            #expect(settings.shortcutOverrides.isEmpty)
        }
        // Their own actions still ship on them, which is why recording the
        // built-in key is a reset rather than a rebind.
        for action in [ShortcutAction.renameChat, .pinChat, .deleteChat, .attachMenu, .saveSnippet, .copyAnswer] {
            var settings = QuickSettings()
            #expect(settings.setShortcut(action.defaultHotkey, for: action) == nil, "\(action.rawValue)")
            #expect(!settings.isShortcutCustomized(action))
        }
        // Moving one of them away keeps the row action's key fixed.
        var moved = QuickSettings()
        #expect(moved.setShortcut(ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option])), for: .renameChat) == nil)
        #expect(moved.setShortcut(ShortcutAction.renameChat.defaultHotkey, for: .copyAnswer) != nil)
    }

    @Test func aRebindCannotTakeAGlobalHotkey() {
        var settings = QuickSettings()
        let launcher = ActionHotkey(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        #expect(settings.setShortcut(launcher, for: .newChat)?.contains("main Quick Launch hotkey") == true)
        #expect(settings.setShortcut(settings.translatorHotkey, for: .newChat)?.contains("Translator") == true)
        #expect(settings.setShortcut(settings.typeToClickHotkey, for: .newChat)?.contains("Type to Click") == true)

        // The shipped Clipboard History key is also Replace Selection's old
        // key, so a rebind of something else meets the fixed-row list first.
        // Moving the clipboard key to a free combination names the clipboard.
        settings.clipboardHistoryHotkey = ActionHotkey(keyCode: 34, modifiers: modifiers([.command, .control]))
        #expect(settings.setShortcut(settings.clipboardHistoryHotkey, for: .newChat)
            == "This conflicts with the Clipboard History hotkey.")
    }

    /// The other direction: every global hotkey setter refuses a combination
    /// an in-app shortcut already owns, including the main Quick Launch one,
    /// which had no cross-check at all.
    @Test func everyGlobalSetterRefusesAnInAppCollision() {
        let rename = ShortcutAction.renameChat.defaultHotkey   // ⌘E

        var main = QuickSettings()
        main.hotkeyKeyCode = rename.keyCode
        main.hotkeyModifiers = rename.modifiers
        #expect(main.launcherHotkeyConflict() == "This conflicts with Rename Chat.")

        var clipboard = QuickSettings()
        clipboard.clipboardHistoryHotkey = rename
        #expect(clipboard.clipboardHistoryHotkeyConflict() == "This conflicts with Rename Chat.")

        var translator = QuickSettings()
        translator.translatorHotkey = rename
        #expect(translator.translatorHotkeyConflict() == "This conflicts with Rename Chat.")

        var typeToClick = QuickSettings()
        typeToClick.typeToClickHotkey = rename
        #expect(typeToClick.typeToClickHotkeyConflict() == "This conflicts with Rename Chat.")

        var action = QuickSettings()
        action.savedPrompts[0].hotkey = rename
        #expect(action.actionHotkeyConflict(for: action.savedPrompts[0].id)
            == "This conflicts with Rename Chat.")

        var item = QuickSettings()
        item.launcherItemConfigurations.append(
            LauncherItemConfiguration(kind: .command, itemID: "shortcutTest.command", hotkey: rename)
        )
        #expect(item.launcherItemHotkeyConflict(for: item.launcherItemConfigurations.last!.id)
            == "This conflicts with Rename Chat.")
    }

    /// A rebind made by a recorder with modifier noise is stored normalized,
    /// and the global setters compare against the normalized value.
    @Test func inAppOverridesAreNormalizedWhenComparedToGlobalHotkeys() {
        var settings = QuickSettings()
        #expect(settings.setShortcut(
            ActionHotkey(keyCode: 34, modifiers: modifiers([.command, .capsLock, .function])),
            for: .newChat
        ) == nil)
        settings.translatorHotkey = ActionHotkey(
            keyCode: 34,
            modifiers: modifiers([.command, .numericPad])
        )
        #expect(settings.translatorHotkeyConflict() == "This conflicts with New Chat.")
    }

    @Test func aRebindCannotDropTheModifier() {
        var settings = QuickSettings()
        #expect(settings.setShortcut(ActionHotkey(keyCode: 45, modifiers: 0), for: .newChat)
            == "Must include Ctrl, Option, or Cmd")
        #expect(settings.shortcutOverrides.isEmpty)
    }

    /// The dedicated global hotkeys name the Translator too, in both
    /// directions that were missing it.
    @Test func savedActionAndLauncherItemHotkeysSeeTheTranslator() {
        var settings = QuickSettings()
        settings.savedPrompts[0].hotkey = settings.translatorHotkey
        #expect(settings.actionHotkeyConflict(for: settings.savedPrompts[0].id)
            == "This conflicts with the Translator hotkey.")

        var itemSettings = QuickSettings()
        itemSettings.launcherItemConfigurations.append(
            LauncherItemConfiguration(
                kind: .command,
                itemID: "shortcutTest.command",
                hotkey: itemSettings.translatorHotkey
            )
        )
        let id = itemSettings.launcherItemConfigurations.last!.id
        #expect(itemSettings.launcherItemHotkeyConflict(for: id)
            == "This conflicts with the Translator hotkey.")
    }

    // MARK: - Effective dispatch

    @Test func aRebindMovesTheRouterAndReleasesTheOldKey() {
        let vm = QuickViewModel(settings: QuickSettings())

        // ⌥⌘T runs the Transform chooser by default.
        #expect(vm.performShortcut(characters: "t", keyCode: 17, modifiers: [.command, .option]))

        let replacement = ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option]))  // ⌥⌘J
        #expect(vm.setShortcut(replacement, for: .transformChooser) == nil)

        #expect(vm.shortcuts.matches(.transformChooser, keyCode: 38, modifiers: [.command, .option]))
        #expect(vm.performShortcut(characters: "j", keyCode: 38, modifiers: [.command, .option]))
        #expect(
            !vm.performShortcut(characters: "t", keyCode: 17, modifiers: [.command, .option]),
            "the old key must stop working"
        )
    }

    @Test func theRouterAndTheHintsReadTheSameKey() {
        let vm = QuickViewModel(settings: QuickSettings())

        let replacement = ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option]))  // ⌥⌘J
        #expect(vm.setShortcut(replacement, for: .commandPalette) == nil)

        // The hint, the caps the palette row draws, and the router agree.
        #expect(vm.shortcutKeyCaps(for: .commandPalette) == ["⌥", "⌘", "J"])
        #expect(vm.footerHints.first { $0.label == "Actions" }?.keys == ["⌥", "⌘", "J"])
        #expect(vm.performShortcut(characters: "j", keyCode: 38, modifiers: [.command, .option]))
        #expect(!vm.performShortcut(characters: "k", keyCode: 40, modifiers: [.command]))

        // A `ResultAction` resolves through the same table, and the built-in
        // table is untouched.
        #expect(ResultAction.newChat.defaultShortcut == ShortcutAction.newChat.defaultShortcut)
        #expect(vm.setShortcut(ActionHotkey(keyCode: 11, modifiers: modifiers([.command, .option])), for: .newChat) == nil)
        #expect(vm.shortcutKeyCaps(for: .newChat) == ["⌥", "⌘", "B"])
        #expect(vm.shortcut(for: .newChat) == ResultAction.newChat.shortcut(vm.shortcuts))
        #expect(ResultAction.newChat.defaultShortcut.keyCaps == ["⌘", "N"], "the default is untouched")
    }

    /// A chat row's own actions name the chat keys, so a rebind moves the row
    /// and the key together. The launcher's `Set Alias…` stays on `⇧⌘A` while
    /// Add Context owns the chat surface.
    @Test func theChatRowActionsFollowTheChatKeys() {
        let chat = LauncherCatalogItem(
            kind: .conversation,
            itemID: UUID().uuidString,
            title: "Chat",
            detail: "",
            value: ""
        )
        let snippet = LauncherCatalogItem(kind: .snippet, itemID: "s", title: "Sig", detail: "", value: "x")

        let defaults = ShortcutBindings.defaults
        let plain = ItemActionCatalog.actions(for: .item(chat), pasteTarget: nil, bindings: defaults)
        #expect(plain.first { $0.kind == .edit }?.shortcut == .command("e"))
        #expect(plain.first { $0.kind == .pin }?.shortcut == .commandShift("p"))
        #expect(plain.first { $0.kind == .delete }?.shortcut == .control("x"))
        #expect(plain.first { $0.kind == .openInAIChat }?.shortcut == .command("j"))

        var settings = QuickSettings()
        let renamed = ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option]))   // ⌥⌘J
        let pinned = ActionHotkey(keyCode: 11, modifiers: modifiers([.command, .option]))    // ⌥⌘B
        let deleted = ActionHotkey(keyCode: 15, modifiers: modifiers([.control, .option]))   // ⌃⌥R
        #expect(settings.setShortcut(renamed, for: .renameChat) == nil)
        #expect(settings.setShortcut(pinned, for: .pinChat) == nil)
        #expect(settings.setShortcut(deleted, for: .deleteChat) == nil)
        let bindings = settings.shortcuts

        let moved = ItemActionCatalog.actions(for: .item(chat), pasteTarget: nil, bindings: bindings)
        #expect(moved.first { $0.kind == .edit }?.shortcut == bindings.keyShortcut(for: .renameChat))
        #expect(moved.first { $0.kind == .pin }?.shortcut == bindings.keyShortcut(for: .pinChat))
        #expect(moved.first { $0.kind == .delete }?.shortcut == bindings.keyShortcut(for: .deleteChat))
        #expect(moved.first { $0.kind == .edit }?.shortcut?.keyCaps == ["⌥", "⌘", "J"])

        // A snippet row keeps the launcher's own keys, including Set Alias…
        // on `⇧⌘A`, while the chat's Add Context owns `⇧⌘A` on the chat
        // surface. The two are separate scopes and neither moved.
        let row = ItemActionCatalog.actions(for: .item(snippet), pasteTarget: nil, bindings: bindings)
        #expect(row.first { $0.kind == .setAlias }?.shortcut == .commandShift("a"))
        #expect(row.first { $0.kind == .pin }?.shortcut == .commandShift("p"), "the row's pin did not move")
        #expect(bindings.keyShortcut(for: .attachMenu) == .commandShift("a"))
        #expect(ShortcutAction.attachMenu.scope == .chat)
    }

    @Test func theScreenshotHintAndThePanelTakeTheSameKey() {
        let vm = QuickViewModel(settings: QuickSettings())

        let replacement = ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option]))  // ⌥⌘J
        #expect(vm.setShortcut(replacement, for: .attachWindow) == nil)

        #expect(ScreenshotKind.window.overlayKeyCaps(vm.shortcuts) == ["⌥", "⌘", "J"])
        #expect(vm.footerHints.first { $0.label == "Capture" }?.keys == ["⌥", "⌘", "J"])
        #expect(ScreenshotKind.display.overlayKeyCaps(vm.shortcuts) == ["⇧", "⌘", "D"], "the other kind is untouched")

        // The panel intercepts the capture keys before the model sees them;
        // it has to read the same table. The window key opens the chooser,
        // the display key still captures directly.
        var captures: [ScreenshotKind] = []
        var chooserOpens = 0
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 90),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.bindings = { [weak vm] in vm?.shortcuts ?? .defaults }
        panel.captureChooserHandler = { chooserOpens += 1 }
        panel.screenshotHandler = { captures.append($0) }
        panel.commandKHandler = {}

        _ = panel.performKeyEquivalent(with: keyEvent(characters: "j", keyCode: 38, modifiers: [.command, .option]))
        #expect(chooserOpens == 1)
        #expect(captures.isEmpty)
        _ = panel.performKeyEquivalent(with: keyEvent(characters: "d", keyCode: 2, modifiers: [.command, .shift]))
        #expect(captures == [.display])
        _ = panel.performKeyEquivalent(with: keyEvent(characters: "s", keyCode: 1, modifiers: [.command, .shift]))
        #expect(chooserOpens == 1, "the old key must stop working in the panel too")
        #expect(captures == [.display], "the window key never captures directly")
    }

    /// `⇧⌘S` opens the capture chooser on the chat's router; `⇧⌘D` still
    /// captures the display directly.
    @Test func theChatRouterOpensTheCaptureChooser() async {
        let vm = QuickViewModel(settings: QuickSettings())
        vm.openQuickAI()
        #expect(vm.canOpenAttachments)

        #expect(vm.performShortcut(characters: "s", keyCode: 1, modifiers: [.command, .shift]))
        #expect(vm.isCaptureChooserPresented)
        #expect(vm.topLayer == .captureChooser)
        #expect(vm.errorMessage == nil, "opening the chooser attaches nothing and cannot fail")
        vm.performShortcut(characters: "s", keyCode: 1, modifiers: [.command, .shift])
        #expect(vm.isCaptureChooserPresented, "the window key opens it; it does not toggle")

        let replacement = ActionHotkey(keyCode: 11, modifiers: modifiers([.command, .control]))  // ⌃⌘B
        #expect(vm.setShortcut(replacement, for: .attachDisplay) == nil)
        #expect(vm.performShortcut(characters: "b", keyCode: 11, modifiers: [.command, .control]))
        #expect(await eventually { vm.errorMessage != nil })
        vm.errorMessage = nil
        #expect(!vm.performShortcut(characters: "d", keyCode: 2, modifiers: [.command, .shift]),
                "the old display key must stop working")
    }

    @Test func thePanelTakesTheReboundPaletteKey() {
        let vm = QuickViewModel(settings: QuickSettings())

        var paletteOpens = 0
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 90),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.bindings = { [weak vm] in vm?.shortcuts ?? .defaults }
        panel.commandKHandler = { paletteOpens += 1 }

        _ = panel.performKeyEquivalent(with: keyEvent(characters: "k", keyCode: 40, modifiers: [.command]))
        #expect(paletteOpens == 1)

        #expect(vm.setShortcut(ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option])), for: .commandPalette) == nil)
        _ = panel.performKeyEquivalent(with: keyEvent(characters: "j", keyCode: 38, modifiers: [.command, .option]))
        #expect(paletteOpens == 2)
        _ = panel.performKeyEquivalent(with: keyEvent(characters: "k", keyCode: 40, modifiers: [.command]))
        #expect(paletteOpens == 2, "the old key must stop working in the panel too")
    }

    @Test func theChatWindowTakesTheReboundChatListKey() {
        let vm = QuickViewModel(settings: QuickSettings())
        let defaults = UserDefaults(suiteName: "ShortcutRegistryTests.chat.\(UUID().uuidString)")!
        let model = AIChatWindowModel(chat: vm, defaults: defaults)

        #expect(model.handleKeyEquivalent(characters: "s", keyCode: 1, modifiers: [.command, .control]))
        let wasVisible = model.isRailVisible

        let replacement = ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option]))  // ⌥⌘J
        #expect(vm.setShortcut(replacement, for: .chatList) == nil)

        #expect(model.handleKeyEquivalent(characters: "j", keyCode: 38, modifiers: [.command, .option]))
        #expect(model.isRailVisible != wasVisible)
        #expect(!model.handleKeyEquivalent(characters: "s", keyCode: 1, modifiers: [.command, .control]))
    }

    @Test func theChatMenuIsRebuiltWhenAShortcutChanges() async {
        let vm = QuickViewModel(settings: QuickSettings())
        let name = "ShortcutRegistryTests.menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let model = AIChatWindowModel(chat: vm, defaults: defaults)
        let shell = MenuRefreshRecordingShell()
        let controller = AIChatWindowController(
            model: model,
            app: RecordingPresenter(),
            shell: shell,
            notifier: FakeAnswerNotifier(),
            frameAutosaveName: nil
        )
        // The observer Task is what rebuilds the menu, and it holds the
        // controller weakly, so the caller must keep it alive across the wait.
        #expect(!controller.isVisible)
        #expect(controller.model === model)
        // Let the observer start iterating: a notification posted before it
        // does is not delivered, by design.
        try? await Task.sleep(for: .milliseconds(50))
        // The menu bar is installed once per regular-app session, so a rebind
        // has to re-install it, or the old key equivalent would stay live in
        // the menu while the router already answers the new key.
        #expect(vm.setShortcut(ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option])), for: .chatList) == nil)
        #expect(await eventually { shell.refreshes > 0 })
        // The menu the shell built names the window's resolved key, never a
        // stale one: the same value its router and hints read.
        #expect(vm.shortcuts.keyCaps(for: .chatList) == ["⌥", "⌘", "J"])
        let menu = shell.lastMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Show Chat List")
        #expect(menu?.keyEquivalent == KeyCodes.menuEquivalent(for: 38))
        #expect(menu?.keyEquivalentModifierMask == [.command, .option])
        #expect(menu?.keyEquivalent != KeyCodes.menuEquivalent(for: 1), "the built-in key is gone too")
        #expect(controller.isVisible == false)
    }

    /// `⌘H` is Hide, and the v1.4 Recent Chats alias is gone with it: a rebind
    /// is the one way to move that key now.
    @Test func commandHNoLongerOpensRecentChats() {
        let vm = QuickViewModel(settings: QuickSettings())
        vm.openQuickAI()
        // ⌘H reaches nothing now: no layer opens and no notice is posted.
        #expect(!vm.performShortcut(characters: "h", keyCode: 4, modifiers: [.command]))
        #expect(!vm.isRecentChatsPresented)
        #expect(vm.errorMessage == nil)
        // ⌘P still reaches Recent Chats. With no chat yet it says so, which
        // is the proof the key routed; the list itself needs a chat.
        #expect(vm.performShortcut(characters: "p", keyCode: 35, modifiers: [.command]))
        #expect(vm.errorMessage == "No chats yet. Ask a question first.")
        vm.errorMessage = nil

        // And it is remappable: the old key stops, the new one arrives.
        #expect(vm.setShortcut(ActionHotkey(keyCode: 6, modifiers: modifiers([.command, .control])), for: .recentChats) == nil)
        #expect(!vm.performShortcut(characters: "p", keyCode: 35, modifiers: [.command]))
        #expect(vm.errorMessage == nil)
        #expect(vm.performShortcut(characters: "z", keyCode: 6, modifiers: [.command, .control]))
        #expect(vm.errorMessage == "No chats yet. Ask a question first.")
    }

    /// No process-wide table: one view model's rebind is invisible to another,
    /// and a second store built with defaults cannot change the first's keys.
    @Test func oneViewModelsRebindDoesNotReachAnother() {
        let first = QuickViewModel(settings: QuickSettings())
        let second = QuickViewModel(settings: QuickSettings())
        #expect(first.setShortcut(ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option])), for: .newChat) == nil)

        #expect(first.shortcuts.isCustomized(.newChat))
        #expect(second.shortcuts == .defaults)
        #expect(second.shortcuts.keyCaps(for: .newChat) == ["⌘", "N"])

        // A third store built after the rebind, the way a sibling window's
        // view model is built, changes nothing about the first.
        let third = QuickViewModel(settings: QuickSettings())
        #expect(third.shortcuts == .defaults)
        #expect(first.shortcuts.isCustomized(.newChat))
        #expect(first.shortcutKeyCaps(for: .newChat) == ["⌥", "⌘", "J"])
    }

    @Test func resetAllPutsEveryKeyBack() {
        let vm = QuickViewModel(settings: QuickSettings())
        #expect(vm.setShortcut(ActionHotkey(keyCode: 38, modifiers: modifiers([.command, .option])), for: .newChat) == nil)
        #expect(vm.setShortcut(ActionHotkey(keyCode: 11, modifiers: modifiers([.command, .option])), for: .openSource) == nil)
        #expect(vm.settings.customizedShortcuts.count == 2)

        vm.resetShortcut(.newChat)
        #expect(vm.settings.customizedShortcuts == [.openSource])

        vm.resetAllShortcuts()
        #expect(vm.settings.customizedShortcuts.isEmpty)
        #expect(vm.settings.shortcutOverrides.isEmpty)
        #expect(vm.shortcuts == .defaults)
    }

    // MARK: - The pane

    /// The new pane is last, so `⌘1`…`⌘7` still open the tabs they always did.
    @Test func theKeyboardPaneIsLastSoTheOldTabNumbersHold() {
        #expect(SettingsPane.allCases.last == .keyboard)
        #expect(SettingsPane.allCases.dropLast() == [
            .general, .items, .models, .clipboard, .screenHistory, .prompts, .about,
        ])
        let destination = SettingsDestinationIndex.destination(id: "pane.keyboard")
        #expect(destination?.pane == .keyboard)
        #expect(destination?.title == "Keyboard Shortcuts")
        // And its groups are launcher-reachable, so its settings are findable.
        for id in ["keyboard.actions", "keyboard.fixed", "keyboard.global"] {
            let group = SettingsDestinationIndex.destination(id: id)
            #expect(group?.pane == .keyboard)
            #expect(group.map { SettingsDestinationIndex.launcherItems.contains($0.launcherItem) } == true)
        }
    }

    /// A shortcut always has a key, so its recorder offers no Clear: Reset is
    /// the one affordance, and Clear stays for the optional global hotkeys.
    @Test func theShortcutRecorderOffersNoClearBecauseResetOwnsThat() {
        #expect(!KeyboardShortcutsSettingsView.recorderAllowsClear)
        #expect(ActionHotkeyRecorderView(hotkey: .constant(nil)).allowsClear, "a global hotkey can be unbound")
    }

    // MARK: - Helpers

    private func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt { flags.rawValue }

    private func jsonObject(of settings: QuickSettings) throws -> [String: Any] {
        let data = try JSONEncoder().encode(settings)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func keyEvent(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }
}

/// An app shell that keeps the menu `present` and `refreshMenu` build, so a
/// test can read the key equivalents without a window server.
@MainActor
private final class MenuRefreshRecordingShell: AIChatAppShell {
    var refreshes = 0
    var lastMenu: NSMenu?

    func present(_ window: NSWindow, menu: () -> NSMenu) {
        lastMenu = menu()
    }

    func refreshMenu(_ menu: () -> NSMenu) {
        refreshes += 1
        lastMenu = menu()
    }

    func windowWillClose(_ window: NSWindow) {}

    func isOnScreen(_ window: NSWindow) -> Bool { false }
}

/// Waits for a main-actor condition, yielding to the main actor between
/// checks so a pending Task can run.
@MainActor
private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
