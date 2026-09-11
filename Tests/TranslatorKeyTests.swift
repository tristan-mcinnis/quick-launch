// TranslatorKeyTests: the Translator window's key table (v1.5.0 group G4).
//
// ⌘P opens Recent Chats in Quick AI and the chat list in AI Chat, so the
// Translator gave it up: its target language is ⌘T. These tests pin the
// table, check ⌘T against every other key table, and hold the footer, the
// chip tooltip and the placeholder to the keys that actually work. The last
// test writes g4-translator-*.png proofs in both appearances.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Translator keys", .serialized)
@MainActor
struct TranslatorKeyTests {
    // Key codes: Return 36, keypad Enter 76, S 1, T 17, P 35, V 9, W 13.

    @Test func theTargetLanguageIsCommandTAndCommandPDoesNothing() {
        #expect(TranslatorKey.target.shortcut == .command("t"))
        #expect(TranslatorKey.target.shortcut.keyCaps == ["⌘", "T"])
        #expect(TranslatorKey.matching(characters: "t", keyCode: 17, modifiers: [.command]) == .target)
        #expect(TranslatorKey.matching(characters: "T", keyCode: 17, modifiers: [.command, .capsLock]) == .target)

        // ⌘P reaches nothing here, and the table never holds the chat-list key.
        #expect(TranslatorKey.matching(characters: "p", keyCode: 35, modifiers: [.command]) == nil)
        let table = TranslatorKey.allCases.map(\.shortcut)
        #expect(!table.contains(QuickViewModel.recentChatsShortcut))
        #expect(!table.contains(.command("p")))
        // ⇧⌘T is the global Translator hotkey, not a key inside the window.
        #expect(TranslatorKey.matching(characters: "t", keyCode: 17, modifiers: [.command, .shift]) == nil)
    }

    @Test func everyKeyInTheTableStillDoesWhatItDid() {
        #expect(TranslatorKey.matching(characters: "\r", keyCode: 36, modifiers: [.command]) == .copy)
        #expect(TranslatorKey.matching(characters: "\u{3}", keyCode: 76, modifiers: [.command]) == .copy)
        #expect(TranslatorKey.matching(characters: "\r", keyCode: 36, modifiers: [.command, .shift]) == .pasteBack)
        #expect(TranslatorKey.matching(characters: "s", keyCode: 1, modifiers: [.command]) == .swap)
        #expect(TranslatorKey.matching(characters: "V", keyCode: 9, modifiers: [.command, .shift]) == .useClipboard)
        #expect(TranslatorKey.matching(characters: "w", keyCode: 13, modifiers: [.command]) == .close)
        // Plain keys type into the source; they are never shortcuts.
        #expect(TranslatorKey.matching(characters: "t", keyCode: 17, modifiers: []) == nil)
        #expect(TranslatorKey.matching(characters: "\r", keyCode: 36, modifiers: []) == nil)
        #expect(TranslatorKey.matching(characters: "v", keyCode: 9, modifiers: [.command]) == nil, "⌘V stays paste")

        let caps = TranslatorKey.allCases.map(\.shortcut.keyCaps)
        #expect(Set(caps).count == TranslatorKey.allCases.count, "no two keys alike")
    }

    /// ⌘T was checked against every key table: the answer actions, the
    /// overlay's own keys, the Quick AI and AI Chat keys, the ⌘K row actions
    /// of every kind, the AI Chat palette, and the default global hotkeys.
    @Test func commandTIsFreeInEveryOtherKeyTable() {
        let target = TranslatorKey.target.shortcut
        let kinds: [LauncherItemKind] = [
            .snippet, .quickLink, .clipboard, .command, .emoji, .screenshot,
            .conversation, .askAI, .folder, .answer, .screenHistory, .color,
        ]
        var results: [LauncherSearchResult] = kinds.map { kind in
            .item(LauncherCatalogItem(
                kind: kind,
                itemID: kind == .color ? "#FF0000" : "item",
                title: "Item",
                detail: "",
                value: "https://example.com/?utm_source=proof",
                keywords: "has-local-file"
            ))
        }
        results.append(.catalog(.chats, count: 1))
        let app = LaunchableApplication(
            name: "Notes",
            bundleIdentifier: "com.apple.Notes",
            url: URL(fileURLWithPath: "/Applications/Notes.app")
        )
        results.append(.application(app))
        var otherKeys = results.flatMap {
            ItemActionCatalog.actions(for: $0, pasteTarget: nil).compactMap(\.shortcut)
        }
        otherKeys += ItemActionCatalog.actions(for: .application(app), pasteTarget: nil, isRunning: true)
            .compactMap(\.shortcut)
        otherKeys += ResultAction.allCases.map(\.shortcut)
        otherKeys += QuickAISurfaceAction.allCases.compactMap(\.shortcut)
        otherKeys += [
            QuickViewModel.recentChatsShortcut,
            QuickViewModel.transformChooserShortcut,
            QuickViewModel.transcriptCollapseShortcut,
            AIChatWindowModel.chatListShortcut,
            AIChatWindowModel.findShortcut,
            AIChatWindowModel.findNextShortcut,
            AIChatWindowModel.findPreviousShortcut,
        ]
        #expect(!otherKeys.isEmpty)
        #expect(!otherKeys.contains(target), "⌘T is taken elsewhere")

        // Global hotkeys are key codes: T is 17, ⌘ alone is 1_048_576.
        let settings = QuickSettings()
        var globals = [settings.clipboardHistoryHotkey, settings.translatorHotkey, settings.typeToClickHotkey]
        globals += settings.savedPrompts.compactMap(\.hotkey)
        globals += settings.launcherItemConfigurations.compactMap(\.hotkey)
        #expect(!globals.contains(ActionHotkey(keyCode: 17, modifiers: 1_048_576)))
        #expect(!(settings.hotkeyKeyCode == 17 && settings.hotkeyModifiers == 1_048_576))
    }

    @Test func theFooterTheChipAndThePlaceholderNameTheRealKeys() {
        let model = TranslatorModel(lastTarget: .simplifiedChinese)
        #expect(model.footerContext == "Translator")
        #expect(model.footerHints == [
            QuickViewModel.FooterHint(label: "Copy", keys: ["⌘", "↩"]),
            QuickViewModel.FooterHint(label: "Paste back", keys: ["⇧", "⌘", "↩"]),
            QuickViewModel.FooterHint(label: "Swap", keys: ["⌘", "S"]),
            QuickViewModel.FooterHint(label: "Target", keys: ["⌘", "T"]),
            QuickViewModel.FooterHint(label: "Close", keys: ["esc"]),
        ])
        #expect(!model.footerHints.contains { $0.keys == ["⌘", "P"] })
        // The hint is built from the table, so a rebind renames it.
        #expect(model.footerHints.first { $0.label == "Target" }?.keys == TranslatorKey.target.shortcut.keyCaps)

        model.isTargetPickerPresented = true
        #expect(model.footerContext == "Target Language")
        #expect(model.footerHints == [
            QuickViewModel.FooterHint(label: "Choose", keys: ["↩"]),
            QuickViewModel.FooterHint(label: "Back", keys: ["esc"]),
        ])

        #expect(TranslatorKey.targetHelp == "Change target language (⌘T)")
        #expect(TranslatorKey.sourcePlaceholder == "Type or paste text. ⇧⌘V uses the clipboard.")
        #expect(!TranslatorKey.targetHelp.contains("—") && !TranslatorKey.sourcePlaceholder.contains("—"))
    }

    // MARK: - Render proofs

    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    /// The Translator with a translation, then with the target list open, in
    /// dark and light: g4-translator-{panes,picker}-{dark,light}.png.
    @Test func rendersTheTranslatorInBothAppearances() throws {
        let appearances: [(NSAppearance.Name, ColorScheme, String)] = [
            (.darkAqua, .dark, "dark"),
            (.aqua, .light, "light"),
        ]
        for (appearance, scheme, suffix) in appearances {
            let model = TranslatorModel(lastTarget: .simplifiedChinese)
            model.source = "Where is the nearest station?"
            model.translation = "最近的车站在哪里？"
            model.pinyin = "zuì jìn de chē zhàn zài nǎ lǐ?"
            model.detectedSource = .english
            let panes = try Self.render(model, appearance: appearance, scheme: scheme)
            #expect(panes.size == TranslatorView.size)
            try Self.save(panes, name: "g4-translator-panes-\(suffix).png")

            model.isTargetPickerPresented = true
            model.targetQuery = "ch"
            let picker = try Self.render(model, appearance: appearance, scheme: scheme)
            try Self.save(picker, name: "g4-translator-picker-\(suffix).png")
        }
    }

    private static func render(
        _ model: TranslatorModel,
        appearance: NSAppearance.Name,
        scheme: ColorScheme
    ) throws -> NSImage {
        let host = NSHostingView(rootView: TranslatorView(model: model).preferredColorScheme(scheme))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: TranslatorView.size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProofError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func save(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ProofError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    enum ProofError: Error { case noBitmap }
}
