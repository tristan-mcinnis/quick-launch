import AppKit
import Testing
@testable import QuickLaunch

/// The Edit keys reach a field in every window that has no Edit menu: the
/// launcher (a Quicklink or snippet editor), Settings, and the Translator.
/// A recording responder stands in for the field, so no test touches the
/// real pasteboard.
@MainActor
@Suite("Standard Edit keys")
struct StandardEditKeysTests {
    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }

    private static let editKeys: [(String, UInt16, NSEvent.ModifierFlags, String)] = [
        ("v", 9, [.command], "paste:"),
        ("z", 6, [.command], "undo:"),
        ("z", 6, [.command, .shift], "redo:"),
        ("x", 7, [.command], "cut:"),
        ("c", 8, [.command], "copy:"),
        ("a", 0, [.command], "selectAll:"),
    ]

    private func check(_ panel: NSPanel) throws {
        let field = RecordingField(frame: .zero)
        panel.contentView = field
        #expect(panel.makeFirstResponder(field))
        for (characters, code, modifiers, selector) in Self.editKeys {
            #expect(panel.performKeyEquivalent(with: try key(characters, code: code, modifiers: modifiers)))
            #expect(field.actions.last == selector, "\(selector) did not reach the field")
        }
        #expect(field.actions.count == Self.editKeys.count)
    }

    @Test func launcherPanelDeliversEveryEditKey() throws {
        try check(KeyablePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false))
    }

    @Test func settingsPanelDeliversEveryEditKey() throws {
        try check(StandardEditingPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false))
    }

    @Test func translatorPanelDeliversEveryEditKey() throws {
        try check(TranslatorPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false))
    }

    /// The menu would refuse Cut on a read-only answer, so the key goes
    /// unhandled and the answer is never cut.
    @Test func aReadOnlyTextViewRefusesCut() throws {
        for panel: NSPanel in [
            StandardEditingPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false),
            TranslatorPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false),
        ] {
            let answer = CutCountingTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            answer.string = "an answer"
            answer.isEditable = false
            answer.setSelectedRange(NSRange(location: 0, length: 2))
            panel.contentView = answer
            #expect(panel.makeFirstResponder(answer))
            let event = try key("x", code: 7, modifiers: [.command])
            #expect(!panel.performKeyEquivalent(with: event))
            #expect(answer.cutCount == 0)
        }
    }

    @Test func otherKeysAreNotEditActions() throws {
        #expect(StandardEditKeys.action(for: try key("v", code: 9, modifiers: [.command, .option])) == nil)
        #expect(StandardEditKeys.action(for: try key("v", code: 9, modifiers: [.control, .command])) == nil)
        #expect(StandardEditKeys.action(for: try key("v", code: 9, modifiers: [])) == nil)
        #expect(StandardEditKeys.action(for: try key("k", code: 40, modifiers: [.command])) == nil)
    }
}

/// A first responder that records the Edit actions it receives.
private final class RecordingField: NSView {
    var actions: [String] = []
    override var acceptsFirstResponder: Bool { true }

    @objc func cut(_ sender: Any?) { actions.append("cut:") }
    @objc func copy(_ sender: Any?) { actions.append("copy:") }
    @objc func paste(_ sender: Any?) { actions.append("paste:") }
    @objc override func selectAll(_ sender: Any?) { actions.append("selectAll:") }
    @objc func undo(_ sender: Any?) { actions.append("undo:") }
    @objc func redo(_ sender: Any?) { actions.append("redo:") }
}

/// A text view that counts Cut, so a refused Cut can be seen.
private final class CutCountingTextView: NSTextView {
    var cutCount = 0
    override func cut(_ sender: Any?) { cutCount += 1 }
}
