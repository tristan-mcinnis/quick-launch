import Foundation
import Testing
@testable import QuickLaunch

@Suite("Application launcher workflow", .serialized)
@MainActor
struct ApplicationLauncherWorkflowTests {
    @Test func spotifyFuzzyMatchLaunchesWithoutCallingAI() async {
        let catalog = FakeApplicationCatalog(applications: [
            LaunchableApplication(
                name: "Spotify",
                bundleIdentifier: "com.spotify.client",
                url: URL(fileURLWithPath: "/Applications/Spotify.app")
            ),
            LaunchableApplication(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                url: URL(fileURLWithPath: "/Applications/Safari.app")
            ),
        ])
        let ai = MockQuickService()
        let vm = QuickViewModel(service: ai, applicationCatalog: catalog)
        vm.input = "spotfy"

        #expect(vm.applicationMatches.first?.name == "Spotify")
        await vm.submitResolvingFuzzyAlias()

        #expect(catalog.launched?.name == "Spotify")
        #expect(await ai.sendCallCount == 0)
    }

    @Test func eachKeystrokeNarrowsVisibleApplications() {
        let catalog = FakeApplicationCatalog(applications: [
            LaunchableApplication(
                name: "Spotify",
                bundleIdentifier: "com.spotify.client",
                url: URL(fileURLWithPath: "/Applications/Spotify.app")
            ),
            LaunchableApplication(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                url: URL(fileURLWithPath: "/Applications/Safari.app")
            ),
            LaunchableApplication(
                name: "System Settings",
                bundleIdentifier: "com.apple.systempreferences",
                url: URL(fileURLWithPath: "/System/Applications/System Settings.app")
            ),
        ])
        let vm = QuickViewModel(applicationCatalog: catalog)

        vm.input = "s"
        let broad = vm.applicationMatches.map(\.name)
        vm.input = "sp"
        let narrower = vm.applicationMatches.map(\.name)
        vm.input = "spot"
        let narrowest = vm.applicationMatches.map(\.name)

        #expect(broad.count > narrower.count)
        #expect(narrower == ["Spotify"])
        #expect(narrowest == ["Spotify"])
    }

    @Test func configuredAliasFindsApplication() {
        let slack = LaunchableApplication(
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            url: URL(fileURLWithPath: "/Applications/Slack.app")
        )
        let catalog = FakeApplicationCatalog(applications: [slack])
        var settings = QuickSettings()
        settings.launcherItemConfigurations = [
            LauncherItemConfiguration(
                kind: .application,
                itemID: slack.id,
                alias: "work chat"
            )
        ]
        let vm = QuickViewModel(settings: settings, applicationCatalog: catalog)
        vm.input = "work chat"

        #expect(vm.applicationMatches == [slack])
    }

    @Test func commandKOpensContextActionsForHighlightedApp() {
        let spotify = LaunchableApplication(
            name: "Spotify",
            bundleIdentifier: "com.spotify.client",
            url: URL(fileURLWithPath: "/Applications/Spotify.app")
        )
        let vm = QuickViewModel(
            applicationCatalog: FakeApplicationCatalog(applications: [spotify])
        )
        vm.input = "spot"

        vm.handleCommandK()

        #expect(vm.isApplicationActionPanePresented)
        #expect(vm.contextualApplication == spotify)
        #expect(!vm.isActionPalettePresented)
    }

    @Test func duplicateApplicationAliasesAreRejected() {
        let slack = LaunchableApplication(
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            url: URL(fileURLWithPath: "/Applications/Slack.app")
        )
        let weChat = LaunchableApplication(
            name: "WeChat",
            bundleIdentifier: "com.tencent.xinWeChat",
            url: URL(fileURLWithPath: "/Applications/WeChat.app")
        )
        let catalog = FakeApplicationCatalog(applications: [slack, weChat])
        let vm = QuickViewModel(applicationCatalog: catalog)

        vm.setApplicationAlias("chat", for: slack)
        vm.setApplicationAlias("CHAT", for: weChat)

        #expect(vm.applicationConfigurationConflict(for: slack) != nil)
        #expect(vm.applicationConfigurationConflict(for: weChat) != nil)
    }

    /// The real catalog finds the apps on this Mac and filters them. Its
    /// speed is a separate budget (`LauncherPerformanceBudgetTests`), which
    /// the default run leaves out.
    @Test func realCatalogFindsAndFiltersTheApplications() {
        let catalog = ApplicationCatalogService()
        let vm = QuickViewModel(applicationCatalog: catalog)
        vm.input = "finder"
        #expect(!catalog.applications.isEmpty)
        #expect(catalog.applications.contains { $0.name == "Finder" })
        #expect(vm.applicationMatches.contains { $0.name == "Finder" })
    }
}

/// The launcher's speed budget: a catalog scan and 100 filters each under
/// 250 ms. Wall-clock numbers mean nothing while other builds and suites
/// share the machine, so this runs only when asked, on a quiet machine:
/// `QUICK_LAUNCH_PERF=1 swift test --filter LauncherPerformanceBudgetTests`.
@Suite(
    "Launcher performance budget",
    .enabled(if: ProcessInfo.processInfo.environment["QUICK_LAUNCH_PERF"] == "1")
)
@MainActor
struct LauncherPerformanceBudgetTests {
    @Test func realCatalogAndFilteringStayWithinLauncherBudget() {
        let clock = ContinuousClock()
        let scanStart = clock.now
        let catalog = ApplicationCatalogService()
        let scanTime = scanStart.duration(to: clock.now)

        let vm = QuickViewModel(applicationCatalog: catalog)
        vm.input = "spot"
        let filterStart = clock.now
        for _ in 0..<100 {
            _ = vm.applicationMatches
        }
        let filterTime = filterStart.duration(to: clock.now)

        #expect(!catalog.applications.isEmpty)
        #expect(scanTime < .milliseconds(250))
        #expect(filterTime < .milliseconds(250))
    }
}

@MainActor
private final class FakeApplicationCatalog: ApplicationCatalogServicing {
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
