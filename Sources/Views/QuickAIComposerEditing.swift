import AppKit

/// Native editing keys for the floating chat composer. Root search keeps its
/// translation shortcut; a draft keeps its newlines and text-navigation keys.
@MainActor
enum QuickAIComposerEditing {
    static let spaceKeyCode: UInt16 = 49
    static let zKeyCode: UInt16 = 6

    static func handle(_ event: NSEvent, editor: NSTextView, model: QuickViewModel) -> Bool {
        guard event.type == .keyDown, editor.isEditable, !editor.hasMarkedText(),
              model.isQuickAIPresented, !model.isAIChatWindow,
              model.inputMode == nil, !model.isRecentChatsPresented,
              !model.isTransformChooserPresented,
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
            // While a proposed task waits for ↩, ⌘↩ on the empty field is
            // the answer's own action, so Paste never adds a task.
            if modifiers == [.command] {
                if model.input.isEmpty, model.pendingAction != nil {
                    Task { await model.runPrimaryAnswerAction(skippingProposal: true) }
                } else {
                    model.submitFromComposer()
                }
                return true
            }
            if modifiers.isEmpty {
                model.submitFromComposer()
                return true
            }
        }
        // ⌘Z on an empty field with nothing of the field's own to undo puts
        // the newest change back (a reschedule, a done, a moved event).
        if event.keyCode == Self.zKeyCode, modifiers == [.command], model.input.isEmpty,
           editor.undoManager?.canUndo != true, model.undoableChange != nil {
            Task { await model.undoLastChange() }
            return true
        }
        // Space on an empty field pages the thread down, ⇧Space up, so a
        // long answer reads without the mouse. Typed text keeps its spaces,
        // and an input method's marked text never gets here.
        if event.keyCode == Self.spaceKeyCode, model.input.isEmpty,
           modifiers.isEmpty || modifiers == [.shift] {
            return model.handleThreadKey(modifiers.isEmpty ? .pageDown : .pageUp, command: false, option: false)
        }
        if !model.input.isEmpty,
           let move = ComposerCaretMove(keyCode: event.keyCode, modifiers: modifiers) {
            move.apply(to: editor)
            return true
        }
        return false
    }
}
