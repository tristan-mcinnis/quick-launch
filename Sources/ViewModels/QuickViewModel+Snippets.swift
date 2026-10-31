import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    // MARK: - Creating and editing snippets and Quicklinks

    /// "Create Snippet": the ⌘K editor opens on a blank snippet. Nothing is
    /// written until Save.
    func beginCreatingSnippet() {
        beginCreating(kind: .snippet)
    }

    /// "Create Quicklink": the same editor, with an address instead of text.
    func beginCreatingQuicklink() {
        beginCreating(kind: .quickLink)
    }

    private func beginCreating(kind: LauncherItemKind) {
        let isSnippet = kind == .snippet
        let draft = LauncherCatalogItem(
            kind: isSnippet ? .snippet : .quickLink,
            itemID: isSnippet ? Self.draftSnippetID : Self.draftQuickLinkID,
            title: "",
            detail: isSnippet ? "New snippet" : "New Quicklink",
            value: ""
        )
        // A create starts from a clean surface, then lands in the catalog the
        // new item belongs to, so Escape leaves the user among its siblings.
        reset([.layers, .mode, .input])
        draftCatalogItem = draft
        catalogScope = isSnippet ? .snippets : .quickLinks
        openActionPane(for: .item(draft), form: .edit)
        errorMessage = nil
    }

    /// Save in the ⌘K editor. A draft is written to the store as a new item;
    /// anything else is updated in place. The store owns validation, so an
    /// empty name or an address that is not a web link reports its own
    /// message and the form stays open.
    @discardableResult
    func commitItemEdit(_ item: LauncherCatalogItem, title: String, value: String) -> Bool {
        guard let launcherCatalog else {
            errorMessage = LauncherCatalogError.creationUnsupported.localizedDescription
            requestInputFocus()
            return false
        }
        do {
            let saved: LauncherCatalogItem
            if isDraftItem(item) {
                saved = item.kind == .quickLink
                    ? try launcherCatalog.createQuickLink(title: title, value: value)
                    : try launcherCatalog.createSnippet(title: title, value: value)
                draftCatalogItem = nil
            } else if item.kind == .quickLink {
                try launcherCatalog.updateQuickLink(item, title: title, value: value)
                saved = launcherCatalog.quickLinks.first { $0.itemID == item.itemID } ?? item
            } else {
                try launcherCatalog.updateSnippet(item, title: title, value: value)
                saved = launcherCatalog.snippets.first { $0.itemID == item.itemID } ?? item
            }
            errorMessage = nil
            contextualCatalogItemID = saved.id
            activeItemActionForm = nil
            invalidateLauncherRanking()
            noteInteraction()
            return true
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
            return false
        }
    }

    @discardableResult
    func deleteQuickLink(_ item: LauncherCatalogItem) -> Bool {
        do {
            try launcherCatalog?.deleteQuickLink(item)
            removeLauncherItemConfiguration(for: item)
            closeCatalogActionPane()
            applicationSelectionIndex = 0
            errorMessage = nil
            invalidateLauncherRanking()
            noteInteraction()
            return true
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
            return false
        }
    }

    // MARK: - Snippet placeholders

    /// Raycast-style placeholders live inside the snippet's own text, so an
    /// insertion expands them here: `{clipboard}` through the pasteboard
    /// seam, `{date}` and `{time}` from this view model's clock, and
    /// `{argument}` from what the user types when asked. A snippet with no
    /// placeholder takes the same path and comes out unchanged.
    func insertSnippet(
        _ item: LauncherCatalogItem,
        mode: SnippetInsertMode,
        dismissingOverlay: Bool = false
    ) async {
        let slots = SnippetPlaceholders.arguments(in: item.value)
        guard slots.isEmpty else {
            enterInputMode(.snippetArgument)
            pendingSnippetInsertion = PendingSnippetInsertion(
                item: item,
                arguments: slots,
                collected: [],
                mode: mode,
                dismissesOverlay: dismissingOverlay
            )
            return
        }
        await finishSnippetInsertion(
            item,
            arguments: [],
            mode: mode,
            dismissingOverlay: dismissingOverlay
        )
    }

    func finishSnippetInsertion(
        _ item: LauncherCatalogItem,
        arguments: [String],
        mode: SnippetInsertMode,
        dismissingOverlay: Bool
    ) async {
        var expanded = item
        expanded.value = expandSnippet(item.value, arguments: arguments).text
        switch mode {
        case .paste:
            _ = await pasteLauncherItem(expanded)
        case .copy:
            _ = await copyLauncherItem(expanded)
        case .copyAndPaste:
            _ = await copyAndPasteLauncherItem(expanded)
        }
        guard dismissingOverlay else { return }
        input = ""
        overlayPresenter.dismissOverlay()
    }

    /// The pure expansion with this view model's seams filled in: the
    /// clipboard through `PasteboardWriting`, the time through `now`.
    func expandSnippet(_ template: String, arguments: [String] = []) -> SnippetExpansion {
        SnippetPlaceholders.expand(
            template,
            clipboard: pasteboard.readString(),
            now: now(),
            arguments: arguments
        )
    }

    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) -> Bool {
        do {
            try launcherCatalog?.updateSnippet(item, title: title, value: value)
            errorMessage = nil
            contextualCatalogItemID = launcherCatalog?.snippets.first {
                $0.itemID == item.itemID
            }?.id
            activeItemActionForm = nil
            noteInteraction()
            return true
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
            return false
        }
    }

    func deleteSnippet(_ item: LauncherCatalogItem) -> Bool {
        do {
            try launcherCatalog?.deleteSnippet(item)
            removeLauncherItemConfiguration(for: item)
            closeCatalogActionPane()
            applicationSelectionIndex = 0
            errorMessage = nil
            noteInteraction()
            return true
        } catch {
            errorMessage = error.localizedDescription
            requestInputFocus()
            return false
        }
    }
}
