import Testing
import Foundation
@testable import QuickLaunch

@Suite("Model profiles")
struct ModelProfileTests {
    @Test func profileRoundTripsThroughJSON() throws {
        let profile = ModelProfile(
            enabled: false,
            speed: .four,
            intelligence: .two,
            contextWindow: 256_000,
            supportsReasoningEffort: true,
            reasoningEffort: .high
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ModelProfile.self, from: data)

        #expect(decoded == profile)
    }

    @Test func aProfileWithNoDataDefaultsToOnAndUnknown() {
        let profile = ModelProfile()

        #expect(profile.enabled)
        #expect(profile.speed == nil)
        #expect(profile.intelligence == nil)
        #expect(profile.contextWindow == nil)
        #expect(!profile.supportsReasoningEffort)
        #expect(profile.reasoningEffort == .modelDefault)
    }

    @Test func theFirstReasoningOptionIsModelDefault() {
        #expect(ReasoningEffort.allCases.first == .modelDefault)
        #expect(ReasoningEffort.modelDefault.title == "Model default")
    }

    @Test func aModelWithNoCuratedDataReadsAsUnknownRatherThanANumber() {
        let profile = ModelProfile.curated(forModelID: "some-model-nobody-curated")

        #expect(profile.contextWindow == nil)
        #expect(profile.contextWindowLabel == "Unknown")
        #expect(profile.speed == nil)
        #expect(profile.intelligence == nil)
        #expect(!profile.supportsReasoningEffort)
    }

    @Test func theShippedDeepSeekIdsCarryTheirCuratedFacts() {
        let flash = ModelProfile.curated(forModelID: "deepseek-v4-flash")

        #expect(flash.contextWindow == 1_000_000)
        #expect(flash.contextWindowLabel == "1M")
        #expect(flash.supportsReasoningEffort)

        // Ids come back from servers, so the lookup ignores case.
        #expect(ModelProfile.curated(forModelID: "DeepSeek-V4-Flash") == flash)
    }

    @Test func contextWindowLabelsStayCompact() {
        #expect(ModelProfile.contextWindowLabel(nil) == "Unknown")
        #expect(ModelProfile.contextWindowLabel(0) == "Unknown")
        #expect(ModelProfile.contextWindowLabel(8_192) == "8.2K")
        #expect(ModelProfile.contextWindowLabel(128_000) == "128K")
        #expect(ModelProfile.contextWindowLabel(1_000_000) == "1M")
        #expect(ModelProfile.contextWindowLabel(1_500_000) == "1.5M")
    }

    @Test func brandsComeFromTheModelId() {
        #expect(ModelBrand.of(modelID: "deepseek-v4-flash") == "DeepSeek")
        #expect(ModelBrand.of(modelID: "kimi-k3") == "Moonshot")
        #expect(ModelBrand.of(modelID: "sonnet") == "Anthropic")
        #expect(ModelBrand.of(modelID: "deepseek/deepseek-v4-pro") == "DeepSeek")
        #expect(ModelBrand.of(modelID: "xiaomi/mimo-v2.5-pro") == "Xiaomi")
        #expect(ModelBrand.of(modelID: "s1-mini") == "Other")
    }
}

@Suite("Manage models list")
struct ModelListTests {
    private let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func entry(
        _ model: String,
        provider: UUID,
        providerName: String = "Provider",
        speed: ModelRating? = nil,
        intelligence: ModelRating? = nil,
        context: Int? = nil,
        enabled: Bool = true
    ) -> ModelListEntry {
        ModelListEntry(
            providerID: provider,
            providerName: providerName,
            model: model,
            profile: ModelProfile(
                enabled: enabled,
                speed: speed,
                intelligence: intelligence,
                contextWindow: context
            )
        )
    }

    @Test func brandSortGroupsByMakerThenName() {
        let rows = [
            entry("kimi-k3", provider: first),
            entry("deepseek-v4-pro", provider: first),
            entry("sonnet", provider: first),
            entry("deepseek-v4-flash", provider: first),
            entry("mystery-1", provider: first),
        ]

        let sorted = ModelList.sorted(rows, by: .brand).map(\.model)

        #expect(sorted == [
            "sonnet",
            "deepseek-v4-flash",
            "deepseek-v4-pro",
            "kimi-k3",
            "mystery-1",
        ])
    }

    @Test func alphabeticalSortIgnoresMakerAndRatings() {
        let rows = [
            entry("kimi-k3", provider: first, speed: .five),
            entry("deepseek-v4-pro", provider: first, speed: .one),
            entry("gemma-it", provider: first),
        ]

        #expect(ModelList.sorted(rows, by: .alphabetically).map(\.model) == [
            "deepseek-v4-pro",
            "gemma-it",
            "kimi-k3",
        ])
    }

    @Test func speedSortPutsTheFastestFirstAndUnknownLast() {
        let rows = [
            entry("slow", provider: first, speed: .two),
            entry("unrated", provider: first),
            entry("fast", provider: first, speed: .five),
            entry("middling", provider: first, speed: .three),
        ]

        #expect(ModelList.sorted(rows, by: .speed).map(\.model) == [
            "fast",
            "middling",
            "slow",
            "unrated",
        ])
    }

    @Test func intelligenceSortPutsTheStrongestFirstAndUnknownLast() {
        let rows = [
            entry("slight", provider: first, intelligence: .one),
            entry("unrated", provider: first),
            entry("strong", provider: first, intelligence: .five),
        ]

        #expect(ModelList.sorted(rows, by: .intelligence).map(\.model) == [
            "strong",
            "slight",
            "unrated",
        ])
    }

    @Test func contextWindowSortPutsTheLargestFirstAndUnknownLast() {
        let rows = [
            entry("small", provider: first, context: 128_000),
            entry("unrated", provider: first),
            entry("large", provider: first, context: 1_000_000),
            entry("medium", provider: first, context: 256_000),
        ]

        #expect(ModelList.sorted(rows, by: .contextWindow).map(\.model) == [
            "large",
            "medium",
            "small",
            "unrated",
        ])
    }

    @Test func groupingIsOffByDefaultAndKeepsProviderOrderWhenOn() {
        let rows = [
            entry("a", provider: first, providerName: "First"),
            entry("b", provider: second, providerName: "Second"),
            entry("c", provider: first, providerName: "First"),
        ]

        let flat = ModelList.build(rows, query: "", order: .alphabetically, groupsByProvider: false)
        #expect(flat.flat.map(\.model) == ["a", "b", "c"])
        #expect(flat.groups.isEmpty)

        let grouped = ModelList.build(rows, query: "", order: .alphabetically, groupsByProvider: true)
        #expect(grouped.groups.map(\.providerName) == ["First", "Second"])
        #expect(grouped.groups.first?.entries.map(\.model) == ["a", "c"])
        #expect(grouped.groups.last?.entries.map(\.model) == ["b"])
    }

    @Test func searchMatchesModelProviderAndBrand() {
        let rows = [
            entry("deepseek-v4-flash", provider: first, providerName: "DeepSeek API"),
            entry("kimi-k3", provider: second, providerName: "Moonshot"),
        ]

        #expect(ModelList.matching(rows, query: "flash").map(\.model) == ["deepseek-v4-flash"])
        #expect(ModelList.matching(rows, query: "Moonshot").map(\.model) == ["kimi-k3"])
        #expect(ModelList.matching(rows, query: "anthropic").isEmpty)
        #expect(ModelList.matching(rows, query: "").count == 2)
        #expect(ModelList.matching(rows, query: "FLASH").count == 1)
    }
}
