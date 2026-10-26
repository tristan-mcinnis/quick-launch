import Foundation
import AppKit
import SwiftUI
import Testing
@testable import QuickLaunch
import HouseDesign

@Suite("Web search provider", .serialized)
@MainActor
struct WebSearchProviderTests {
    @Test func providerChoiceRoundTripsAndOlderSettingsKeepAutomatic() throws {
        for provider in WebSearchProvider.allCases {
            var settings = QuickSettings()
            settings.webSearchProvider = provider
            let data = try JSONEncoder().encode(settings)
            #expect(try JSONDecoder().decode(QuickSettings.self, from: data).webSearchProvider == provider)
        }
        for json in [#"{"autoCopy":false}"#, #"{"autoCopy":false,"webSearchProvider":"retired-engine"}"#] {
            let settings = try JSONDecoder().decode(QuickSettings.self, from: Data(json.utf8))
            #expect(settings.webSearchProvider == .automatic)
            #expect(settings.autoCopy == false, "an unknown provider never resets other settings")
        }
    }

    @Test func explicitSearchUsesTheChosenProvider() async {
        let search = ProviderRecordingSearch()
        let ai = MockQuickService()
        await ai.setResponses([StreamDelta(text: "Found it", finishReason: "stop")])
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.webSearchProvider = .tavily
        let vm = QuickViewModel(settings: settings, service: ai, webSearchService: search)
        vm.input = "/search release notes"
        await vm.submit()
        #expect(await search.providers == [.tavily])
        #expect(vm.output == "Found it")
    }

    @Test func bothChatSurfacesAndTranslatorUseOneChosenProvider() async throws {
        let search = ProviderRecordingSearch()
        let launcher = QuickViewModel(webSearchService: search)
        let chat = QuickViewModel(store: launcher.store, webSearchService: search)
        launcher.settings.webSearchProvider = .brave
        for vm in [launcher, chat] {
            let provider = try #require(vm.settings.selectedProvider)
            let service = try #require(vm.makeService(provider: provider, model: "test") as? OpenAICompatibleService)
            let call = try #require(service.webSearch)
            _ = try await call("first query")
        }
        chat.settings.webSearchProvider = .tavily
        launcher.apiKeyProvider = { _ in "test-key" }
        let translator = try #require(launcher.makeCurrentService() as? OpenAICompatibleService)
        let lookup = try #require(translator.webSearch)
        _ = try await lookup("translation lookup")
        #expect(await search.providers == [.brave, .brave, .tavily])
    }

    @Test func onlyTheKeyedBackendsNeedAKey() {
        for provider in WebSearchProvider.allCases {
            #expect(provider.requiresAPIKey == (provider != .automatic), "\(provider.title)")
        }
    }

    @Test func backendMappingIsStable() {
        #expect(WebSearchProvider.automatic.backend == .chain)
        #expect(WebSearchProvider.tavily.backend == .tavily)
        #expect(WebSearchProvider.brave.backend == .brave)
        #expect(WebSearchProvider.bocha.backend == .bocha)
        #expect(WebSearchProvider.exa.backend == .exa)
    }

    @Test func aRetiredHostedEngineProviderFallsBackToAutomatic() throws {
        for name in ["google", "bing", "duckduckgo", "news"] {
            let json = #"{"autoCopy":false,"webSearchProvider":"\#(name)"}"#
            let settings = try JSONDecoder().decode(QuickSettings.self, from: Data(json.utf8))
            #expect(settings.webSearchProvider == .automatic)
        }
    }

    @Test func paletteChoiceIsFuzzySharedAndPersisted() throws {
        let vm = QuickViewModel(webSearchService: ProviderRecordingSearch())
        let chat = QuickViewModel(store: vm.store)
        vm.openQuickAI()
        vm.actionQuery = "srchprv"
        #expect(vm.paletteSurfaceActions.contains(.searchSettings))
        vm.performQuickAISurfaceAction(.searchSettings)
        #expect(vm.actionPaletteSubmenu == .searchProviders)
        vm.actionQuery = "brv"
        #expect(vm.paletteSearchProviders == [.brave])
        #expect(vm.actionPaletteEntryCount == 1)
        let suite = "WebSearchProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        vm.selectWebSearchProvider(.brave, defaults: defaults)
        #expect(chat.settings.webSearchProvider == .brave)
        #expect(!vm.isActionPalettePresented)
        let saved = try #require(defaults.data(forKey: QuickSettings.defaultsKey))
        #expect(try JSONDecoder().decode(QuickSettings.self, from: saved).webSearchProvider == .brave)
    }

    @Test func rendersSharedPickerAndPaletteInBothAppearances() throws {
        let folder = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, appearance, preference) in [
            ("dark", NSAppearance.Name.darkAqua, AppearancePreference.dark),
            ("light", .aqua, .light),
        ] {
            var settings = QuickSettings()
            settings.appearance = preference
            settings.webSearchProvider = .tavily
            let vm = QuickViewModel(settings: settings, webSearchService: ProviderRecordingSearch())
            let card = SettingsCard("Web search") {
                WebSearchProviderRow(viewModel: vm, isFirst: true)
                CardNote { CardText("Used by Quick AI, AI Chat, and the Translator.") }
            }
            .padding(House.Spacing.lg)
            .frame(width: SettingsView.windowSize.width - House.Layout.settingsRail)
            .background(AQDesign.ColorToken.windowSurface)
            try render(card, appearance: appearance, to: folder.appendingPathComponent("web-search-provider-settings-\(name).png"))
            vm.openQuickAI()
            vm.performQuickAISurfaceAction(.searchSettings)
            let palette = QuickActionPalette(viewModel: vm)
                .frame(width: PanelSizing.actionPaletteWidth)
                .padding(House.Spacing.xs)
                .background(AQDesign.ColorToken.raisedSurface)
            try render(palette, appearance: appearance, to: folder.appendingPathComponent("web-search-provider-palette-\(name).png"))
        }
    }

    private func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}

private actor ProviderRecordingSearch: WebSearchServicing {
    var providers: [WebSearchProvider] = []
    func search(_ query: String) async throws -> String {
        try await search(query, provider: .automatic)
    }
    func search(_ query: String, provider: WebSearchProvider) async throws -> String {
        providers.append(provider)
        return "## Source\nURL: https://example.com\nSnippet: A result."
    }
}
