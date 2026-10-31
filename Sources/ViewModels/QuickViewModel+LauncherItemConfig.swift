import AppKit
import Foundation
import HouseChatCore
import HouseDesign
import Observation

extension QuickViewModel {
    // MARK: - Hiding items

    /// Stable ids ("kind:itemID") of every row the user hid.
    func hiddenLauncherItemIDs() -> Set<String> {
        Set(settings.launcherItemConfigurations.lazy.filter(\.isHidden).map(\.id))
    }

    func isLauncherItemHidden(_ item: LauncherCatalogItem) -> Bool {
        settings.launcherItemConfiguration(kind: item.kind, itemID: item.itemID)?.isHidden ?? false
    }

    func isApplicationHidden(_ application: LaunchableApplication) -> Bool {
        settings.launcherItemConfiguration(kind: .application, itemID: application.id)?.isHidden ?? false
    }

    /// Drops hidden rows. Ranking and every catalog read through this, so a
    /// hidden row can never come back through an alias, a pin, a learned
    /// abbreviation, or a row cap.
    func visibleLauncherItems(_ items: [LauncherCatalogItem]) -> [LauncherCatalogItem] {
        let hidden = hiddenLauncherItemIDs()
        guard !hidden.isEmpty else { return items }
        return items.filter { !hidden.contains($0.id) }
    }

    /// Hide a row from launcher search and its catalog. Reversible; the
    /// source, alias, hotkey, and pin are untouched, and a direct hotkey
    /// keeps working because it resolves through `catalogItem` unfiltered.
    @discardableResult
    func hideLauncherItem(_ item: LauncherCatalogItem) -> Bool {
        guard item.canBeHidden else { return false }
        updateLauncherItemConfiguration(kind: item.kind, itemID: item.itemID) { configuration in
            configuration.isHidden = true
            configuration.hiddenTitle = LauncherItemHiding.storedTitle(for: item)
        }
        launcherRankingVersion += 1
        applicationSelectionIndex = 0
        if isRecentChatsPresented {
            recentChatsIndex = min(recentChatsIndex, max(recentChatItems.count - 1, 0))
        }
        closeItemActionPane()
        noteInteraction()
        return true
    }

    func hideApplication(_ application: LaunchableApplication) {
        updateApplicationConfiguration(application) { configuration in
            configuration.isHidden = true
            configuration.hiddenTitle = String(application.name.prefix(120))
        }
        launcherRankingVersion += 1
        applicationSelectionIndex = 0
        closeItemActionPane()
        noteInteraction()
    }

    /// Hidden records, in configuration order. Includes records whose item
    /// is missing or uninstalled, which is why the label is stored at hide
    /// time.
    var hiddenLauncherItems: [LauncherItemConfiguration] {
        settings.launcherItemConfigurations.filter(\.isHidden)
    }

    /// Whether the row a hidden record names still exists. The record
    /// outlives an uninstalled app, a pruned clipboard entry, or a deleted
    /// chat, and Settings marks those as unavailable instead of dropping them.
    func hiddenLauncherItemExists(_ configuration: LauncherItemConfiguration) -> Bool {
        switch configuration.kind {
        case .application:
            return applications.contains { $0.id == configuration.itemID }
        case .conversation:
            return history.contains { $0.id.uuidString == configuration.itemID }
        case .clipboard:
            return clipboardEntries.contains { $0.itemID == configuration.itemID }
        case .screenshot:
            return screenshotFiles.contains { $0.itemID == configuration.itemID }
        case .emoji:
            return emojiItems.contains { $0.itemID == configuration.itemID }
        case .answer:
            return false
        case .askAI, .snippet, .quickLink, .command, .folder:
            return catalogItem(kind: configuration.kind, itemID: configuration.itemID) != nil
        }
    }

    /// Bring one hidden row back. A record that carries nothing else is
    /// dropped once it is visible again.
    func restoreHiddenItem(_ configuration: LauncherItemConfiguration) {
        guard let index = settings.launcherItemConfigurations.firstIndex(where: {
            $0.id == configuration.id && $0.isHidden
        }) else { return }
        settings.launcherItemConfigurations[index].isHidden = false
        settings.launcherItemConfigurations[index].hiddenTitle = nil
        if settings.launcherItemConfigurations[index].isEmpty {
            settings.launcherItemConfigurations.remove(at: index)
        }
        persistSettings(settings)
        NotificationCenter.default.post(name: .launcherItemHotkeysChanged, object: nil)
        launcherRankingVersion += 1
        applicationSelectionIndex = 0
    }

    /// Bring every hidden row back, including records whose item is gone.
    func restoreAllHiddenItems() {
        var restored = false
        settings.launcherItemConfigurations = settings.launcherItemConfigurations.compactMap { configuration in
            guard configuration.isHidden else { return configuration }
            restored = true
            var visible = configuration
            visible.isHidden = false
            visible.hiddenTitle = nil
            return visible.isEmpty ? nil : visible
        }
        guard restored else { return }
        persistSettings(settings)
        NotificationCenter.default.post(name: .launcherItemHotkeysChanged, object: nil)
        launcherRankingVersion += 1
        applicationSelectionIndex = 0
    }

    /// Drops the alias, hotkey, and pin of an item that no longer exists.
    func removeLauncherItemConfiguration(for item: LauncherCatalogItem) {
        let before = settings.launcherItemConfigurations.count
        settings.launcherItemConfigurations.removeAll { $0.kind == item.kind && $0.itemID == item.itemID }
        guard settings.launcherItemConfigurations.count != before else { return }
        persistSettings(settings)
        NotificationCenter.default.post(name: .launcherItemHotkeysChanged, object: nil)
    }

    func setLauncherItemHotkey(_ hotkey: ActionHotkey?, for item: LauncherCatalogItem) {
        if item.itemID == "type-to-click.mode" {
            if let hotkey {
                settings.typeToClickHotkey = hotkey
                settings.typeToClickHotkeyEnabled = true
            } else {
                settings.typeToClickHotkeyEnabled = false
            }
            // Remove only a legacy second shortcut created before this
            // command's ⌘K editor was unified. Preserve its alias or pin.
            if let index = settings.launcherItemConfigurations.firstIndex(where: {
                $0.kind == item.kind && $0.itemID == item.itemID
            }) {
                settings.launcherItemConfigurations[index].hotkey = nil
                if settings.launcherItemConfigurations[index].isEmpty {
                    settings.launcherItemConfigurations.remove(at: index)
                }
            }
            persistSettings(settings)
            NotificationCenter.default.post(name: .typeToClickSettingsChanged, object: nil)
            return
        }
        updateLauncherItemConfiguration(kind: item.kind, itemID: item.itemID) { $0.hotkey = hotkey }
        NotificationCenter.default.post(name: .launcherItemHotkeysChanged, object: nil)
    }

    func launcherItemConfigurationConflict(for item: LauncherCatalogItem) -> String? {
        let id = LauncherItemConfiguration(kind: item.kind, itemID: item.itemID).id
        let alias = launcherItemAlias(for: item).trimmingCharacters(in: .whitespacesAndNewlines)
        if !alias.isEmpty, settings.launcherItemConfigurations.contains(where: {
            $0.id != id
                && $0.alias.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare(alias) == .orderedSame
        }) {
            return "This alias is already used by another launcher item."
        }
        if item.itemID == "type-to-click.mode" {
            return settings.typeToClickHotkeyConflict() ?? typeToClickHotkeyRegistrationError
        }
        return settings.launcherItemHotkeyConflict(for: id)
            ?? launcherItemHotkeyRegistrationErrors[id]
    }

    func catalogItem(kind: LauncherItemKind, itemID: String) -> LauncherCatalogItem? {
        if kind == .askAI { return askAIItem(query: "") }
        if kind == .folder { return folderItems.first { $0.itemID == itemID } }
        return (configurableCatalogItems + clipboardEntries + systemCommands).first {
            $0.kind == kind && $0.itemID == itemID
        }
    }

    func updateLauncherItemConfiguration(
        kind: LauncherItemKind,
        itemID: String,
        mutation: (inout LauncherItemConfiguration) -> Void
    ) {
        if let index = settings.launcherItemConfigurations.firstIndex(where: {
            $0.kind == kind && $0.itemID == itemID
        }) {
            mutation(&settings.launcherItemConfigurations[index])
            if settings.launcherItemConfigurations[index].isEmpty {
                settings.launcherItemConfigurations.remove(at: index)
            }
        } else {
            var configuration = LauncherItemConfiguration(kind: kind, itemID: itemID)
            mutation(&configuration)
            if !configuration.isEmpty {
                settings.launcherItemConfigurations.append(configuration)
            }
        }
        persistSettings(settings)
    }

    func applicationAlias(for application: LaunchableApplication) -> String {
        settings.launcherItemConfiguration(
            kind: .application,
            itemID: application.id
        )?.alias ?? ""
    }

    func applicationHotkey(for application: LaunchableApplication) -> ActionHotkey? {
        settings.launcherItemConfiguration(
            kind: .application,
            itemID: application.id
        )?.hotkey
    }

    func setApplicationAlias(_ alias: String, for application: LaunchableApplication) {
        updateApplicationConfiguration(application) { $0.alias = alias }
    }

    func setApplicationHotkey(
        _ hotkey: ActionHotkey?,
        for application: LaunchableApplication
    ) {
        updateApplicationConfiguration(application) { $0.hotkey = hotkey }
        NotificationCenter.default.post(name: .launcherItemHotkeysChanged, object: nil)
    }

    func applicationConfigurationConflict(
        for application: LaunchableApplication
    ) -> String? {
        let alias = applicationAlias(for: application)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !alias.isEmpty,
           settings.launcherItemConfigurations.contains(where: {
               $0.id != LauncherItemConfiguration(kind: .application, itemID: application.id).id
                   && $0.alias.trimmingCharacters(in: .whitespacesAndNewlines)
                       .localizedCaseInsensitiveCompare(alias) == .orderedSame
           }) {
            return "This alias is already used by another launcher item."
        }
        let id = LauncherItemConfiguration(
            kind: .application,
            itemID: application.id
        ).id
        return settings.launcherItemHotkeyConflict(for: id)
            ?? launcherItemHotkeyRegistrationErrors[id]
    }

    private func updateApplicationConfiguration(
        _ application: LaunchableApplication,
        mutation: (inout LauncherItemConfiguration) -> Void
    ) {
        if let index = settings.launcherItemConfigurations.firstIndex(where: {
            $0.kind == .application && $0.itemID == application.id
        }) {
            mutation(&settings.launcherItemConfigurations[index])
            if settings.launcherItemConfigurations[index].isEmpty {
                settings.launcherItemConfigurations.remove(at: index)
            }
        } else {
            var configuration = LauncherItemConfiguration(
                kind: .application,
                itemID: application.id
            )
            mutation(&configuration)
            if !configuration.isEmpty {
                settings.launcherItemConfigurations.append(configuration)
            }
        }
        persistSettings(settings)
    }
}
