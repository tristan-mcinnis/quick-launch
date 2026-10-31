import Foundation
import AppKit
import Observation
import HouseChatCore
import HouseDesign

extension QuickViewModel {
    // MARK: - Footer and badges

    struct FooterHint: Equatable, Sendable {
        let label: String
        let keys: [String]
    }

    /// The footer stays visible while a ⌘K pane floats above it, like
    /// Raycast's bottom bar; hiding it made the window jump on every
    /// pane open and close.
    var showsLauncherFooter: Bool { true }

    /// Left side of the footer: where the user is, or which model answers.
    var footerContext: String {
        if catalogScope == .screenshots, screenshotIndexProgress.isRunning {
            return "Reading text \(screenshotIndexProgress.completed)/\(screenshotIndexProgress.total)"
        }
        switch inputMode {
        case .caffeinateUntil: return "Caffeinate Until"
        case .renameChat: return "Rename Chat"
        case .renameClipboard: return "Rename Entry"
        case .snippetArgument:
            return pendingSnippetInsertion.map { "Snippet · \($0.item.title)" } ?? "Snippet"
        case .houseCommandArgument:
            guard let row = pendingHouseCommandText else { return "Command" }
            return "\(row.manifest.name) · \(row.command.title)"
        case nil: break
        }
        if let pendingQuickLink { return pendingQuickLink.title }
        if let catalogScope { return catalogScope.title }
        if pendingImage != nil { return activeModelDisplay }
        if rootAnswer != nil { return Self.rootAnswerContext }
        if !launcherMatches.isEmpty, !input.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Quick Launch"
        }
        return activeModelDisplay
    }

    /// The footer while an item's form is open. The form is the top layer,
    /// so the footer names the form's own keys, not the row's behind it.
    static func footerHints(forForm form: ItemActionForm) -> [FooterHint] {
        let cancel = FooterHint(label: "Cancel", keys: ["esc"])
        switch form {
        case .edit:
            return [FooterHint(label: "Save", keys: ["⌘", "↩"]), cancel]
        case .alias, .hotkey:
            return [FooterHint(label: "Done", keys: ["⌘", "↩"]), cancel]
        }
    }

    /// Right side of the footer: what Return and the main shortcuts do now.
    var footerHints: [FooterHint] {
        // An open form owns the footer: Paste and Copy act on the row behind
        // it, and neither is what Return does while the editor is up.
        if let activeItemActionForm { return Self.footerHints(forForm: activeItemActionForm) }
        if isStreaming { return [FooterHint(label: "Stop", keys: ["esc"])] }
        if hasPendingAttachment {
            var hints = [
                FooterHint(label: "Ask", keys: ["↩"]),
                FooterHint(label: "Remove", keys: ["⌫"]),
            ]
            // Retake is a screenshot's; a file or a link has nothing to retake.
            if !pendingImages.isEmpty || pendingContext != nil {
                hints.append(FooterHint(
                    label: "Retake",
                    keys: ScreenshotKind.window.overlayKeyCaps(shortcuts)
                ))
            }
            return hints
        }
        if let inputMode {
            switch inputMode {
            case .caffeinateUntil:
                return [
                    FooterHint(label: "Caffeinate", keys: ["↩"]),
                    FooterHint(label: "Back", keys: ["⌫"]),
                ]
            case .renameChat, .renameClipboard:
                return [
                    FooterHint(label: "Save", keys: ["↩"]),
                    FooterHint(label: "Back", keys: ["⌫"]),
                ]
            case .houseCommandArgument:
                return [
                    FooterHint(label: "Run", keys: ["↩"]),
                    FooterHint(label: "Back", keys: ["⌫"]),
                ]
            case .snippetArgument:
                let isLast = pendingSnippetInsertion?.arguments.count
                    == (pendingSnippetInsertion?.collected.count ?? 0) + 1
                return [
                    FooterHint(label: isLast ? "Insert" : "Next", keys: ["↩"]),
                    FooterHint(label: "Back", keys: ["⌫"]),
                ]
            }
        }
        if pendingQuickLink != nil {
            return [
                FooterHint(label: "Open", keys: ["↩"]),
                FooterHint(label: "Back", keys: ["⌫"]),
            ]
        }
        if let rootAnswer {
            // Return does what the inline answer row does.
            return [
                FooterHint(label: Self.answerItem(rootAnswer).defaultActionTitle, keys: ["↩"]),
                FooterHint(label: "Clear", keys: ["esc"]),
            ]
        }
        let matches = launcherMatches
        if !matches.isEmpty {
            let index = min(applicationSelectionIndex, matches.count - 1)
            // Primary key and ⌘K only; Copy, Capture, ⇧↩ and ⌫ still work.
            var hints = [FooterHint(label: primaryActionTitle(for: matches[index]), keys: ["↩"])]
            if case .catalog = matches[index] {
                // Roots have no ⌘K actions.
            } else {
                hints.append(FooterHint(label: "Actions", keys: shortcutKeyCaps(for: .commandPalette)))
            }
            return hints
        }
        if !savedPromptMatches.isEmpty {
            return [
                FooterHint(label: "Complete", keys: ["⇥"]),
                FooterHint(label: "Run", keys: ["↩"]),
            ]
        }
        if catalogScope != nil { return [] }
        return [
            FooterHint(label: input.isEmpty ? "Open" : "Ask", keys: ["↩"]),
            FooterHint(label: "Actions", keys: shortcutKeyCaps(for: .commandPalette)),
        ]
    }

    func primaryActionTitle(for result: LauncherSearchResult) -> String {
        switch result {
        case .application: "Open"
        case .catalog: "Browse"
        case .item(let item): item.defaultActionTitle
        }
    }

    /// The global hotkey bound to a launcher row, for its key-cap badge.
    func hotkey(for result: LauncherSearchResult) -> ActionHotkey? {
        switch result {
        case .application(let application):
            return applicationHotkey(for: application)
        case .catalog(let scope, _):
            return scope == .clipboard ? settings.clipboardHistoryHotkey : nil
        case .item(let item):
            return launcherItemHotkey(for: item)
        }
    }
}
