import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    // MARK: - Chip selected-text transforms

    /// The compact rewrite actions offered beside the chip. Order and
    /// membership are fixed, so the menu is discoverable and stable; each
    /// entry maps to a saved action by alias, or to the Translator window
    /// (which carries its own target picker rather than hard-coding a
    /// language).
    struct ChipTransformOption: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case saved(UUID)
            case translator
            /// One option of the `{argument}` slot the Transform chooser is
            /// currently filling. The index is into that slot's options.
            case argument(Int)
        }
        let kind: Kind
        let title: String
        let systemImage: String

        var id: String {
            switch kind {
            case .saved(let id): "saved:\(id.uuidString)"
            case .translator: "translator"
            case .argument(let index): "argument:\(index)"
            }
        }
    }

    /// The fixed quick-transform order: alias (or the translator) plus glyph.
    static let chipTransformOrder: [(value: String, image: String)] = [
        ("shorter", "arrow.down.right.and.arrow.up.left"),
        ("bullets", "list.bullet"),
        ("improve", "sparkles"),
        ("tldr", "text.alignleft"),
        ("translate", "character.bubble"),
    ]

    /// The transforms that act on the retained launch selection. Translate
    /// always opens the Translator; the rest resolve to their saved prompt
    /// (so the user's edited name, prompt, and hotkey are honored). Absent
    /// aliases are dropped, so a defunct action simply doesn't appear.
    var chipTransformOptions: [ChipTransformOption] {
        guard selectionTransformSource != nil else { return [] }
        return Self.chipTransformOrder.compactMap { entry in
            if entry.value == "translate" {
                return ChipTransformOption(
                    kind: .translator,
                    title: "Translate",
                    systemImage: entry.image
                )
            }
            guard let action = settings.savedPrompts.first(where: { $0.alias == entry.value }) else {
                return nil
            }
            return ChipTransformOption(
                kind: .saved(action.id),
                title: action.name,
                systemImage: entry.image
            )
        }
    }

    /// Run a transform from the chip menu. Saved actions go through
    /// `performTransform`, which sources from the captured selection snapshot
    /// (not the input field) and previews the result before any write.
    func runChipTransform(_ option: ChipTransformOption) async {
        switch option.kind {
        case .translator:
            openTranslatorWithSelection()
        case .saved(let id):
            guard let action = settings.savedPrompts.first(where: { $0.id == id }) else { return }
            await performTransform(action: action)
        case .argument(let index):
            await chooseTransformArgument(index: index)
        }
    }

    /// Run a quick transform. Always acts on the captured selection snapshot,
    /// never on whatever is typed in the input field, so the rewrite targets
    /// the text the user selected. This is the keyboard-first path for the
    /// Transform chooser and the chip menu.
    func performTransform(action: SavedPrompt) async {
        let label = selectionTransformSourceLabel
        let snapshot = selectionTransformSource
            ?? captureSelectedText(promptForPermission: true)?.text
        guard let snapshot,
              !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            closeActionPalette()
            errorMessage = selectedTextService?.isAccessibilityTrusted == false
                ? "Allow Accessibility in System Settings, then select text and try again."
                : "Select some text first, then run this transform."
            requestInputFocus()
            return
        }
        // One answer at a time: an answer still streaming stops first and
        // keeps what arrived, as Stop does, so the transform never runs a
        // second model request beside it.
        if isStreaming { cancel() }
        isActionPalettePresented = false
        actionQuery = ""
        // A prompt with `{argument …}` slots that offer `options` waits for
        // the chooser; one without collects its defaults and runs at once.
        await beginTransformArguments(action: action, source: snapshot, sourceLabel: label)
    }

    /// The shortcut that opens/closes the keyboard-first Transform chooser.
    /// `⌘⌥T` (Transform). Deliberately not `⌘⇧D` (owned by the panel's
    /// screenshot-display handler) and not `⌘⇧T` (the translator global
    /// hotkey) — those are consumed before `performShortcut` is reached.
    static let transformChooserShortcut: KeyShortcut = .commandOption("t")

    /// A saved transform waiting on its `{argument …}` slots. `values` is
    /// positional, matching `slots`; a slot with `options` is offered as a
    /// chooser through the existing Transform chooser pane, and a slot with
    /// only a `default` is filled silently. Nil when nothing is waiting.
    struct PendingTransformArguments: Equatable, Sendable {
        let actionID: UUID
        let alias: String
        let source: String
        /// The source's label ("Clipboard", or an app name), carried to the
        /// review card so an attached source is never attributed to the live
        /// selection.
        let sourceLabel: String?
        let slots: [SnippetArgument]
        var values: [String]
        /// The slot the option chooser is on, or nil.
        var choosing: Int?
        /// The required free-text slot the composer is filling, or nil. A
        /// `{argument …}` with no `default` and no `options` must be typed:
        /// it is never substituted with an empty string.
        var filling: Int?

        var currentSlot: SnippetArgument? {
            guard let choosing, slots.indices.contains(choosing) else { return nil }
            return slots[choosing]
        }

        var fillingSlot: SnippetArgument? {
            guard let filling, slots.indices.contains(filling) else { return nil }
            return slots[filling]
        }
    }

    /// The original text and the proposed result of a `.reviewChanges`
    /// transform, shown before anything is written back.
    ///
    /// `target` is the captured live-selection context the transform actually
    /// ran on, frozen here and set only when the transformed source was that
    /// exact selection. It is nil for a clipboard or otherwise attached
    /// source, so Accept copies the result instead of writing it into an
    /// unrelated app. Accept then runs the same fail-closed live-selection
    /// check as Replace Selection against this frozen target.
    struct PendingTransformReview {
        let original: String
        let proposed: String
        let sourceApp: String?
        let target: SelectedTextContext?
    }

    func openTransformChooser() {
        // A transform is its own model request; it waits for the answer on
        // screen to end, as Add Context does.
        guard !isStreaming, !chipTransformOptions.isEmpty else { return }
        isTransformChooserPresented = true
        transformChooserIndex = 0
        isAssistantChooserPresented = false
        isCaptureChooserPresented = false
        isActionPalettePresented = false
        isApplicationActionPanePresented = false
        isCatalogActionPanePresented = false
        activeItemActionForm = nil
        requestInputFocus()
    }

    func closeTransformChooser() {
        // Closing while filling an argument must drop the abandoned run, or a
        // later Return on a reopened chooser could send it.
        if pendingTransformArguments != nil {
            cancelTransformArguments()
            return
        }
        isTransformChooserPresented = false
        requestInputFocus()
    }

    func toggleTransformChooser() {
        if isTransformChooserPresented { closeTransformChooser() } else { openTransformChooser() }
    }

    func moveTransformChooserSelection(_ delta: Int) {
        let count = transformChooserOptions.count
        guard count > 0 else { return }
        transformChooserIndex = (transformChooserIndex + delta + count) % count
    }

    func runTransformChooserSelection() async {
        let options = transformChooserOptions
        guard options.indices.contains(transformChooserIndex) else { return }
        // Filling an argument: the highlighted option is the value.
        if pendingTransformArguments != nil {
            await chooseTransformArgument(index: transformChooserIndex)
            return
        }
        isTransformChooserPresented = false
        await runChipTransform(options[transformChooserIndex])
    }

    /// Open the Translator with the retained launch selection available to its
    /// "Use selected text" button, so the import survives the focus moving on.
    func openTranslatorWithSelection() {
        input = ""
        errorMessage = nil
        // Hand the retained selection to the presenter seam *before* any
        // dismissal, because dismissing the overlay clears launch-scoped state
        // (and with it `launchSelection`). The presenter passes it to the
        // Translator so "Use selected text" can import it even after focus
        // moves on.
        let retained = selectionTransformSource
        overlayPresenter.openTranslator(retainedSelection: retained)
    }

    func toggleActionPalette() {
        isApplicationActionPanePresented = false
        contextualApplicationID = nil
        isCatalogActionPanePresented = false
        contextualCatalogItemID = nil
        isActionPalettePresented.toggle()
        actionPaletteSubmenu = nil
        actionQuery = ""
        if !isActionPalettePresented { requestInputFocus() }
    }
}
