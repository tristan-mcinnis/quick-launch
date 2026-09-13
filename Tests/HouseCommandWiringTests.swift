import Foundation
import Testing
@testable import QuickLaunch

/// The launcher shipped once with `houseCommandCatalog` left nil in the real
/// app: every house-command path returned at its `guard let`, no row could
/// exist, and the whole suite stayed green because each test injected its own
/// catalog. These pin the wiring itself rather than the behaviour behind it.
@Suite("House command wiring")
@MainActor
struct HouseCommandWiringTests {
    @Test func aViewModelBuiltWithoutACatalogOffersNoHouseRows() async {
        let vm = QuickViewModel(service: MockQuickService())
        vm.refreshHouseCommands()
        await vm.waitForHouseCommandRefreshForTesting()
        #expect(vm.houseCommandItems.isEmpty, "no catalog means no rows, silently — the shipped bug")
    }

    /// The real construction path must pass one. Reading the source is crude,
    /// but it is the only thing that catches a dependency quietly dropped from
    /// a thirty-argument initialiser.
    @Test func theAppWiresACatalogIntoTheLauncher() throws {
        let here = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: here.appendingPathComponent("Sources/App/AppDelegate.swift"),
            encoding: .utf8
        )
        #expect(
            source.contains("houseCommandCatalog: HouseCommandCatalog("),
            "AppDelegate must inject a HouseCommandCatalog, or no house command can ever appear"
        )
    }
}
