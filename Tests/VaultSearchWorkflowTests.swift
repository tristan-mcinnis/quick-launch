import Testing
import Foundation
@testable import QuickLaunch

@MainActor
@Suite("Vault Search workflow")
struct VaultSearchWorkflowTests {
    @Test func catalogUsesExistingKeyboardItemAndInputModeContract() async {
        let service = RecordingVaultSearchService()
        let vm = QuickViewModel(vaultSearchService: service)

        vm.enterCatalog(.vaultSearch)
        #expect(vm.catalogMatches.map(\.title) == [
            "Current Project", "Reconcile Changes", "Project History", "Across Projects",
        ])
        let item = vm.catalogMatches[0]
        #expect(item.defaultActionTitle == "Search")
        #expect(item.systemImage == "magnifyingglass")

        await vm.performLauncherItem(item)
        #expect(vm.inputMode == .vaultSearch(.current))
        #expect(vm.footerContext == "Vault Search · Current Project")
        #expect(vm.inputPlaceholder == "Project and question…")
        #expect(vm.footerHints.map(\.label) == ["Search", "Back"])
    }

    @Test func resultAndFollowUpStayOnVaultSearchInsteadOfAI() async {
        let service = RecordingVaultSearchService()
        let vm = QuickViewModel(vaultSearchService: service)
        vm.enterInputMode(.vaultSearch(.current))
        vm.input = "Acme Launch where do we stand?"

        #expect(await vm.submitInputMode())
        #expect(vm.output == "Vault result")
        #expect(vm.lastQuestion == "Acme Launch where do we stand?")
        #expect(vm.activeVaultSearchMode == .current)

        vm.input = "What changed after the meeting?"
        await vm.submitResolvingFuzzyAlias()

        let calls = await service.recordedCalls()
        #expect(calls.count == 2)
        #expect(calls[1].mode == .current)
        #expect(calls[1].query.contains("Follow-up: What changed after the meeting?"))
    }

    @Test func rootExposesOneAccessibleCatalogNotFourCompetingRows() {
        let vm = QuickViewModel(vaultSearchService: RecordingVaultSearchService())
        let roots = vm.launcherMatches
        #expect(roots.contains(.catalog(.vaultSearch, count: 4)))
        #expect(roots.filter { $0.id == "catalog:vaultSearch" }.count == 1)
    }

    @Test func escapeDuringAVaultSearchRestoresTheQuestionAndPublishesNothing() async {
        let service = SuspendingVaultSearchService()
        let vm = QuickViewModel(vaultSearchService: service)
        vm.enterInputMode(.vaultSearch(.current))
        vm.input = "Acme Launch where do we stand?"
        vm.submitFromComposer()
        let submit = vm.composerSubmitTask
        await service.waitUntilSearching()
        vm.cancel()
        await submit?.value
        #expect(vm.output.isEmpty)
        #expect(vm.input == "Acme Launch where do we stand?")
    }
}

private actor SuspendingVaultSearchService: VaultSearchServicing {
    private var started = false

    func search(mode: VaultSearchMode, query: String) async throws -> String {
        started = true
        try await Task.sleep(for: .seconds(30))
        return "Vault result"
    }

    func waitUntilSearching() async {
        while !started { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

private actor RecordingVaultSearchService: VaultSearchServicing {
    struct Call: Sendable {
        let mode: VaultSearchMode
        let query: String
    }
    private var calls: [Call] = []

    func search(mode: VaultSearchMode, query: String) async throws -> String {
        calls.append(Call(mode: mode, query: query))
        return "Vault result"
    }

    func recordedCalls() -> [Call] { calls }
}
