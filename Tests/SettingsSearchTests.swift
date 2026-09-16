import Testing
import Foundation
import AppKit
import SwiftUI
@testable import QuickLaunch

/// The shared Settings search index, the launcher rows it feeds, the
/// Caffeinate preference controls, and the launch-time update check.
@MainActor
@Suite("Settings search and destinations", .serialized)
struct SettingsSearchTests {

    // MARK: - The shared index

    @Test func everyDestinationIsUniqueAndAddressesARealPane() {
        let all = SettingsDestinationIndex.all
        #expect(!all.isEmpty)
        #expect(Set(all.map(\.id)).count == all.count, "destination ids must be unique")

        // Every pane has a pane-level row, so searching a tab's own name lands
        // on that tab.
        for pane in SettingsPane.allCases {
            #expect(all.contains { $0.id == "pane.\(pane.rawValue)" && $0.pane == pane })
        }

        // A group destination must carry an anchor; only the pane rows are
        // allowed to point at the pane as a whole.
        for destination in all where !destination.id.hasPrefix("pane.") {
            #expect(!destination.anchor.isEmpty, "\(destination.id) must name a group anchor")
        }
    }

    @Test func launcherItemsAreGroupLevelOnly() {
        let items = SettingsDestinationIndex.launcherItems
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.value.hasPrefix(SettingsDestination.valuePrefix) })
        // Bare-pane rows stay in the sidebar; the launcher always lands on a
        // named group.
        #expect(!items.contains { $0.value.contains("settings.destination.pane.") })
    }

    @Test func synonymsFindTheSettingTheyName() {
        func firstID(_ query: String) -> String? {
            SettingsDestinationIndex.matching(query).first?.id
        }

        #expect(firstID("battery cutoff") == "general.caffeinate.battery")
        #expect(firstID("agent watch") == "general.caffeinate.agentWatch")
        #expect(firstID("keep display awake") == "general.caffeinate.display")
        #expect(firstID("check for updates") == "about.updates")
        #expect(firstID("quicklinks") == "clipboard.quicklinks")
        #expect(firstID("interaction journal") == "general.learning")

        #expect(SettingsDestinationIndex.matching("caffeinate").contains { $0.id == "general.caffeinate" })
        #expect(SettingsDestinationIndex.matching("appearance").contains { $0.id == "general.appearance" })
        #expect(SettingsDestinationIndex.matching("zzzzzzz").isEmpty)
        #expect(SettingsDestinationIndex.matching("   ").isEmpty, "a blank query searches nothing")
    }

    @Test func everyDeclaredAnchorResolvesInTheViews() throws {
        // The index and the views must not drift: every declared group anchor
        // must have a matching `.settingsAnchor(...)` somewhere in Sources/Views.
        var root = URL(fileURLWithPath: #filePath)
        root.deleteLastPathComponent()
        root.deleteLastPathComponent()
        let viewsDir = root.appendingPathComponent("Sources/Views")
        let files = try FileManager.default.contentsOfDirectory(
            at: viewsDir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        var source = ""
        for file in files {
            source += try String(contentsOf: file, encoding: .utf8)
        }
        for destination in SettingsDestinationIndex.all where !destination.id.hasPrefix("pane.") {
            #expect(
                source.contains("settingsAnchor(\"\(destination.anchor)\""),
                "no view applies .settingsAnchor(\"\(destination.anchor)\") for \(destination.id)"
            )
        }
    }

    @Test func everyPaneRendersWithAnInitialDestination() {
        for pane in SettingsPane.allCases {
            // A group row when the pane has one, so the anchor and scroll path
            // is exercised; the pane row otherwise.
            let destination = SettingsDestinationIndex.all.first {
                $0.pane == pane && !$0.id.hasPrefix("pane.")
            } ?? SettingsDestination(
                id: "pane.\(pane.rawValue)",
                pane: pane,
                anchor: "",
                title: pane.title,
                detail: "Settings",
                synonyms: []
            )
            let vm = QuickViewModel()
            let view = SettingsView(viewModel: vm, initialDestination: destination)
            // The destination actually landed, not just that a frame was drawn.
            #expect(view.revealedDestinationForTesting?.pane == pane)
            #expect(view.revealedDestinationForTesting?.anchor == destination.anchor)

            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: SettingsView.windowSize)
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.width == SettingsView.windowSize.width)
        }
    }

    // MARK: - Launcher root search

    @Test func launcherRootSearchFindsASettingAndOpensIt() async throws {
        let vm = QuickViewModel()
        vm.persistSettings = { _ in }
        let presenter = RecordingSettingsPresenter()
        vm.overlayPresenter = presenter

        vm.input = "battery cutoff"
        let item = try #require(
            vm.launcherMatches.compactMap { result -> LauncherCatalogItem? in
                guard case .item(let item) = result else { return nil }
                return item
            }.first { $0.value.hasPrefix(SettingsDestination.valuePrefix) }
        )
        #expect(item.value == "settings.destination.general.caffeinate.battery")

        await vm.performLauncherItem(item)

        #expect(presenter.revealedDestination?.id == "general.caffeinate.battery")
        #expect(presenter.revealedDestination?.pane == .general)
        #expect(presenter.revealedDestination?.anchor == "general.caffeinate.battery")
    }

    @Test func genericOpenSettingsIsStillOffered() {
        let vm = QuickViewModel()
        vm.input = "settings"
        #expect(vm.launcherMatches.contains {
            guard case .item(let item) = $0 else { return false }
            return item.itemID == "settings.open"
        })
    }

    // MARK: - Caffeinate controls

    @Test func caffeinateRowNamesTheActionFromTheEffectiveState() {
        let manager = RecordingCaffeinateManager()
        let vm = QuickViewModel(caffeinateManager: manager)
        vm.persistSettings = { _ in }

        #expect(vm.caffeinateStatusRow.title == "Caffeinate")
        #expect(vm.caffeinateStatusRow.caffeinateIsActive == false)

        #expect(vm.setCaffeinateEnabled(true))
        #expect(vm.caffeinateStatusRow.title == "Decaffeinate")
        #expect(vm.caffeinateStatusRow.caffeinateIsActive == true)

        // A timed session leaves the stored master switch off but is still the
        // manager's effective awake state, so the word must be Decaffeinate.
        vm.setCaffeinateEnabled(false)
        manager.enable(for: 600)
        vm.syncCaffeinateState()
        #expect(!vm.settings.caffeinateEnabled)
        #expect(vm.isCaffeinating)
        #expect(vm.caffeinateStatusRow.title == "Decaffeinate")
    }

    @Test func caffeinateActionPaletteOffersOnlyTheOppositeWord() {
        let inactive = LauncherCatalogItem(
            kind: .command,
            itemID: "caffeinate.toggle",
            title: "Caffeinate",
            detail: "",
            value: "caffeinate.toggle",
            keywords: "",
            statusLight: .off
        )
        let active = LauncherCatalogItem(
            kind: .command,
            itemID: "caffeinate.toggle",
            title: "Decaffeinate",
            detail: "",
            value: "caffeinate.toggle",
            keywords: "",
            statusLight: .on
        )

        let off = ItemActionCatalog.actions(for: .item(inactive), pasteTarget: nil)
        #expect(off.filter { $0.kind == .primary }.map(\.title) == ["Caffeinate"])
        #expect(!off.contains { $0.title == "Decaffeinate" })

        let on = ItemActionCatalog.actions(for: .item(active), pasteTarget: nil)
        #expect(on.filter { $0.kind == .primary }.map(\.title) == ["Decaffeinate"])
        #expect(!on.contains { $0.title == "Caffeinate" }, "no Caffeinate action while active")
    }

    @Test func pausedSessionNamesTheRowDecaffeinateAndCancels() {
        let manager = RecordingCaffeinateManager()
        let vm = QuickViewModel(caffeinateManager: manager)
        vm.persistSettings = { _ in }

        // A live timed session the battery has paused: the assertion is
        // released, the session is not.
        manager.isEnabled = false
        manager.hasLiveSession = true
        manager.pauseDetail = "Paused at 15% battery. Decaffeinate to cancel."
        vm.syncCaffeinateState()

        #expect(vm.hasCaffeinateSession)
        #expect(!vm.isCaffeinating)
        #expect(vm.caffeinateStatusRow.title == "Decaffeinate")
        #expect(vm.caffeinateStatusRow.statusLight == .paused)
        #expect(vm.caffeinateStatusRow.detail.contains("Paused at 15%"))
        #expect(vm.caffeinateStatusRow.caffeinateIsActive == true)

        // Return on the row cancels the session instead of re-enabling.
        vm.performSystemCommand(vm.caffeinateStatusRow)
        #expect(manager.setEnabledCalls.last == false)
        #expect(!manager.hasLiveSession)
        #expect(!vm.hasCaffeinateSession)
        #expect(!vm.settings.caffeinateEnabled)
    }

    @Test func startingATimerWhilePausedPersistsTheIntendedDeadline() async {
        let manager = RecordingCaffeinateManager()
        manager.paused = true
        let vm = QuickViewModel(caffeinateManager: manager)
        vm.persistSettings = { _ in }
        vm.syncCaffeinateState()

        // A preset: the deadline is persisted even though `endsAt` is nil.
        let oneHour = vm.caffeinateItems.first { $0.value == "caffeinate.60" }!
        vm.performSystemCommand(oneHour)
        #expect(vm.errorMessage == nil, "a paused timer is a started session, not a failure")
        #expect(!vm.settings.caffeinateEnabled)
        #expect(vm.settings.caffeinateUntil == manager.sessionDeadline)
        #expect(vm.settings.caffeinateUntil != nil)
        #expect(vm.hasCaffeinateSession)
        #expect(!vm.isCaffeinating)

        // An explicit time, through the input mode.
        vm.enterInputMode(.caffeinateUntil)
        vm.input = "90m"
        _ = await vm.submitInputMode()
        #expect(vm.errorMessage == nil)
        #expect(vm.settings.caffeinateUntil == manager.sessionDeadline)
        #expect(vm.settings.caffeinateUntil != nil)
    }

    @Test func caffeinateActionPaletteNamesPausedAsDecaffeinate() {
        let paused = LauncherCatalogItem(
            kind: .command,
            itemID: "caffeinate.toggle",
            title: "Decaffeinate",
            detail: "",
            value: "caffeinate.toggle",
            keywords: "",
            statusLight: .paused
        )
        let actions = ItemActionCatalog.actions(for: .item(paused), pasteTarget: nil)
        #expect(actions.filter { $0.kind == .primary }.map(\.title) == ["Decaffeinate"])
        #expect(!actions.contains { $0.title == "Caffeinate" })
    }

    @Test func caffeinateRowIsFindableInBothStates() {
        let manager = RecordingCaffeinateManager()
        let vm = QuickViewModel(caffeinateManager: manager)
        vm.persistSettings = { _ in }

        vm.input = "caffeinate"
        #expect(vm.launcherMatches.contains { $0.id == "command:caffeinate.toggle" })

        vm.setCaffeinateEnabled(true)
        vm.input = ""
        vm.input = "decaffeinate"
        #expect(vm.launcherMatches.contains { $0.id == "command:caffeinate.toggle" })
        vm.input = ""
        vm.input = "caffeinate"
        #expect(vm.launcherMatches.contains { $0.id == "command:caffeinate.toggle" })
    }

    @Test func setCaffeinateEnabledReportsAndDoesNotPersistAFailedAssertion() {
        let manager = RecordingCaffeinateManager()
        manager.refusesEnable = true
        let vm = QuickViewModel(caffeinateManager: manager)
        var persisted: [QuickSettings] = []
        vm.persistSettings = { persisted.append($0) }
        // The preference defaults on, so start from a known off state: a
        // refused enable must leave it exactly where it was.
        vm.settings.caffeinateEnabled = false

        #expect(vm.setCaffeinateEnabled(true) == false)
        #expect(!vm.settings.caffeinateEnabled, "a refused assertion is not written as intent")
        #expect(!manager.isEnabled)
        #expect(persisted.isEmpty)
    }

    @Test func caffeinateStatusSummaryComesFromTheManager() {
        let manager = RecordingCaffeinateManager()
        manager.statusSummary = "Paused at 18% battery. Normal Mac sleep is enabled until you plug in."
        let vm = QuickViewModel(caffeinateManager: manager)
        vm.persistSettings = { _ in }
        // The battery pause releases the assertion, so `isCaffeinating` is
        // false while the intent is still live; the manager's line is the
        // only honest source and it is what the card shows.
        #expect(!vm.isCaffeinating)
        #expect(vm.caffeinateStatusSummary.contains("Paused at 18%"))
    }

    @Test func masterSwitchDrivesTheManagerAndClearsTheTimedSessionOnEnable() {
        let manager = RecordingCaffeinateManager()
        let vm = QuickViewModel(caffeinateManager: manager)
        vm.persistSettings = { _ in }

        vm.setCaffeinateEnabled(true)
        #expect(manager.isEnabled)
        #expect(vm.settings.caffeinateEnabled)
        #expect(vm.settings.caffeinateUntil == nil)
        #expect(vm.isCaffeinating)

        vm.settings.caffeinateUntil = Date().addingTimeInterval(600)
        vm.setCaffeinateEnabled(false)
        #expect(!manager.isEnabled)
        #expect(!vm.settings.caffeinateEnabled)
        // Disabling an indefinite session does not invent a timed one.
        #expect(vm.settings.caffeinateUntil != nil)
    }

    @Test func preferenceSwitchesReachTheRunningManager() {
        let manager = RecordingCaffeinateManager()
        let vm = QuickViewModel(caffeinateManager: manager)
        vm.persistSettings = { _ in }

        vm.settings.caffeinateAgentWatch = false
        vm.settings.caffeinateBatteryCutoff = 35
        vm.settings.caffeinateKeepDisplayAwake = true
        vm.applyCaffeinatePreferences()

        #expect(manager.isAgentWatchEnabled == false)
        #expect(manager.batteryCutoff == 35)
        #expect(manager.keepsDisplayAwake)
        // Applying preferences never starts a session on its own.
        #expect(!manager.isEnabled)
    }

    // MARK: - Items removal

    @Test func addingACoveredFolderOrAppIsRejected() {
        let vm = QuickViewModel()
        vm.persistSettings = { _ in }

        // A built-in folder path is already in the list; storing it again
        // would leave a record the Items table deduplicates away.
        let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        #expect(vm.addCustomFolder(downloads) == false)
        #expect(vm.settings.customFolders.isEmpty)

        // An app inside a scanned Applications root is already in the list.
        #expect(vm.addCustomApplication(URL(fileURLWithPath: "/Applications/Example.app")) == false)
        #expect(vm.settings.customApplicationPaths.isEmpty)

        // A folder outside every built-in is accepted, and adding twice is a no-op.
        let fresh = URL(fileURLWithPath: "/tmp/quick-launch-fresh-\(UUID().uuidString)")
        #expect(vm.addCustomFolder(fresh))
        #expect(vm.addCustomFolder(fresh) == false)
        #expect(vm.settings.customFolders.count == 1)
    }

    @Test func removingACustomApplicationDropsThePathAndItsConfiguration() {
        let vm = QuickViewModel()
        vm.persistSettings = { _ in }
        let url = URL(fileURLWithPath: "/Applications/Example App.app")
        let application = LaunchableApplication(
            name: "Example App",
            bundleIdentifier: "com.example.app",
            url: url
        )
        vm.settings.customApplicationPaths = [url.standardizedFileURL.path]
        vm.setApplicationAlias("ex", for: application)
        #expect(!vm.settings.launcherItemConfigurations.isEmpty)

        vm.removeCustomApplication(application)

        #expect(vm.settings.customApplicationPaths.isEmpty)
        #expect(vm.applicationAlias(for: application).isEmpty)
    }

    @Test func removingACustomFolderDropsTheFolderAndItsConfiguration() {
        let vm = QuickViewModel()
        vm.persistSettings = { _ in }
        let location = FolderLocation(
            id: "custom-1",
            title: "Notes",
            path: "/tmp/notes",
            systemImage: "folder",
            isBuiltIn: false
        )
        vm.settings.customFolders = [location]
        let item = LauncherCatalogItem(
            kind: .folder,
            itemID: location.id,
            title: location.title,
            detail: location.path,
            value: location.path
        )
        vm.setLauncherItemAlias("nt", for: item)

        vm.removeCustomFolder(item)

        #expect(vm.settings.customFolders.isEmpty)
        #expect(vm.launcherItemAlias(for: item).isEmpty)
    }

    // MARK: - Staples

    @Test func aSettingsDestinationCanBePinnedAndBecomeAStaple() throws {
        let vm = QuickViewModel()
        vm.persistSettings = { _ in }
        let item = try #require(SettingsDestinationIndex.destination(id: "general.caffeinate.battery")?.launcherItem)

        vm.togglePinLauncherItem(item)
        #expect(vm.isLauncherItemPinned(item), "a setting is a normal pinnable command row")

        vm.learnDirectUse(of: item)
        vm.input = ""
        #expect(
            vm.launcherMatches.contains { $0.id == item.id },
            "a learned setting is offered as a root staple"
        )
    }

    // MARK: - Update preference

    @Test func updateCheckOnLaunchDefaultsOffAndIsNotSilentlyEnabled() {
        // The preference exists but was dead code. It defaults off in both the
        // declaration and the decoder, so wiring it to launch behaviour does
        // not start any network call for an existing user who never asked.
        #expect(QuickSettings().checkForUpdatesOnLaunch == false)

        let decoded = QuickSettings.load(from: UserDefaults(suiteName: "settings-search-empty-\(UUID().uuidString)")!)
        #expect(decoded.checkForUpdatesOnLaunch == false)
    }
}

// MARK: - Fakes

@MainActor
private final class RecordingSettingsPresenter: OverlayPresenting {
    private(set) var revealedDestination: SettingsDestination?
    private(set) var openCount = 0

    func presentOverlay() {}
    func dismissOverlay() {}
    func openSettings() { openCount += 1 }
    func openSettings(destination: SettingsDestination) { revealedDestination = destination }
    func openTranslator() {}
    func openTranslator(retainedSelection: String?) {}
    func openTypeToClick() {}
}

@MainActor
private final class RecordingCaffeinateManager: CaffeinateManaging {
    var isEnabled = false
    var hasLiveSession = false
    var pauseDetail: String?
    var endsAt: Date?
    var sessionDeadline: Date?
    var statusSummary = "—"
    var reason: String?
    var isAgentWatchEnabled = true
    var batteryCutoff = 20
    var keepsDisplayAwake = false
    var onChange: (() -> Void)?
    /// When true, `setEnabled(true)` behaves like an assertion that failed.
    var refusesEnable = false
    /// When true, a started timer is in force but the assertion is released.
    var paused = false
    private(set) var setEnabledCalls: [Bool] = []

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        setEnabledCalls.append(enabled)
        if enabled, refusesEnable {
            isEnabled = false
            return false
        }
        isEnabled = enabled
        hasLiveSession = enabled
        if !enabled {
            endsAt = nil
            sessionDeadline = nil
            pauseDetail = nil
        }
        return true
    }

    @discardableResult
    func enable(for duration: TimeInterval) -> Bool {
        startTimer(until: Date().addingTimeInterval(duration))
    }

    @discardableResult
    func enable(until date: Date) -> Bool {
        startTimer(until: date)
    }

    /// Models the manager: a started timer is in force and keeps its deadline
    /// even while the battery has paused the assertion.
    @discardableResult
    private func startTimer(until deadline: Date) -> Bool {
        hasLiveSession = true
        sessionDeadline = deadline
        isEnabled = !paused
        endsAt = paused ? nil : deadline
        pauseDetail = paused ? "Paused at 10% battery. Decaffeinate to cancel." : nil
        return true
    }
}
