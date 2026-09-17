import AppKit

/// Native editing keys for the floating chat composer. Root search keeps its
/// translation shortcut; a draft keeps its newlines and text-navigation keys.
@MainActor
enum QuickAIComposerEditing {
    static func handle(_ event: NSEvent, editor: NSTextView, model: QuickViewModel) -> Bool {
        guard event.type == .keyDown, editor.isEditable, !editor.hasMarkedText(),
              model.isQuickAIPresented, !model.isAIChatWindow,
              model.inputMode == nil, !model.isRecentChatsPresented,
              !model.isAskQuestionActive, !model.isTransformChooserPresented,
              !model.isModelChooserPresented, !model.isAssistantChooserPresented,
              !model.isAddContextMenuPresented, !model.isActionPalettePresented,
              !model.isItemActionPanePresented, !model.attachmentTray.isStripFocused
        else { return false }
        let modifiers = event.modifierFlags.overlayRelevant
        if VirtualKey.isReturn(keyCode: event.keyCode) {
            if modifiers == [.shift] {
                editor.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            // ⌘↩ always sends; ↩ keeps the empty-composer Paste/Copy rule.
            if modifiers == [.command] {
                model.submitFromComposer()
                return true
            }
            if modifiers.isEmpty {
                model.submitFromComposer()
                return true
            }
        }
        if !model.input.isEmpty,
           let move = ComposerCaretMove(keyCode: event.keyCode, modifiers: modifiers) {
            move.apply(to: editor)
            return true
        }
        return false
    }
}
