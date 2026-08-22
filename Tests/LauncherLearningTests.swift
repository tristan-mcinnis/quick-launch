import Foundation
import Testing
@testable import QuickLaunch

@Suite("Launcher learning", .serialized)
@MainActor
struct LauncherLearningTests {
    private static let claude = LaunchableApplication(
        name: "Claude",
        bundleIdentifier: "com.anthropic.claudefordesktop",
        url: URL(fileURLWithPath: "/Applications/Claude.app")
    )
    private static let clashX = LaunchableApplication(
        name: "ClashX",
        bundleIdentifier: "com.west2online.ClashX",
        url: URL(fileURLWithPath: "/Applications/ClashX.app")
    )
    private static let calendar = LaunchableApplication(
        name: "Calendar",
        bundleIdentifier: "com.apple.iCal",
        url: URL(fileURLWithPath: "/System/Applications/Calendar.app")
    )
    private static let clamp = LaunchableApplication(
        name: "Clamp",
        bundleIdentifier: "com.example.clamp",
        url: URL(fileURLWithPath: "/Applications/Clamp.app")
    )

    private func makeViewModel(
        usage: LauncherUsageStore? = nil,
        settings: QuickSettings = QuickSettings()
    ) -> (QuickViewModel, LearningFakeCatalog) {
        let catalog = LearningFakeCatalog(applications: [
            Self.calendar, Self.clamp, Self.clashX, Self.claude,
        ])
        let vm = QuickViewModel(
            settings: settings,
            applicationCatalog: catalog,
            launcherUsage: usage
        )
        return (vm, catalog)
    }

    // MARK: - Store

    @Test func storeLearnsExactAbbreviationWithDecayAndBounds() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let store = LauncherUsageStore(fileURL: nil, now: { clock })
        store.recordSelection(query: "Cla", scope: "root", itemID: "application:claude")
        store.recordSelection(query: "cla", scope: "root", itemID: "application:claude")
        #expect(store.mnemonicWeight(query: "CLA", scope: "root", itemID: "application:claude") == 2)
        #expect(store.frecency(itemID: "application:claude") == 2)
        #expect(store.mnemonicWeight(query: "cla", scope: "snippets", itemID: "application:claude") == 0)

        clock = clock.addingTimeInterval(LauncherUsageStore.halfLife)
        #expect(abs(store.mnemonicWeight(query: "cla", scope: "root", itemID: "application:claude") - 1) < 0.001)

        for index in 0..<(LauncherUsageStore.maxItemsPerMnemonic + 3) {
            store.recordSelection(query: "cla", scope: "root", itemID: "item-\(index)")
        }
        let bucket = store.mnemonics[LauncherUsageStore.mnemonicKey(scope: "root", query: "cla")] ?? [:]
        #expect(bucket.count == LauncherUsageStore.maxItemsPerMnemonic)
    }

    @Test func storePersistsAndResets() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-usage-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("launcher-usage.json")

        let store = LauncherUsageStore(fileURL: file)
        store.recordSelection(query: "sl", scope: "root", itemID: "application:slack")
        store.recordUse(itemID: "command:window.leftHalf")

        let reloaded = LauncherUsageStore(fileURL: file)
        #expect(reloaded.mnemonicWeight(query: "sl", scope: "root", itemID: "application:slack") > 0.99)
        #expect(reloaded.frecency(itemID: "command:window.leftHalf") > 0.99)
        let top = Set(reloaded.topItemIDs(limit: 5))
        #expect(top == ["application:slack", "command:window.leftHalf"])

        reloaded.reset()
        #expect(reloaded.isEmpty)
        #expect(LauncherUsageStore(fileURL: file).isEmpty)

        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(!contents.contains("Hello"))
    }

    @Test func signalsCoverExactShorterAndLongerAbbreviations() {
        let store = LauncherUsageStore(fileURL: nil)
        store.recordSelection(query: "cla", scope: "root", itemID: "a")
        store.recordSelection(query: "cl", scope: "root", itemID: "b")
        store.recordSelection(query: "clau", scope: "root", itemID: "c")
        store.recordUse(itemID: "d")

        let signals = store.signals(query: "cla", scope: "root")
        #expect(abs((signals["a"]?.exactMnemonic ?? 0) - 1) < 0.001)
        #expect(abs((signals["b"]?.relatedMnemonic ?? 0) - 1) < 0.001)
        #expect(abs((signals["c"]?.relatedMnemonic ?? 0) - 1) < 0.001)
        #expect(abs((signals["d"]?.frecency ?? 0) - 1) < 0.001)
        #expect(signals["d"]?.exactMnemonic == 0)
        #expect(LauncherRanker.boost(for: signals["a"]) > LauncherRanker.boost(for: signals["b"]))
        #expect(LauncherRanker.boost(for: signals["b"]) > LauncherRanker.boost(for: signals["d"]))
        #expect(LauncherRanker.boost(for: nil) == 0)
    }

    // MARK: - Ranking through the view model

    @Test func choosingClaudeForClaMakesItFirstNextTime() async {
        let (vm, catalog) = makeViewModel()
        vm.input = "cla"
        let before = vm.launcherMatches
        #expect(before.contains(.application(Self.claude)))
        #expect(before.first != .application(Self.claude))

        vm.applicationSelectionIndex = before.firstIndex(of: .application(Self.claude)) ?? 0
        await vm.submitResolvingFuzzyAlias()
        #expect(catalog.launched == Self.claude)

        vm.input = "cla"
        #expect(vm.launcherMatches.first == .application(Self.claude))
        #expect(vm.applicationMatches.first == Self.claude)
    }

    @Test func learnedAbbreviationHelpsShorterAndLongerTyping() async {
        let (vm, _) = makeViewModel()
        vm.input = "cla"
        vm.applicationSelectionIndex = vm.launcherMatches.firstIndex(of: .application(Self.claude)) ?? 0
        await vm.submitResolvingFuzzyAlias()

        vm.input = "c"
        #expect(vm.launcherMatches.first == .application(Self.claude))
        vm.input = "claud"
        #expect(vm.launcherMatches.first == .application(Self.claude))
        // An exact name still wins over a related abbreviation.
        vm.input = "calendar"
        #expect(vm.launcherMatches.first == .application(Self.calendar))
    }

    @Test func learnedFavouritesAppearBeforeCatalogRootsOnEmptyInput() async {
        let (vm, _) = makeViewModel()
        vm.input = ""
        #expect(vm.launcherMatches.count == LauncherCatalogScope.allCases.count)

        vm.input = "cla"
        vm.applicationSelectionIndex = vm.launcherMatches.firstIndex(of: .application(Self.claude)) ?? 0
        await vm.submitResolvingFuzzyAlias()

        vm.input = ""
        let matches = vm.launcherMatches
        #expect(matches.first == .application(Self.claude))
        #expect(matches.count == LauncherCatalogScope.allCases.count + 1)
        #expect(matches.count <= QuickViewModel.maxLauncherRows)
    }

    @Test func learningCanBeDisabledAndForgotten() async {
        var settings = QuickSettings()
        settings.launcherLearningEnabled = false
        let store = LauncherUsageStore(fileURL: nil)
        let (vm, _) = makeViewModel(usage: store, settings: settings)

        vm.input = "cla"
        vm.applicationSelectionIndex = vm.launcherMatches.firstIndex(of: .application(Self.claude)) ?? 0
        await vm.submitResolvingFuzzyAlias()
        #expect(store.isEmpty)

        vm.settings.launcherLearningEnabled = true
        vm.input = "cla"
        vm.applicationSelectionIndex = vm.launcherMatches.firstIndex(of: .application(Self.claude)) ?? 0
        await vm.submitResolvingFuzzyAlias()
        #expect(!store.isEmpty)
        vm.input = "cla"
        #expect(vm.launcherMatches.first == .application(Self.claude))

        vm.forgetLearnedRanking()
        #expect(store.isEmpty)
        vm.input = "cla"
        #expect(vm.launcherMatches.first != .application(Self.claude))
    }

    @Test func directHotkeyUseCountsTowardFavourites() {
        let (vm, _) = makeViewModel()
        vm.learnDirectUse(of: Self.clashX)
        vm.input = ""
        #expect(vm.launcherMatches.first == .application(Self.clashX))
    }

    @Test func snippetsAndQuickLinksAreReachableFromTheRoot() {
        let catalog = LearningFakeLauncherCatalog()
        let vm = QuickViewModel(launcherCatalog: catalog)
        vm.input = "greet"
        #expect(vm.launcherMatches.contains { result in
            guard case .item(let item) = result else { return false }
            return item.kind == .snippet && item.title == "Greeting"
        })
        vm.input = "site"
        #expect(vm.launcherMatches.contains { result in
            guard case .item(let item) = result else { return false }
            return item.kind == .quickLink && item.title == "Site"
        })
    }

    @Test func learningInsideACatalogIsScopedToThatCatalog() async {
        let catalog = LearningFakeLauncherCatalog()
        catalog.snippets.append(LauncherCatalogItem(
            kind: .snippet, itemID: "three", title: "Great Escape", detail: "Test", value: "Bye"
        ))
        let store = LauncherUsageStore(fileURL: nil)
        let vm = QuickViewModel(launcherCatalog: catalog, launcherUsage: store)
        vm.enterCatalog(.snippets)
        vm.input = "gre"
        let greatEscape = vm.catalogMatches.first { $0.title == "Great Escape" }
        #expect(greatEscape != nil)
        vm.applicationSelectionIndex = vm.launcherMatches.firstIndex(of: .item(greatEscape!)) ?? 0
        await vm.submitResolvingFuzzyAlias()

        #expect(abs(store.mnemonicWeight(query: "gre", scope: "snippets", itemID: greatEscape!.id) - 1) < 0.001)
        #expect(store.mnemonicWeight(query: "gre", scope: "root", itemID: greatEscape!.id) == 0)
        vm.enterCatalog(.snippets)
        vm.input = "gre"
        #expect(vm.catalogMatches.first?.title == "Great Escape")
        vm.input = ""
        #expect(vm.catalogMatches.first?.title == "Great Escape")
    }

    @Test func rankingAHundredQueriesStaysWithinBudget() {
        let store = LauncherUsageStore(fileURL: nil)
        for index in 0..<200 {
            store.recordSelection(query: "q\(index % 40)", scope: "root", itemID: "application:app-\(index)")
        }
        let vm = QuickViewModel(applicationCatalog: ApplicationCatalogService(), launcherUsage: store)
        vm.input = "q1"
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<100 {
            _ = vm.launcherMatches
        }
        #expect(start.duration(to: clock.now) < .milliseconds(250))
    }
}

private final class LearningFakeCatalog: ApplicationCatalogServicing {
    let applications: [LaunchableApplication]
    var launched: LaunchableApplication?

    init(applications: [LaunchableApplication]) {
        self.applications = applications
    }

    func launch(_ application: LaunchableApplication) -> Bool {
        launched = application
        return true
    }
}

private final class LearningFakeLauncherCatalog: LauncherCatalogServicing {
    var snippets = [LauncherCatalogItem(
        kind: .snippet, itemID: "one", title: "Greeting", detail: "Test", value: "Hello"
    )]
    var quickLinks = [LauncherCatalogItem(
        kind: .quickLink, itemID: "two", title: "Site", detail: "example.com",
        value: "https://example.com"
    )]
    func reload() {}
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteSnippet(_ item: LauncherCatalogItem) throws {}
}
