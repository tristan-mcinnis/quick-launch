import AppKit
import Foundation
import SQLite3
import Testing
@testable import QuickLaunch

@Suite("Screen History product evaluation", .serialized)
struct ScreenHistoryProductEvaluationTests {
    @Test("Frozen fixture identity and suite ownership")
    func frozenFixtureIdentityAndSuiteOwnership() throws {
        let receipt = try Self.receipt("SH-FIXTURE")
        let fixture = try ProductFixture.load()

        #expect(fixture.fixtureId == "screen-history-product-v1.1")
        #expect(fixture.schemaVersion == 1)
        #expect(fixture.syntheticOnly)
        #expect(fixture.records.count == fixture.sourceManifest.recordCount)
        #expect(Set(fixture.evaluations.map(\.id)).count == 20)

        let interfaceCases = Set(
            fixture.evaluations
                .filter { $0.category == "accessibility" || $0.category == "interaction_polish" }
                .map(\.id)
        )
        #expect(interfaceCases == ["SH-A01", "SH-A02", "SH-I01", "SH-I02"])
        let renderCases = Set(
            fixture.evaluations
                .filter { $0.id == "SH-P02" }
                .map(\.id)
        )
        #expect(renderCases == ["SH-P02"])
        Self.diagnostic(caseID: "fixture", fields: [
            "records": fixture.records.count,
            "executable_cases": fixture.evaluations.count
                - interfaceCases.count - renderCases.count,
            "integration_cases": interfaceCases.count + renderCases.count,
        ])
        try receipt.finish(measurements: .init(
            localFileCount: 1,
            toolCallCount: 0,
            helperCallCount: 1,
            sourceRootCount: 1
        ))
    }

    @Test("SH-R retrieval rank", arguments: ["SH-R01", "SH-R02", "SH-R03"])
    func retrievalRank(caseID: String) async throws {
        let receipt = try Self.receipt(caseID)
        let fixture = try ProductFixture.load()
        let evaluation = try fixture.evaluation(caseID)
        let workspace = try EvaluationWorkspace()
        let store = try await fixture.makeEligibleStore(in: workspace)
        let parsed = try Self.searchDecision(for: try evaluation.requiredQuery(), fixture: fixture)

        let results = try await store.search(parsed.storageQuery)
        let ids = results.map(\.sourceIdentifier)
        for expectedId in evaluation.expectedIds ?? [] {
            let rank = try #require(ids.firstIndex(of: expectedId).map { $0 + 1 })
            #expect(rank <= (evaluation.maxRank ?? 1))
            Self.diagnostic(caseID: caseID, fields: ["rank": rank, "results": ids.count])
        }
        try receipt.finish(measurements: .init(
            localFileCount: workspace.directory.screenHistoryEvaluationLocalFileCount(),
            toolCallCount: 0,
            helperCallCount: 1,
            sourceRootCount: 1
        ))
    }

    @Test("SH-S surrounding sequence", arguments: ["SH-S01", "SH-S02"])
    func surroundingSequence(caseID: String) async throws {
        let receipt = try Self.receipt(caseID)
        let fixture = try ProductFixture.load()
        let evaluation = try fixture.evaluation(caseID)
        let workspace = try EvaluationWorkspace()
        let store = try await fixture.makeEligibleStore(in: workspace)
        let frames = try await store.search(ScreenHistorySearchQuery(limit: 200))
        let anchor = try #require(frames.first { $0.sourceIdentifier == evaluation.anchorId })

        let sequence = try await store.sequence(containingFrameID: anchor.id, limit: 200)
        let ids = sequence.map(\.sourceIdentifier)
        #expect(ids == evaluation.expectedOrderedIds)
        #expect(Set(ids).isDisjoint(with: evaluation.forbiddenIds ?? []))
        Self.diagnostic(caseID: caseID, fields: ["moments": ids.count])
        try receipt.finish(measurements: .init(
            localFileCount: workspace.directory.screenHistoryEvaluationLocalFileCount(),
            toolCallCount: 0,
            helperCallCount: 2,
            sourceRootCount: 1
        ))
    }

    @Test("SH-F parsed filters", arguments: ["SH-F01", "SH-F02"])
    func parsedFilters(caseID: String) async throws {
        let receipt = try Self.receipt(caseID)
        let fixture = try ProductFixture.load()
        let evaluation = try fixture.evaluation(caseID)
        let workspace = try EvaluationWorkspace()
        let store = try await fixture.makeEligibleStore(in: workspace)
        let parsed = try Self.searchDecision(for: try evaluation.requiredQuery(), fixture: fixture)

        let results = try await store.search(parsed.storageQuery)
        let ids = Set(results.map(\.sourceIdentifier))
        #expect(ids == Set(evaluation.expectedIds ?? []))
        if let bundleId = evaluation.allResultsAppBundleId {
            #expect(results.allSatisfy { $0.bundleIdentifier == bundleId })
        }
        if let after = evaluation.allResultsAfter {
            let boundary = try ProductFixture.date(after)
            #expect(results.allSatisfy { $0.capturedAt >= boundary })
        }
        if let between = evaluation.allResultsBetween {
            let lower = try ProductFixture.date(between[0])
            let upper = try ProductFixture.date(between[1])
            #expect(results.allSatisfy { $0.capturedAt >= lower && $0.capturedAt <= upper })
        }
        Self.diagnostic(caseID: caseID, fields: ["results": results.count, "filters": parsed.hasFilters])
        try receipt.finish(measurements: .init(
            localFileCount: workspace.directory.screenHistoryEvaluationLocalFileCount(),
            toolCallCount: 0,
            helperCallCount: 1,
            sourceRootCount: 1
        ))
    }

    @Test("Visible site token becomes an exact local domain filter")
    func visibleSiteTokenBecomesExactLocalDomainFilter() async throws {
        let receipt = try Self.receipt("SH-F-DOMAIN")
        let fixture = try ProductFixture.load()
        let workspace = try EvaluationWorkspace()
        let store = try await fixture.makeEligibleStore(in: workspace)
        let parsed = try Self.searchDecision(
            for: "starter plan site:research.example",
            fixture: fixture
        )

        #expect(parsed.domain == "research.example")
        #expect(parsed.text == "starter plan")
        let results = try await store.search(parsed.storageQuery)
        #expect(results.map(\.sourceIdentifier) == ["shf-004"])
        #expect(results.allSatisfy { $0.domain == "research.example" })
        Self.diagnostic(caseID: "domain-filter", fields: ["results": results.count, "filters": true])
        try receipt.finish(measurements: .init(
            localFileCount: workspace.directory.screenHistoryEvaluationLocalFileCount(),
            toolCallCount: 0,
            helperCallCount: 1,
            sourceRootCount: 1
        ))
    }

    @Test("SH-E exclusion and routing boundaries", arguments: ["SH-E01", "SH-E02", "SH-E03"])
    func exclusionAndRoutingBoundaries(caseID: String) async throws {
        let receipt = try Self.receipt(caseID)
        let fixture = try ProductFixture.load()
        let evaluation = try fixture.evaluation(caseID)
        let query = try evaluation.requiredQuery()
        let decision = ScreenHistoryQueryParser.parse(
            query,
            now: try fixture.referenceDate(),
            calendar: fixture.calendar
        )

        switch caseID {
        case "SH-E01":
            let workspace = try EvaluationWorkspace()
            let store = try await fixture.makeEligibleStore(in: workspace)
            guard case .search(let parsed) = decision else {
                throw EvaluationError.unexpectedDecision(caseID)
            }
            let results = try await store.search(parsed.storageQuery)
            #expect(results.isEmpty)
            let surfaced = results.map {
                [$0.application, $0.bundleIdentifier, $0.domain, $0.windowTitle, $0.ocrText]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
            }.joined(separator: " ")
            for term in evaluation.forbiddenOutputTerms ?? [] {
                #expect(!surfaced.contains(term.lowercased()))
            }
        case "SH-E02":
            #expect(decision == .refuseFuture)
            #expect(evaluation.expectedRefusal == "future_screen_unknown")
        case "SH-E03":
            #expect(decision == .routeVaultSearch)
            #expect(evaluation.expectedRoute == "vault_search")
        default:
            throw EvaluationError.unknownCase(caseID)
        }
        Self.diagnostic(caseID: caseID, fields: ["screen_results": 0])
        try receipt.finish(measurements: .init(
            localFileCount: caseID == "SH-E01" ? 1 : 0,
            toolCallCount: 0,
            helperCallCount: caseID == "SH-E01" ? 1 : 0,
            sourceRootCount: caseID == "SH-E01" ? 1 : 0
        ))
    }

    @Test("SH-N01 local retrieval has no process or network hooks")
    @MainActor
    func localRetrievalHasNoProcessOrNetworkHooks() async throws {
        let receipt = try Self.receipt("SH-N01")
        let fixture = try ProductFixture.load()
        let evaluation = try fixture.evaluation("SH-N01")
        let workspace = try EvaluationWorkspace()
        let store = try await fixture.makeEligibleStore(in: workspace)
        let countingStore = CountingEvaluationScreenHistoryStore(store: store)
        let viewModel = QuickViewModel(screenHistoryStore: countingStore)

        viewModel.enterCatalog(.screenHistory)
        await viewModel.loadScreenHistory(
            query: try evaluation.requiredQuery(),
            now: try fixture.referenceDate(),
            calendar: fixture.calendar
        )
        #expect(Set(viewModel.screenHistoryFrames.map(\.sourceIdentifier)) == Set(evaluation.expectedIds ?? []))
        #expect(viewModel.showsDetailPane)
        #expect(viewModel.detailItem?.kind == .screenHistory)
        #expect(await countingStore.searchCalls == 2)

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceFiles = [
            "Sources/Services/ScreenHistoryStore.swift",
            "Sources/Services/CoastLegacyReader.swift",
            "Sources/Services/ScreenHistorySearch.swift",
            "Sources/Views/CatalogPanes.swift",
        ]
        let forbiddenHooks = [
            "URLSession", "NWConnection", "getaddrinfo", "CFNetwork",
            "Process(", "ProcessInfo.processInfo.environment", "ssh ", "telemetry",
        ]
        var forbiddenHookHits = 0
        for relativePath in sourceFiles {
            let source = try String(
                contentsOf: repository.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            for hook in forbiddenHooks {
                if source.localizedCaseInsensitiveContains(hook) {
                    forbiddenHookHits += 1
                }
            }
        }
        #expect(forbiddenHookHits == 0)
        let runtimeNetworkDenied = ProcessInfo.processInfo.environment[
            "SCREEN_HISTORY_NETWORK_DENIED"
        ] == "1"
        Self.diagnostic(caseID: "SH-N01", fields: [
            "owned_store_calls": await countingStore.searchCalls,
            "coast_store_calls": 0,
            "result_count": viewModel.screenHistoryFrames.count,
            "forbidden_hook_hits": forbiddenHookHits,
            "runtime_network_denied": runtimeNetworkDenied,
            "files_scanned": sourceFiles.count,
        ])
        try receipt.finish(measurements: .init(
            localFileCount: workspace.directory.screenHistoryEvaluationLocalFileCount()
                + sourceFiles.count,
            toolCallCount: 0,
            helperCallCount: await countingStore.searchCalls,
            network: .staticScan(
                observedCallCount: forbiddenHookHits,
                runtimeDenied: runtimeNetworkDenied
            ),
            sourceRootCount: 1
        ))
    }

    @Test("SH-M migration reconciliation", arguments: ["SH-M01", "SH-M02", "SH-M03"])
    func migrationReconciliation(caseID: String) async throws {
        let receipt = try Self.receipt(caseID)
        let fixture = try ProductFixture.load()
        let evaluation = try fixture.evaluation(caseID)
        let legacy = try SyntheticCoastDatabase(records: fixture.records)
        let reader = CoastLegacyReader(databaseURL: legacy.databaseURL, contentRootURL: legacy.directory)
        let referenceNow = try fixture.referenceDate()

        switch caseID {
        case "SH-M01":
            let expected = try #require(evaluation.expected)
            let workspace = try EvaluationWorkspace()
            let store = try SQLiteScreenHistoryStore(databaseURL: workspace.databaseURL)
            let service = ScreenHistoryMigrationService(
                reader: reader,
                store: store,
                policy: Self.migrationPolicy,
                clock: { referenceNow }
            )
            let result = try await service.migrate()
            #expect(result.source == expected.source)
            #expect(result.imported == expected.imported)
            #expect(result.excluded == expected.excluded)
            #expect(result.invalid == expected.invalid)
            #expect(result.reconciles)
            #expect(result.mappingCount == expected.imported)
            #expect(result.ledgerCount == expected.source)
            #expect(try await store.count() == expected.imported)
            Self.diagnostic(caseID: caseID, fields: [
                "source": result.source,
                "imported": result.imported,
                "excluded": result.excluded,
                "invalid": result.invalid,
                "mapping_count": result.mappingCount,
                "ledger_count": result.ledgerCount,
            ])
            try receipt.finish(measurements: .init(
                localFileCount: legacy.directory.screenHistoryEvaluationLocalFileCount()
                    + workspace.directory.screenHistoryEvaluationLocalFileCount(),
                toolCallCount: 0,
                helperCallCount: 1,
                sourceRootCount: 1
            ))
        case "SH-M02":
            let workspace = try EvaluationWorkspace()
            let store = try SQLiteScreenHistoryStore(databaseURL: workspace.databaseURL)
            let service = ScreenHistoryMigrationService(
                reader: reader,
                store: store,
                policy: Self.migrationPolicy,
                clock: { referenceNow }
            )
            _ = try await service.migrate()
            let before = try await Self.identitySnapshot(store)
            let repeated = try await service.migrate()
            let after = try await Self.identitySnapshot(store)
            #expect(repeated.ownedRowDelta == evaluation.expectedOwnedRowDelta)
            #expect(repeated.hashDelta == evaluation.expectedHashDelta)
            #expect(repeated.mappingCount == evaluation.expectedMappingCount)
            #expect(after == before)
            Self.diagnostic(caseID: caseID, fields: [
                "mapping_count": repeated.mappingCount,
                "row_delta": repeated.ownedRowDelta,
                "hash_delta": repeated.hashDelta,
            ])
            try receipt.finish(measurements: .init(
                localFileCount: legacy.directory.screenHistoryEvaluationLocalFileCount()
                    + workspace.directory.screenHistoryEvaluationLocalFileCount(),
                toolCallCount: 0,
                helperCallCount: 2,
                sourceRootCount: 1
            ))
        case "SH-M03":
            let resumeAfter = try #require(Self.numericLegacyId(evaluation.resumeAfterLegacyId))
            let cleanWorkspace = try EvaluationWorkspace()
            let cleanStore = try SQLiteScreenHistoryStore(databaseURL: cleanWorkspace.databaseURL)
            let cleanService = ScreenHistoryMigrationService(
                reader: reader,
                store: cleanStore,
                policy: Self.migrationPolicy,
                clock: { referenceNow }
            )
            _ = try await cleanService.migrate()

            let resumedWorkspace = try EvaluationWorkspace()
            let resumedStore = try SQLiteScreenHistoryStore(databaseURL: resumedWorkspace.databaseURL)
            let resumedService = ScreenHistoryMigrationService(
                reader: reader,
                store: resumedStore,
                policy: Self.migrationPolicy,
                clock: { referenceNow }
            )
            let first = try await resumedService.migrate(maximumSourceRows: 7)
            #expect(first.lastLegacyFrameID == resumeAfter)
            let remaining = try await resumedService.migrate(afterLegacyFrameID: resumeAfter)

            let clean = try await Self.identitySnapshot(cleanStore)
            let resumed = try await Self.identitySnapshot(resumedStore)
            #expect(resumed == clean)
            let idMap = Dictionary(uniqueKeysWithValues: fixture.records.compactMap { record in
                Self.numericLegacyId(record.legacyId).map { (String($0), record.id) }
            })
            let finalIds = Set(resumed.compactMap { idMap[$0.sourceIdentifier] })
            #expect(finalIds == Set(evaluation.expectedFinalOwnedIds ?? []))
            #expect(evaluation.expectedMatchesCleanImport == true)
            Self.diagnostic(caseID: caseID, fields: [
                "first_source": first.source,
                "remaining_source": remaining.source,
                "final_owned": resumed.count,
                "mapping_count": remaining.mappingCount,
            ])
            try receipt.finish(measurements: .init(
                localFileCount: legacy.directory.screenHistoryEvaluationLocalFileCount()
                    + cleanWorkspace.directory.screenHistoryEvaluationLocalFileCount()
                    + resumedWorkspace.directory.screenHistoryEvaluationLocalFileCount(),
                toolCallCount: 0,
                helperCallCount: 3,
                sourceRootCount: 1
            ))
        default:
            throw EvaluationError.unknownCase(caseID)
        }
    }

    @Test("SH-P01 50,000-record FTS latency")
    func fiftyThousandRecordFTSLatency() async throws {
        let receipt = try Self.receipt("SH-P01")
        let fixture = try ProductFixture.load()
        let evaluation = try fixture.evaluation("SH-P01")
        let performance = fixture.performanceCorpus
        #expect(evaluation.corpusRecordCount == performance.recordCount)
        let catalogSamples = await MainActor.run { () -> [Double] in
            var samples: [Double] = []
            for _ in 0..<40 {
                let viewModel = QuickViewModel()
                let start = DispatchTime.now().uptimeNanoseconds
                viewModel.enterCatalog(.screenHistory)
                let end = DispatchTime.now().uptimeNanoseconds
                samples.append(Double(end - start) / 1_000_000)
                viewModel.leaveCatalog()
            }
            return samples
        }
        let catalogP95 = Self.percentile(catalogSamples, 0.95)
        #expect(catalogP95 <= Double(evaluation.expectedCatalogOpenP95Ms ?? 100))
        let workspace = try EvaluationWorkspace()
        let store = try SQLiteScreenHistoryStore(databaseURL: workspace.databaseURL)

        let records = (0..<performance.recordCount).map { index in
            let target = index == 24_825 || index == 49_825
            return ScreenHistoryFrameInput(
                sourceIdentifier: String(format: "perf-%05d", index),
                capturedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index)),
                application: "Synthetic Editor",
                bundleIdentifier: "test.synthetic.editor",
                domain: "example.test",
                windowTitle: "Synthetic record \(index)",
                ocrText: target
                    ? "coral variance chart deterministic target"
                    : "synthetic background record \(index) seed \(performance.generationSeed)",
                byteCount: 1
            )
        }
        _ = try await store.record(records)
        #expect(try await store.count() == performance.recordCount)

        let query = ScreenHistorySearchQuery(text: try evaluation.requiredQuery(), limit: 50)
        for _ in 0..<5 { _ = try await store.search(query) }
        var samples: [Double] = []
        var resultIDs: [String] = []
        for _ in 0..<40 {
            let start = DispatchTime.now().uptimeNanoseconds
            let results = try await store.search(query)
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(end - start) / 1_000_000)
            resultIDs = results.map(\.sourceIdentifier)
        }

        let p95 = Self.percentile(samples, 0.95)
        let p99 = Self.percentile(samples, 0.99)
        #expect(resultIDs == ["perf-49825", "perf-24825"])
        #expect(p95 <= Double(evaluation.expectedSearchP95Ms ?? performance.searchP95Ms))
        #expect(p99 <= Double(evaluation.expectedSearchP99Ms ?? performance.searchP99Ms))
        Self.diagnostic(caseID: "SH-P01", fields: [
            "corpus": performance.recordCount, "samples": samples.count,
            "catalog_open_p95_ms": String(format: "%.3f", catalogP95),
            "p95_ms": String(format: "%.3f", p95), "p99_ms": String(format: "%.3f", p99),
            "results": resultIDs.count,
        ])
        try receipt.finish(measurements: .init(
            localFileCount: workspace.directory.screenHistoryEvaluationLocalFileCount(),
            toolCallCount: 0,
            helperCallCount: 46,
            sourceRootCount: 1
        ))
    }

    @Test("SH-P02 local preview latency keeps selection stable")
    @MainActor
    func localPreviewLatencyKeepsSelectionStable() async throws {
        let receipt = try Self.receipt("SH-P02")
        let fixture = try ProductFixture.load()
        let evaluation = try fixture.evaluation("SH-P02")
        let recordID = try #require(evaluation.recordId)
        let expectedP95 = try #require(evaluation.expectedPreviewP95Ms)
        #expect(evaluation.selectionMustRemainStable == true)

        let workspace = try EvaluationWorkspace()
        let imageURL = workspace.directory.appendingPathComponent("synthetic-preview.png")
        try Self.writeSyntheticPreview(to: imageURL)
        let store = try SQLiteScreenHistoryStore(databaseURL: workspace.databaseURL)
        let inputs = try fixture.records.filter(\.isEligible).map { record in
            try record.storeInput(imageLocator: record.id == recordID ? imageURL.path : nil)
        }
        _ = try await store.record(inputs)

        let viewModel = QuickViewModel(screenHistoryStore: store)
        viewModel.catalogScope = .screenHistory
        await viewModel.loadScreenHistory(query: "coral variance chart")
        let selectedIndex = try #require(viewModel.screenHistoryItems.firstIndex { item in
            viewModel.screenHistoryFrame(for: item)?.sourceIdentifier == recordID
        })
        viewModel.applicationSelectionIndex = selectedIndex

        let sampleCount = 40
        var samples: [Double] = []
        samples.reserveCapacity(sampleCount)
        var selectionStayedStable = true
        for _ in 0..<sampleCount {
            let start = DispatchTime.now().uptimeNanoseconds
            let preview = ScreenshotThumbnailCache.thumbnail(forPath: imageURL.path)
            let end = DispatchTime.now().uptimeNanoseconds
            #expect(preview != nil)
            samples.append(Double(end - start) / 1_000_000)

            let items = viewModel.screenHistoryItems
            guard items.indices.contains(viewModel.applicationSelectionIndex) else {
                selectionStayedStable = false
                continue
            }
            let selectedFrame = viewModel.screenHistoryFrame(
                for: items[viewModel.applicationSelectionIndex]
            )
            selectionStayedStable = selectionStayedStable
                && selectedFrame?.sourceIdentifier == recordID
        }

        let p95 = Self.percentile(samples, 0.95)
        #expect(samples.count == sampleCount)
        #expect(p95 <= Double(expectedP95))
        #expect(selectionStayedStable)
        Self.diagnostic(caseID: "SH-P02", fields: [
            "cold_ms": String(format: "%.3f", samples[0]),
            "p95_ms": String(format: "%.3f", p95),
            "samples": samples.count,
            "selection_stable": selectionStayedStable,
        ])
        try receipt.finish(measurements: .init(
            localFileCount: workspace.directory.screenHistoryEvaluationLocalFileCount(),
            toolCallCount: 0,
            helperCallCount: 41,
            sourceRootCount: 1
        ))
    }

    private static func receipt(_ caseID: String) throws -> ScreenHistoryEvaluationRun {
        try ScreenHistoryEvaluationReceiptWriter.shared.begin(suite: .product, caseID: caseID)
    }

    private static func searchDecision(
        for query: String,
        fixture: ProductFixture
    ) throws -> ScreenHistoryParsedQuery {
        let decision = ScreenHistoryQueryParser.parse(
            query,
            now: try fixture.referenceDate(),
            calendar: fixture.calendar
        )
        guard case .search(let parsed) = decision else {
            throw EvaluationError.unexpectedDecision(query)
        }
        return parsed
    }

    private static func percentile(_ samples: [Double], _ fraction: Double) -> Double {
        guard !samples.isEmpty else { return .infinity }
        let sorted = samples.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))
        return sorted[index]
    }

    @MainActor
    private static func writeSyntheticPreview(to url: URL) throws {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1_280,
            pixelsHigh: 720,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw EvaluationError.syntheticPreview
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.12, green: 0.28, blue: 0.46, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1_280, height: 720).fill()
        NSColor(calibratedRed: 0.82, green: 0.48, blue: 0.32, alpha: 1).setFill()
        NSRect(x: 96, y: 96, width: 1_088, height: 528).fill()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw EvaluationError.syntheticPreview
        }
        try png.write(to: url, options: .atomic)
    }

    private static let migrationPolicy = ScreenHistoryMigrationPolicy(
        financeDomains: ["bank.example"]
    )

    private static func numericLegacyId(_ value: String?) -> Int64? {
        guard let value else { return nil }
        return Int64(value.replacingOccurrences(of: "legacy-", with: ""))
    }

    private static func identitySnapshot(
        _ store: SQLiteScreenHistoryStore
    ) async throws -> [FrameIdentity] {
        try await store.search(ScreenHistorySearchQuery(limit: 200))
            .map { FrameIdentity(sourceIdentifier: $0.sourceIdentifier, contentHash: $0.contentHash) }
            .sorted { $0.sourceIdentifier < $1.sourceIdentifier }
    }

    private static func diagnostic(caseID: String, fields: [String: Any]) {
        let values = fields.keys.sorted().map { "\($0)=\(fields[$0]!)" }.joined(separator: " ")
        print("screen-history-eval case=\(caseID) \(values)")
    }
}

private struct ProductFixture: Decodable {
    let fixtureId: String
    let schemaVersion: Int
    let syntheticOnly: Bool
    let timezone: String
    let referenceNow: String
    let sourceManifest: SourceManifest
    let performanceCorpus: PerformanceCorpus
    let records: [FixtureRecord]
    let evaluations: [EvaluationCase]

    private enum CodingKeys: String, CodingKey {
        case fixtureId
        case schemaVersion
        case syntheticOnly
        case timezone
        case referenceNow
        case sourceManifest
        case performanceCorpus
        case records
        case evaluations = "cases"
    }

    static func load() throws -> ProductFixture {
        guard let url = Bundle.module.url(
            forResource: "screen-history-product-cases",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) ?? Bundle.module.url(forResource: "screen-history-product-cases", withExtension: "json") else {
            throw EvaluationError.fixtureMissing
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ProductFixture.self, from: Data(contentsOf: url))
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 8 * 3_600)!
        return calendar
    }

    func referenceDate() throws -> Date { try Self.date(referenceNow) }

    func evaluation(_ id: String) throws -> EvaluationCase {
        guard let evaluation = evaluations.first(where: { $0.id == id }) else {
            throw EvaluationError.unknownCase(id)
        }
        return evaluation
    }

    func makeEligibleStore(in workspace: EvaluationWorkspace) async throws -> SQLiteScreenHistoryStore {
        let store = try SQLiteScreenHistoryStore(databaseURL: workspace.databaseURL)
        let inputs = try records.filter(\.isEligible).map { try $0.storeInput }
        _ = try await store.record(inputs)
        return store
    }

    static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
        guard let date = formatter.date(from: value) else { throw EvaluationError.invalidDate(value) }
        return date
    }
}

private struct SourceManifest: Decodable {
    let recordCount: Int
    let eligibleCount: Int
    let excludedCount: Int
    let invalidCount: Int
}

private struct PerformanceCorpus: Decodable {
    let recordCount: Int
    let generationSeed: Int
    let searchP95Ms: Int
    let searchP99Ms: Int
}

private struct FixtureRecord: Decodable {
    let id: String
    let legacyId: String
    let capturedAt: String
    let appBundleId: String
    let appName: String
    let windowTitle: String
    let domain: String?
    let ocrText: String
    let sequenceId: String
    let sequenceOrdinal: Int
    let mediaRef: String
    let contentHash: String
    let eligibility: String

    var isEligible: Bool { eligibility == "eligible" }

    var storeInput: ScreenHistoryFrameInput {
        get throws { try storeInput(imageLocator: nil) }
    }

    func storeInput(imageLocator: String?) throws -> ScreenHistoryFrameInput {
        ScreenHistoryFrameInput(
            source: .coast,
            sourceIdentifier: id,
            capturedAt: try ProductFixture.date(capturedAt),
            application: appName,
            bundleIdentifier: appBundleId,
            domain: domain,
            windowTitle: windowTitle,
            ocrText: ocrText,
            imageLocator: imageLocator,
            byteCount: 1,
            sequenceIdentifier: sequenceId,
            sequenceOrdinal: sequenceOrdinal,
            contentHash: contentHash
        )
    }
}

private struct EvaluationCase: Decodable {
    let id: String
    let category: String
    let operation: String
    let query: String?
    let expectedIds: [String]?
    let maxRank: Int?
    let anchorId: String?
    let expectedOrderedIds: [String]?
    let forbiddenIds: [String]?
    let allResultsAppBundleId: String?
    let allResultsAfter: String?
    let allResultsBetween: [String]?
    let forbiddenOutputTerms: [String]?
    let expectedRefusal: String?
    let expectedRoute: String?
    let expected: MigrationExpected?
    let expectedOwnedRowDelta: Int?
    let expectedHashDelta: Int?
    let expectedMappingCount: Int?
    let resumeAfterLegacyId: String?
    let expectedFinalOwnedIds: [String]?
    let expectedMatchesCleanImport: Bool?
    let corpusRecordCount: Int?
    let expectedCatalogOpenP95Ms: Int?
    let expectedSearchP95Ms: Int?
    let expectedSearchP99Ms: Int?
    let recordId: String?
    let expectedPreviewP95Ms: Int?
    let selectionMustRemainStable: Bool?

    func requiredQuery() throws -> String {
        guard let query else { throw EvaluationError.missingField("\(id).query") }
        return query
    }
}

private struct MigrationExpected: Decodable {
    let source: Int
    let imported: Int
    let excluded: Int
    let invalid: Int
}

private struct FrameIdentity: Equatable {
    let sourceIdentifier: String
    let contentHash: String
}

private final class EvaluationWorkspace: @unchecked Sendable {
    let directory: URL
    let databaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-screen-history-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("screen-history.sqlite3")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class SyntheticCoastDatabase: @unchecked Sendable {
    let directory: URL
    let databaseURL: URL
    private var database: OpaquePointer?

    init(records: [FixtureRecord]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-coast-product-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("rem.db")
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw EvaluationError.sqlite("open")
        }
        try execute("""
            CREATE TABLE application(id INTEGER PRIMARY KEY, bundle_id TEXT, display_name TEXT);
            CREATE TABLE domain(id INTEGER PRIMARY KEY, normalized_domain TEXT);
            CREATE TABLE video(id INTEGER PRIMARY KEY, path TEXT, num_frames INTEGER, size_bytes INTEGER);
            CREATE TABLE segment(id INTEGER PRIMARY KEY, application INTEGER, domain INTEGER);
            CREATE TABLE frame(
                id INTEGER PRIMARY KEY, timestamp INTEGER, video INTEGER, video_index INTEGER,
                image_path TEXT, foreground TEXT, background TEXT, title TEXT, segment INTEGER,
                capture_display_x REAL, capture_display_y REAL,
                capture_display_width REAL, capture_display_height REAL
            );
            CREATE VIRTUAL TABLE ocr_fts USING fts5(
                foreground, background, title, content='frame', content_rowid='id'
            );
            CREATE TRIGGER frame_ai AFTER INSERT ON frame BEGIN
                INSERT INTO ocr_fts(rowid, foreground, background, title)
                VALUES (new.id, new.foreground, new.background, new.title);
            END;
            """)
        for (position, record) in records.enumerated() {
            try insert(record, relationID: position + 1)
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func insert(_ record: FixtureRecord, relationID: Int) throws {
        guard let frameId = Int64(record.legacyId.replacingOccurrences(of: "legacy-", with: "")) else {
            throw EvaluationError.missingField("legacy_id")
        }
        let capturedAt = try ProductFixture.date(record.capturedAt).timeIntervalSince1970 * 1_000
        try prepared(
            "INSERT INTO application(id, bundle_id, display_name) VALUES (?, ?, ?);",
            [.integer(Int64(relationID)), .text(record.appBundleId), .text(record.appName)]
        )
        if let domain = record.domain {
            try prepared(
                "INSERT INTO domain(id, normalized_domain) VALUES (?, ?);",
                [.integer(Int64(relationID)), .text(domain)]
            )
        }
        try prepared(
            "INSERT INTO video(id, path, num_frames, size_bytes) VALUES (?, ?, 1, 1);",
            [.integer(Int64(relationID)), .text("media/segment-\(relationID).mp4")]
        )
        try prepared(
            "INSERT INTO segment(id, application, domain) VALUES (?, ?, ?);",
            [
                .integer(Int64(relationID)), .integer(Int64(relationID)),
                record.domain == nil ? .null : .integer(Int64(relationID)),
            ]
        )
        try prepared(
            """
            INSERT INTO frame(
                id, timestamp, video, video_index, image_path,
                foreground, background, title, segment
            ) VALUES (?, ?, ?, 0, NULL, ?, '', ?, ?);
            """,
            [
                .integer(frameId), .number(capturedAt), .integer(Int64(relationID)),
                .text(record.ocrText), .text(record.windowTitle), .integer(Int64(relationID)),
            ]
        )
    }

    private enum Value {
        case integer(Int64)
        case number(Double)
        case text(String)
        case null
    }

    private func prepared(_ sql: String, _ values: [Value]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw EvaluationError.sqlite("prepare")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .number(let number): result = sqlite3_bind_double(statement, index, number)
            case .text(let text):
                result = text.withCString {
                    sqlite3_bind_text(
                        statement,
                        index,
                        $0,
                        -1,
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw EvaluationError.sqlite("bind") }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw EvaluationError.sqlite("step") }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            sqlite3_free(error)
            throw EvaluationError.sqlite("schema")
        }
    }
}

private actor CountingEvaluationScreenHistoryStore: ScreenHistoryStoring {
    private let store: SQLiteScreenHistoryStore
    private(set) var searchCalls = 0

    init(store: SQLiteScreenHistoryStore) {
        self.store = store
    }

    func record(_ frame: ScreenHistoryFrameInput) async throws -> Int64 {
        try await store.record(frame)
    }

    func record(_ frames: [ScreenHistoryFrameInput]) async throws -> Int {
        try await store.record(frames)
    }

    func search(_ query: ScreenHistorySearchQuery) async throws -> [ScreenHistoryFrame] {
        searchCalls += 1
        return try await store.search(query)
    }

    func sequence(containingFrameID frameID: Int64, limit: Int) async throws -> [ScreenHistoryFrame] {
        try await store.sequence(containingFrameID: frameID, limit: limit)
    }

    func count() async throws -> Int {
        try await store.count()
    }

    func prune(policy: ScreenHistoryRetentionPolicy, now: Date) async throws -> ScreenHistoryPruneResult {
        try await store.prune(policy: policy, now: now)
    }
}

private enum EvaluationError: Error {
    case fixtureMissing
    case unknownCase(String)
    case missingField(String)
    case invalidDate(String)
    case unexpectedDecision(String)
    case sqlite(String)
    case syntheticPreview
}
