import Foundation
import Testing
@testable import QuickLaunch

/// The Return rule: Return runs the highlighted row. "Ask AI" is a row like
/// any other, so what gets highlighted decides whether Return launches or asks.
@Suite("Ask AI row and Tab", .serialized)
@MainActor
struct AskAITests {
    private static let apps = [
        LaunchableApplication(name: "Hidden Bar", bundleIdentifier: "com.example.hiddenbar", url: URL(fileURLWithPath: "/Applications/Hidden Bar.app")),
        LaunchableApplication(name: "Books", bundleIdentifier: "com.apple.iBooksX", url: URL(fileURLWithPath: "/System/Applications/Books.app")),
        LaunchableApplication(name: "Weather", bundleIdentifier: "com.apple.weather", url: URL(fileURLWithPath: "/System/Applications/Weather.app")),
        LaunchableApplication(name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode", url: URL(fileURLWithPath: "/Applications/Visual Studio Code.app")),
        LaunchableApplication(name: "WeChat", bundleIdentifier: "com.tencent.xinWeChat", url: URL(fileURLWithPath: "/Applications/WeChat.app")),
    ]

    private func make(settings: QuickSettings = QuickSettings()) -> (QuickViewModel, AskAIFakeCatalog, MockQuickService) {
        let catalog = AskAIFakeCatalog(applications: Self.apps)
        let ai = MockQuickService()
        let vm = QuickViewModel(settings: settings, service: ai, applicationCatalog: catalog)
        return (vm, catalog, ai)
    }

    private func first(_ vm: QuickViewModel) -> String { vm.launcherMatches.first?.id ?? "" }
    private var askID: String { LauncherCatalogItem(kind: .askAI, itemID: QuickViewModel.askAIItemID, title: "", detail: "", value: "").id }

    @Test func singleWordKeepsTheLauncherFirstAndAskAILast() {
        let (vm, _, _) = make()
        vm.input = "hi"
        #expect(first(vm) == "application:com.example.hiddenbar")
        #expect(vm.launcherMatches.last?.id == askID)
        vm.input = "weather"
        #expect(first(vm) == "application:com.apple.weather")
        #expect(vm.launcherMatches.contains { $0.id == askID })
    }

    @Test func promptShapedTextPutsAskAIFirst() async {
        let (vm, catalog, ai) = make()
        for text in ["what is the capital of france", "fix grammar", "write a haiku", "hello?", "define entropy"] {
            vm.input = text
            #expect(first(vm) == askID, "\(text)")
            #expect(vm.footerHints.first?.label == "Ask", "\(text)")
        }
        vm.input = "what is the capital of france"
        await vm.submitResolvingFuzzyAlias()
        #expect(catalog.launched == nil)
        #expect(await ai.sendCallCount == 1)
    }

    @Test func titlePrefixStillBeatsAskAIForTwoWords() {
        let (vm, _, _) = make()
        vm.input = "visual studio"
        #expect(first(vm) == "application:com.microsoft.VSCode")
    }

    @Test func learnedAbbreviationBeatsAskAI() {
        let (vm, _, _) = make()
        vm.input = "what"
        #expect(first(vm) == askID, "a leading question word reads as a prompt")
        vm.learn(.application(Self.apps[4]))
        #expect(first(vm) == "application:com.tencent.xinWeChat", "what the user taught wins")
    }

    @Test func pinnedAskAIOutranksWeakMatchesOnOneWord() {
        var settings = QuickSettings()
        settings.launcherItemConfigurations.append(
            LauncherItemConfiguration(kind: .askAI, itemID: QuickViewModel.askAIItemID, isPinned: true)
        )
        let (vm, _, _) = make(settings: settings)
        vm.input = "ok"
        #expect(first(vm) == askID, "a pin beats a letters-in-order match")
        vm.input = "hi"
        #expect(first(vm) == "application:com.example.hiddenbar", "a title prefix still beats a pin")
        vm.input = "weather"
        #expect(first(vm) == "application:com.apple.weather", "an exact name still wins")
    }

    @Test func frequentUseLiftsAskAIAboveSubsequenceMatches() {
        let (vm, _, _) = make()
        vm.input = "ok"
        #expect(first(vm) == "application:com.apple.iBooksX")
        for _ in 0..<20 { vm.learnDirectUse(of: vm.askAIItem(query: "")) }
        vm.input = "ok"
        #expect(first(vm) == askID)
    }

    @Test func aliasFindsAskAI() {
        var settings = QuickSettings()
        settings.launcherItemConfigurations.append(
            LauncherItemConfiguration(kind: .askAI, itemID: QuickViewModel.askAIItemID, alias: "ai")
        )
        let (vm, _, _) = make(settings: settings)
        vm.input = "ai"
        #expect(first(vm) == askID)
    }

    @Test func emptyRootShowsAskAIBeforeTheCatalogs() {
        let (vm, _, _) = make()
        vm.input = ""
        let ids = vm.launcherMatches.map(\.id)
        #expect(ids.first == askID)
        #expect(ids.contains("catalog:snippets"))
    }

    @Test func tabHandsTheTypedTextToQuickAIAndSendsIt() async {
        let (vm, catalog, ai) = make()
        vm.input = "hi"
        #expect(vm.handleTab())
        #expect(vm.isQuickAIPresented)
        #expect(vm.launcherMatches.isEmpty)
        await vm.tabSubmitTask?.value
        #expect(catalog.launched == nil)
        #expect(await ai.sendCallCount == 1, "Tab submits in the same gesture")
        #expect(vm.lastQuestion == "hi")
        #expect(vm.inputMode == nil)
    }

    @Test func tabCompletesASavedPromptAliasFirst() {
        let (vm, _, _) = make()
        vm.input = "/gram"
        #expect(vm.handleTab())
        #expect(vm.inputMode == nil)
        #expect(vm.input.hasPrefix("/grammar"))
    }

    @Test func backspaceOnEmptyLeavesTheSurface() {
        let (vm, _, _) = make()
        vm.input = ""
        vm.openQuickAI()
        #expect(vm.popLayerForEmptyBackspace())
        #expect(!vm.isQuickAIPresented)
    }

    @Test func hotkeyPathOpensTheModeWithNothingTyped() async {
        let (vm, _, _) = make()
        let item = vm.catalogItem(kind: .askAI, itemID: QuickViewModel.askAIItemID)
        #expect(item != nil)
        await vm.performLauncherItem(item!)
        #expect(vm.isQuickAIPresented)
        #expect(vm.input.isEmpty)
        #expect(vm.quickAITitle == "Quick AI")
    }

    @Test func askAIHasPinAliasAndHotkeyActions() {
        let (vm, _, _) = make()
        let kinds = ItemActionCatalog.actions(for: .item(vm.askAIItem(query: "x")), pasteTarget: nil).map(\.kind)
        #expect(kinds == [.primary, .pin, .setAlias, .setHotkey])
    }

    @Test func rankerShape() {
        #expect(AskAIRanker.looksLikePrompt("what"))
        #expect(AskAIRanker.looksLikePrompt("two words"))
        #expect(AskAIRanker.looksLikePrompt("thanks?"))
        #expect(!AskAIRanker.looksLikePrompt("weather"))
        #expect(!AskAIRanker.looksLikePrompt("hi"))
        #expect(!AskAIRanker.looksLikePrompt(""))
    }
}

private final class AskAIFakeCatalog: ApplicationCatalogServicing {
    let applications: [LaunchableApplication]
    var launched: LaunchableApplication?
    init(applications: [LaunchableApplication]) { self.applications = applications }
    func launch(_ application: LaunchableApplication) -> Bool { launched = application; return true }
}
