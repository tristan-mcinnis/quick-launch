import Foundation
import AppKit
import SwiftUI
import Testing
@testable import QuickLaunch

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
        settings.webSearchProvider = .bing
        let vm = QuickViewModel(settings: settings, service: ai, webSearchService: search)
        vm.input = "/search release notes"
        await vm.submit()
        #expect(await search.providers == [.bing])
        #expect(vm.output == "Found it")
    }

    @Test func bothChatSurfacesAndTranslatorUseOneChosenProvider() async throws {
        let search = ProviderRecordingSearch()
        let launcher = QuickViewModel(webSearchService: search)
        let chat = QuickViewModel(store: launcher.store, webSearchService: search)
        launcher.settings.webSearchProvider = .google
        for vm in [launcher, chat] {
            let provider = try #require(vm.settings.selectedProvider)
            let service = try #require(vm.makeService(provider: provider, model: "test") as? OpenAICompatibleService)
            let call = try #require(service.webSearch)
            _ = try await call("first query")
        }
        chat.settings.webSearchProvider = .bing
        launcher.apiKeyProvider = { _ in "test-key" }
        let translator = try #require(launcher.makeCurrentService() as? OpenAICompatibleService)
        let lookup = try #require(translator.webSearch)
        _ = try await lookup("translation lookup")
        #expect(await search.providers == [.google, .google, .bing])
    }

    @Test func singleProviderRequestsDoNotMixInCategoryEngines() async throws {
        for provider in WebSearchProvider.allCases {
            let requests = SearchURLRecorder()
            let service = SearXNGSearchService(transport: { url in
                await requests.record(url)
                return Data(#"{"results":[{"title":"Source","url":"https://example.com","content":"An answer"}]}"#.utf8)
            })
            _ = try await service.search("quoted ' query & symbols", provider: provider)
            let url = try #require(await requests.url)
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
            #expect(fields["q"]?.hasPrefix("quoted ' query & symbols") == true)
            switch provider {
            case .automatic:
                #expect(fields["categories"] == "general")
                #expect(fields["engines"] == nil)
            case .google:
                #expect(fields["engines"] == "google cse")
                #expect(fields["categories"] == nil)
            case .bing:
                #expect(fields["engines"] == "bing")
                #expect(fields["categories"] == nil)
            }
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
        vm.actionQuery = "ggl"
        #expect(vm.paletteSearchProviders == [.google])
        #expect(vm.actionPaletteEntryCount == 1)
        let suite = "WebSearchProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        vm.selectWebSearchProvider(.google, defaults: defaults)
        #expect(chat.settings.webSearchProvider == .google)
        #expect(!vm.isActionPalettePresented)
        let saved = try #require(defaults.data(forKey: QuickSettings.defaultsKey))
        #expect(try JSONDecoder().decode(QuickSettings.self, from: saved).webSearchProvider == .google)
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
            settings.webSearchProvider = .bing
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

private actor SearchURLRecorder {
    var url: URL?
    func record(_ url: URL) { self.url = url }
}
