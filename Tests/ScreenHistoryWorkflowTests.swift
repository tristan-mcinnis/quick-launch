import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screen History workflow", .serialized)
@MainActor
struct ScreenHistoryWorkflowTests {
    @Test func rootHasOneCatalogAndDoesNotReadEitherStore() async {
        let owned = FakeScreenHistoryStore(rows: [Self.frame(id: "owned-1")])
        let coast = FakeCoastReader(rows: [Self.frame(id: "coast-1", source: .coast)])
        let vm = QuickViewModel(screenHistoryStore: owned, coastLegacyReader: coast)

        let roots = vm.launcherMatches.filter {
            guard case .catalog(.screenHistory, _) = $0 else { return false }
            return true
        }
        #expect(roots.count == 1)
        #expect(await owned.searchCalls == 0)
        #expect(await coast.searchCalls == 0)
        #expect(await coast.pageCalls == 0)
    }

    @Test func localSearchMergesStableOwnedAndCoastRowsWithSourceCues() async {
        let owned = FakeScreenHistoryStore(rows: [Self.frame(id: "owned-1", text: "Coral variance chart")])
        let coast = FakeCoastReader(rows: [Self.frame(id: "coast-1", source: .coast, text: "Coral source table")])
        let vm = QuickViewModel(screenHistoryStore: owned, coastLegacyReader: coast)
        vm.enterCatalog(.screenHistory)
        await vm.screenHistory.load(query: "coral")

        #expect(vm.screenHistory.items.count == 2)
        #expect(vm.screenHistory.items.allSatisfy { $0.title == "Project Juniper" })
        #expect(vm.screenHistory.items.contains { $0.keywords.contains("Owned") })
        #expect(vm.screenHistory.items.contains { $0.keywords.contains("Coast") })
        #expect(vm.screenHistory.items.contains { $0.detail.hasPrefix("Owned · Seen ") })
        #expect(vm.screenHistory.items.contains { $0.detail.hasPrefix("Coast · Seen ") })
        #expect(vm.screenHistory.items.allSatisfy { $0.kind == .screenHistory })
        #expect(vm.screenHistory.loadState == .ready)
        #expect(vm.footerHints.contains { $0.label == "Copy text" && $0.keys == ["⌘", "↩"] })
        vm.handleCommandK()
        #expect(vm.isCatalogActionPanePresented)
        #expect(vm.contextualCatalogItem?.kind == .screenHistory)
    }

    @Test func futureAndCurrentTruthQueriesDoNotReadStores() async {
        let owned = FakeScreenHistoryStore(rows: [])
        let vm = QuickViewModel(screenHistoryStore: owned)
        vm.enterCatalog(.screenHistory)
        await vm.screenHistory.load(query: "what will be on my screen tomorrow")
        #expect(vm.screenHistory.loadState == .refusedFuture)
        await vm.screenHistory.load(query: "where does Project Juniper stand now?")
        #expect(vm.screenHistory.loadState == .routedToVaultSearch)
        #expect(await owned.searchCalls == 0)
    }

    @Test func parsedFiltersAndYesterdayAreVisibleAndLocal() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-25T04:00:00Z"))
        guard case .search(let parsed) = ScreenHistoryQueryParser.parse(
            "variance chart app:Keynote site:research.example after:2026-08-24 before:2026-08-25",
            now: now,
            calendar: calendar
        ) else { Issue.record("Expected search"); return }
        #expect(parsed.text == "variance chart")
        #expect(parsed.application == "Keynote")
        #expect(parsed.domain == "research.example")
        #expect(parsed.from != nil)
        #expect(parsed.through != nil)
        #expect(parsed.hasFilters)

        guard case .search(let yesterday) = ScreenHistoryQueryParser.parse(
            "Blue Orchard yesterday", now: now, calendar: calendar
        ) else { Issue.record("Expected yesterday search"); return }
        #expect(yesterday.text == "Blue Orchard")
        #expect(yesterday.from != nil)
        #expect(yesterday.through != nil)
    }

    @Test func returnOpensTimelineAndBackspaceReturnsToResults() async {
        let anchor = Self.frame(id: "2", capturedAt: 120)
        let rows = [
            Self.frame(id: "1", capturedAt: 0),
            anchor,
            Self.frame(id: "3", capturedAt: 240),
            Self.frame(id: "4", capturedAt: 1_200),
        ]
        let owned = FakeScreenHistoryStore(rows: rows)
        let vm = QuickViewModel(screenHistoryStore: owned)
        vm.enterCatalog(.screenHistory)
        await vm.screenHistory.load(query: "coral")
        await vm.screenHistory.openSequence(for: anchor)

        #expect(vm.screenHistory.showsTimeline)
        #expect(vm.screenHistory.timelineFrames.map(\.sourceIdentifier) == ["1", "2", "3"])
        vm.input = ""
        #expect(vm.popLayerForEmptyBackspace())
        #expect(!vm.screenHistory.showsTimeline)
        #expect(vm.catalogScope == .screenHistory)
    }

    @Test func productionTimelineNeverLeaksAnAdjacentSequence() async {
        let anchor = Self.frame(
            id: "2",
            source: .coast,
            capturedAt: 120,
            sequenceIdentifier: "coast-segment-a",
            sequenceOrdinal: 2
        )
        let rows = [
            Self.frame(id: "1", source: .coast, capturedAt: 60, sequenceIdentifier: "coast-segment-a", sequenceOrdinal: 1),
            anchor,
            Self.frame(id: "3", source: .coast, capturedAt: 180, sequenceIdentifier: "coast-segment-a", sequenceOrdinal: 3),
            Self.frame(id: "4", source: .coast, capturedAt: 150, sequenceIdentifier: "coast-segment-b", sequenceOrdinal: 1),
        ]
        let vm = QuickViewModel(screenHistoryStore: FakeScreenHistoryStore(rows: rows))
        vm.catalogScope = .screenHistory

        await vm.screenHistory.openSequence(for: anchor)

        #expect(vm.screenHistory.timelineFrames.map(\.sourceIdentifier) == ["1", "2", "3"])
    }

    @Test func actionTableUsesTheLauncherGrammarAndVaultWriteUsesConfirmedForm() async throws {
        let frame = Self.frame(id: "one", image: "/tmp/not-owned.jpg")
        let store = FakeScreenHistoryStore(rows: [frame])
        let saver = FakeScreenHistoryVaultSaver()
        let vm = QuickViewModel(screenHistoryStore: store, screenHistoryVaultSaver: saver)
        vm.enterCatalog(.screenHistory)
        await vm.screenHistory.load(query: "coral")
        let item = try #require(vm.screenHistory.items.first)
        let actions = ItemActionCatalog.actions(for: .item(item), pasteTarget: nil)
        #expect(actions.map(\.title).contains("Open moment"))
        #expect(actions.map(\.title).contains("Show timeline"))
        #expect(actions.map(\.title).contains("Copy text"))
        #expect(actions.map(\.title).contains("Save to Vault"))
        #expect(actions.first?.title == "Open moment")
        #expect(actions.first?.systemImage == "clock")
        #expect(actions.first { $0.title == "Copy text" }?.shortcut == .commandReturn)
        let save = try #require(actions.first { $0.kind == .saveToVault })
        await vm.perform(save, on: .item(item))
        #expect(vm.activeItemActionForm == .screenHistorySave)
        #expect(await saver.savedRecordIDs.isEmpty)
        let preview = ScreenHistorySavePreview(frame: frame)
        #expect(preview.source == "Owned")
        #expect(preview.localRecordID == "one")
        #expect(preview.application == "Keynote")
        #expect(preview.window == "Project Juniper")
        #expect(!preview.ocrExcerpt.contains("/tmp/not-owned.jpg"))
        #expect(await vm.screenHistory.saveNote(
            for: .item(item),
            projectSlug: "project-juniper",
            note: "Follow up with the team"
        ))
        #expect(await saver.savedRecordIDs == ["one"])
        #expect(await saver.savedProjectSlugs == ["project-juniper"])
        #expect(await saver.savedNotes == ["Follow up with the team"])
        #expect(vm.screenHistory.resultAnnouncement == "Saved this screen moment to Vault triage.")
    }

    @Test func settingsKeepSearchAndCaptureConsentSeparate() {
        let settings = QuickSettings()
        #expect(settings.searchLegacyCoastHistory)
        #expect(!settings.screenHistoryCaptureEnabled)
        #expect(!settings.screenHistoryCaptureConfirmed)
        #expect(settings.screenHistoryRetentionDays == 30)
        #expect(settings.screenHistoryStorageCapGB == 20)
        #expect(!settings.screenHistoryExcludedBundleIDs.isEmpty)
        #expect(settings.screenHistoryExcludedDomains == ScreenHistoryCaptureConfiguration.safeDefaultExcludedDomains.sorted())
    }

    @Test("SH-A01 keyboard flow has no Screen History dead ends")
    func shA01KeyboardFlow() async throws {
        let rows = [
            Self.frame(id: "1", capturedAt: 100, text: "coral first"),
            Self.frame(id: "2", capturedAt: 200, text: "coral second"),
        ]
        let vm = QuickViewModel(screenHistoryStore: FakeScreenHistoryStore(rows: rows))
        let root = try #require(vm.launcherMatches.first {
            guard case .catalog(.screenHistory, _) = $0 else { return false }
            return true
        })
        await vm.performLauncherResult(root)
        vm.input = "coral"
        await vm.screenHistory.load(query: vm.input)
        vm.moveSelectionVertically(1)
        #expect(vm.applicationSelectionIndex == 1)
        #expect(vm.screenHistory.resultAnnouncement.contains("selected"))

        let selected = try #require(vm.screenHistory.frame(for: vm.screenHistory.items[1]))
        await vm.screenHistory.openSequence(for: selected)
        #expect(vm.screenHistory.showsTimeline)
        vm.handleCommandK()
        #expect(vm.isCatalogActionPanePresented)
        #expect(!vm.focusedItemActions.contains { $0.kind == .showTimeline })
        vm.dismissItemActionLayer()
        #expect(!vm.isCatalogActionPanePresented)
        vm.screenHistory.closeTimeline()
        #expect(!vm.screenHistory.showsTimeline)
        vm.input = ""
        #expect(vm.popLayerForEmptyBackspace())
        #expect(vm.catalogScope == nil)
    }

    @Test("SH-A02 assistive presentation, repeated announcements, and focus restore")
    func shA02AssistiveTechnology() async throws {
        let frame = Self.frame(id: "a02", text: String(repeating: "Visible context ", count: 80))
        let saver = FakeScreenHistoryVaultSaver()
        let vm = QuickViewModel(
            screenHistoryStore: FakeScreenHistoryStore(rows: [frame]),
            screenHistoryVaultSaver: saver
        )
        vm.catalogScope = .screenHistory
        await vm.screenHistory.load(query: "visible")
        let firstRevision = vm.screenHistory.announcementRevision
        await vm.screenHistory.load(query: "visible")
        #expect(vm.screenHistory.announcementRevision == firstRevision + 1)
        #expect(ScreenHistoryAccessibilityPresentation.rowValue(
            isSelected: true,
            position: 1,
            total: 1,
            primaryAction: "Open moment"
        ) == "Selected, 1 of 1, Open moment with Return")
        #expect(ScreenHistoryAccessibilityPresentation.actionValue(
            isSelected: true,
            position: 2,
            total: 6
        ) == "Selected, 2 of 6")
        #expect(ScreenHistoryAccessibilityPresentation.informationGroupName == "Information")

        let item = try #require(vm.screenHistory.items.first)
        vm.openActionPane(for: .item(item), form: .screenHistorySave)
        let focusBeforeSave = vm.inputFocusRequest
        #expect(await vm.screenHistory.saveNote(for: .item(item), projectSlug: "", note: ""))
        #expect(vm.inputFocusRequest == focusBeforeSave + 1)
        let preview = ScreenHistorySavePreview(frame: frame)
        #expect(preview.ocrExcerpt == String(frame.ocrText.prefix(
            ScreenHistoryVaultSaveService.maximumOCRExcerptCharacters
        )))
        #expect(!preview.ocrExcerpt.contains("/"))
    }

    @Test("SH-I01 one surface grammar, action states, and stable preview")
    func shI01SurfaceGrammar() async throws {
        let rows = [
            Self.frame(id: "new", capturedAt: 200, text: "coral newest"),
            Self.frame(id: "old", capturedAt: 100, text: "coral older"),
        ]
        let vm = QuickViewModel(screenHistoryStore: FakeScreenHistoryStore(rows: rows))
        #expect(vm.launcherMatches.filter {
            guard case .catalog(.screenHistory, _) = $0 else { return false }
            return true
        }.count == 1)
        vm.enterCatalog(.screenHistory)
        await vm.screenHistory.load(query: "coral")
        vm.applicationSelectionIndex = 1
        let stableIDs = vm.screenHistory.items.map(\.itemID)
        _ = vm.detailItem
        #expect(vm.applicationSelectionIndex == 1)
        #expect(vm.screenHistory.items.map(\.itemID) == stableIDs)
        vm.handleCommandK()
        let actions = vm.focusedItemActions
        #expect(actions.first?.title == "Open moment")
        #expect(actions.first?.shortcut == .returnKey)
        #expect(actions.contains { $0.title == "Show timeline" })
        #expect(actions.contains { $0.title == "Copy text" })
        #expect(actions.contains { $0.title == "Save to Vault" })
        #expect(!actions.contains { $0.title == "Resume Screen History" })
        #expect(vm.footerHints.first?.label == "Open moment")
    }

    @Test("SH-I02 empty, filtered, unavailable, and delayed loading states")
    func shI02EmptyUnavailableAndLoading() async throws {
        let plain = ScreenHistoryEmptyPresentation(
            state: .ready,
            query: "synthetic phrase with no match"
        )
        #expect(plain.title == "No screen history for “synthetic phrase with no match”")
        #expect(plain.detail == "Try different words.")
        #expect(!plain.offersClearFilters)
        let filtered = ScreenHistoryEmptyPresentation(state: .ready, query: "coral app:Keynote")
        #expect(filtered.offersClearFilters)
        #expect(filtered.detail.contains("clear the filters"))
        let unavailable = ScreenHistoryEmptyPresentation(state: .unavailable, query: "")
        #expect(unavailable.title == "Screen History is unavailable on this Mac.")

        // A gated search: the store holds it open until released, so the
        // controller's "loading" state is guaranteed to appear before the
        // results. No fixed-timeout race — the search cannot complete until
        // the gate is released, so "loading" always lands and stays.
        let slowStore = FakeScreenHistoryStore(rows: [Self.frame(id: "slow", text: "coral")])
        let vm = QuickViewModel(screenHistoryStore: slowStore)
        vm.enterCatalog(.screenHistory)
        await slowStore.armGate()
        let search = Task { await vm.screenHistory.load(query: "coral") }
        // Deterministically wait until the store's search is actually blocked.
        await slowStore.waitUntilSearchBlocked()
        // The search is held open, so the state is not ready yet, and the
        // controller's "loading" state appears (and stays) before results.
        #expect(vm.screenHistory.loadState != .ready)
        let loadingDeadline = ContinuousClock.now + .seconds(15)
        while vm.screenHistory.loadState != .loading, ContinuousClock.now < loadingDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        if vm.screenHistory.loadState != .loading {
            Issue.record("the held search never reported loading")
        }
        #expect(vm.screenHistory.loadState == .loading)
        // Release the gate: the store returns, and the state becomes ready.
        await slowStore.releaseSearch()
        await search.value
        #expect(vm.screenHistory.loadState == .ready)
    }

    @Test func explicitCoastImportUsesCurrentPolicyAndReportsTheHundredMomentSample() async throws {
        var settings = QuickSettings()
        settings.screenHistoryCaptureEnabled = true
        settings.screenHistoryCaptureConfirmed = true
        settings.screenHistoryExcludedBundleIDs = ["com.example.current-private"]
        settings.screenHistoryExcludedDomains = ["current-private.example"]
        let importer = FakeScreenHistoryCoastImporter(sampleCount: 100)
        let vm = QuickViewModel(settings: settings, screenHistoryCoastImporter: importer)

        await vm.screenHistory.refreshCoastImportAvailability()
        #expect(vm.screenHistory.coastImportState == .ready)
        await vm.screenHistory.previewCoastImport()
        guard case .previewReady(let preview) = vm.screenHistory.coastImportState else {
            Issue.record("Expected reviewed Coast preview")
            return
        }
        #expect(preview.sourceRows == 12)
        #expect(preview.importedRows == 10)
        #expect(preview.excludedRows == 1)
        #expect(preview.invalidRows == 1)
        #expect(vm.screenHistory.coastImportCanImport)
        await vm.screenHistory.importCoastHistory()

        let summary: ScreenHistoryCoastImportSummary
        guard case .completed(let completed) = vm.screenHistory.coastImportState else {
            Issue.record("Expected completed Coast import")
            return
        }
        summary = completed
        #expect(!vm.settings.screenHistoryCaptureConfirmed)
        #expect(summary.verificationSampleCount == 100)
        #expect(summary.verificationSampleTarget == 100)
        #expect(summary.sourceRows == 12)
        #expect(summary.importedRows == 10)
        #expect(summary.newOwnedRows == 10)
        #expect(summary.copiedFiles == 7)
        #expect(await importer.calls == ["available", "available", "preview", "available", "metadata", "media", "sample:100"])
        let policy = try #require(await importer.importPolicies.first)
        #expect(policy.excludedBundleIdentifiers.contains("com.example.current-private"))
        #expect(policy.excludedDomains.contains("current-private.example"))
        #expect(vm.screenHistory.coastImportMessage?.contains("Prepared 100 of 100") == true)
        #expect(vm.screenHistory.coastImportMessage?.contains("Coast stays unchanged") == true)
    }

    @Test func coastImportFailureStopsSafelyAndCanResumeWithoutSamplingEarly() async {
        var settings = QuickSettings()
        settings.screenHistoryCaptureEnabled = true
        settings.screenHistoryCaptureConfirmed = true
        let importer = FakeScreenHistoryCoastImporter(failure: .media)
        let vm = QuickViewModel(settings: settings, screenHistoryCoastImporter: importer)

        await vm.screenHistory.previewCoastImport()
        await vm.screenHistory.importCoastHistory()

        #expect(vm.screenHistory.coastImportState == .failed(.media))
        #expect(!vm.settings.screenHistoryCaptureConfirmed)
        #expect(await importer.calls == ["available", "preview", "available", "metadata", "media"])
        #expect(vm.screenHistory.coastImportMessage?.contains("Coast stayed unchanged") == true)
        #expect(vm.screenHistory.coastImportMessage?.contains("resume") == true)
    }

    @Test func coastImportUnavailableDoesNotReadOrWriteMigrationStages() async {
        let importer = FakeScreenHistoryCoastImporter(isAvailable: false)
        let vm = QuickViewModel(screenHistoryCoastImporter: importer)

        await vm.screenHistory.refreshCoastImportAvailability()
        #expect(vm.screenHistory.coastImportState == .unavailable)
        await vm.screenHistory.importCoastHistory()

        #expect(vm.screenHistory.coastImportState == .previewInvalidated)
        #expect(await importer.calls == ["available"])
    }

    @Test func coastImportCannotCompleteWithMediaFailuresOrAShortReviewSample() async {
        let mediaFailure = FakeScreenHistoryCoastImporter(mediaFailureCount: 1)
        let mediaVM = QuickViewModel(screenHistoryCoastImporter: mediaFailure)
        await mediaVM.screenHistory.previewCoastImport()
        await mediaVM.screenHistory.importCoastHistory()
        #expect(mediaVM.screenHistory.coastImportState == .failed(.media))
        #expect(await mediaFailure.calls == ["available", "preview", "available", "metadata", "media"])

        let shortSample = FakeScreenHistoryCoastImporter(sampleCount: 99)
        let sampleVM = QuickViewModel(screenHistoryCoastImporter: shortSample)
        await sampleVM.screenHistory.previewCoastImport()
        await sampleVM.screenHistory.importCoastHistory()
        #expect(sampleVM.screenHistory.coastImportState == .failed(.verificationSample))
        #expect(await shortSample.calls == ["available", "preview", "available", "metadata", "media", "sample:100"])
    }

    @Test func coastImportRequiresPreviewAndExclusionEditsInvalidateIt() async {
        let importer = FakeScreenHistoryCoastImporter()
        let vm = QuickViewModel(screenHistoryCoastImporter: importer)

        await vm.screenHistory.importCoastHistory()
        #expect(vm.screenHistory.coastImportState == .previewInvalidated)
        #expect(await importer.calls.isEmpty)

        await vm.screenHistory.previewCoastImport()
        #expect(vm.screenHistory.coastImportCanImport)
        vm.settings.screenHistoryExcludedDomains = ["new-private.example"]
        vm.screenHistory.invalidateCoastImportPreview()
        #expect(vm.screenHistory.coastImportState == .previewInvalidated)
        #expect(!vm.screenHistory.coastImportCanImport)

        await vm.screenHistory.importCoastHistory()
        #expect(await importer.calls == ["available", "preview"])
    }

    @Test func coastImportRejectsSilentPolicyDriftEvenWithoutUIInvalidation() async {
        let importer = FakeScreenHistoryCoastImporter()
        let vm = QuickViewModel(screenHistoryCoastImporter: importer)
        await vm.screenHistory.previewCoastImport()
        vm.settings.screenHistoryExcludedBundleIDs.append("com.example.changed")

        await vm.screenHistory.importCoastHistory()

        #expect(vm.screenHistory.coastImportState == .previewInvalidated)
        #expect(!vm.screenHistory.coastImportCanImport)
        #expect(await importer.calls == ["available", "preview"])
    }

    @Test func coastPreviewShowsProgressAndFailsBeforeImportStages() async throws {
        // A long preview and a poll, not a fixed 30 ms nap: under a loaded
        // machine the task could start late, and the check ran before it.
        let slowImporter = FakeScreenHistoryCoastImporter(previewDelay: .seconds(2))
        let slowVM = QuickViewModel(screenHistoryCoastImporter: slowImporter)
        let preview = Task { await slowVM.screenHistory.previewCoastImport() }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(15)
        while slowVM.screenHistory.coastImportState != .previewingMetadata, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        if slowVM.screenHistory.coastImportState != .previewingMetadata {
            Issue.record("the preview never reached previewingMetadata")
        }
        #expect(slowVM.screenHistory.coastImportState == .previewingMetadata)
        #expect(slowVM.screenHistory.coastImportIsRunning)
        await preview.value
        #expect(slowVM.screenHistory.coastImportCanImport)

        let failedImporter = FakeScreenHistoryCoastImporter(failure: .preview)
        let failedVM = QuickViewModel(screenHistoryCoastImporter: failedImporter)
        await failedVM.screenHistory.previewCoastImport()
        #expect(failedVM.screenHistory.coastImportState == .failed(.preview))
        #expect(!failedVM.screenHistory.coastImportCanImport)
        #expect(failedVM.screenHistory.coastImportMessage?.contains("before any import write") == true)
        #expect(await failedImporter.calls == ["available", "preview"])
    }

    @Test func unavailableOrDisabledCaptureHasNoResumeCommandAndNamesTheFooter() {
        var disabledSettings = QuickSettings()
        disabledSettings.screenHistoryCaptureEnabled = false
        let disabled = QuickViewModel(settings: disabledSettings)
        #expect(!disabled.systemCommands.contains { $0.itemID == "screenHistory.toggleCapture" })
        #expect(disabled.screenHistory.captureStatusLabel == "Capture unavailable")

        disabled.screenHistory.captureStatus = ScreenHistoryCaptureStatus(
            state: .running,
            lastSkipReason: nil,
            metrics: .init(),
            configuration: .init(isEnabled: true),
            fileVaultStatus: .on
        )
        #expect(disabled.screenHistory.menuBarCanBeHidden)
        #expect(!disabled.screenHistory.captureIsActive)
        #expect(!disabled.systemCommands.contains { $0.itemID == "screenHistory.toggleCapture" })

        let running = ScreenHistoryMenuBarPresentation.make(status: disabled.screenHistory.captureStatus)
        #expect(running.symbolName == "record.circle.fill")
        #expect(running.accessibilityName == "Quick Launch, Screen History running")
        #expect(running.forcesVisibility)
        let stopped = ScreenHistoryMenuBarPresentation.make(status: nil)
        #expect(stopped.symbolName == "bolt")
        #expect(stopped.accessibilityName == "Quick Launch")
        #expect(!stopped.forcesVisibility)
    }

    private static func frame(
        id: String,
        source: ScreenHistorySource = .owned,
        capturedAt: TimeInterval = 100,
        text: String = "coral",
        image: String? = nil,
        sequenceIdentifier: String? = nil,
        sequenceOrdinal: Int? = nil
    ) -> ScreenHistoryFrame {
        let input = ScreenHistoryFrameInput(
            source: source,
            sourceIdentifier: id,
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            application: "Keynote",
            bundleIdentifier: "com.apple.iWork.Keynote",
            domain: "research.example",
            windowTitle: "Project Juniper",
            ocrText: text,
            imageLocator: image,
            sequenceIdentifier: sequenceIdentifier,
            sequenceOrdinal: sequenceOrdinal
        )
        return ScreenHistoryFrame(
            id: Int64(id) ?? 1,
            source: source,
            sourceIdentifier: id,
            capturedAt: input.capturedAt,
            application: input.application,
            bundleIdentifier: input.bundleIdentifier,
            domain: input.domain,
            windowTitle: input.windowTitle,
            ocrText: input.ocrText,
            imageLocator: input.imageLocator,
            mediaLocator: nil,
            mediaFrameIndex: nil,
            byteCount: 0,
            sequenceIdentifier: input.sequenceIdentifier,
            sequenceOrdinal: input.sequenceOrdinal,
            contentHash: input.contentHash
        )
    }

    private static func item(_ frame: ScreenHistoryFrame) -> LauncherCatalogItem {
        LauncherCatalogItem(
            kind: .screenHistory,
            itemID: "\(frame.source.rawValue):\(frame.sourceIdentifier)",
            title: frame.ocrText,
            detail: "Seen now · Owned",
            value: frame.ocrText,
            keywords: frame.imageLocator == nil ? "" : "has-local-file"
        )
    }
}

private actor FakeScreenHistoryVaultSaver: ScreenHistoryVaultSaving {
    private(set) var savedRecordIDs: [String] = []
    private(set) var savedNotes: [String?] = []
    private(set) var savedProjectSlugs: [String?] = []

    func save(_ frame: ScreenHistoryFrame, note: String?, projectSlug: String?) async throws -> URL {
        savedRecordIDs.append(frame.sourceIdentifier)
        savedNotes.append(note)
        savedProjectSlugs.append(projectSlug)
        return URL(fileURLWithPath: "/tmp/synthetic-screen-history-note.md")
    }
}

private actor FakeScreenHistoryCoastImporter: ScreenHistoryCoastImporting {
    enum Failure: Equatable {
        case preview
        case metadata
        case media
        case sample
    }

    let isAvailable: Bool
    let sampleCount: Int
    let failure: Failure?
    let mediaFailureCount: Int
    let previewDelay: Duration
    private(set) var calls: [String] = []
    private(set) var previewPolicies: [ScreenHistoryMigrationPolicy] = []
    private(set) var importPolicies: [ScreenHistoryMigrationPolicy] = []
    private var approvedPreview: ScreenHistoryCoastImportPreview?

    init(
        isAvailable: Bool = true,
        sampleCount: Int = 100,
        failure: Failure? = nil,
        mediaFailureCount: Int = 0,
        previewDelay: Duration = .zero
    ) {
        self.isAvailable = isAvailable
        self.sampleCount = sampleCount
        self.failure = failure
        self.mediaFailureCount = mediaFailureCount
        self.previewDelay = previewDelay
    }

    func sourceIsAvailable() async -> Bool {
        calls.append("available")
        return isAvailable
    }

    func previewMetadata(policy: ScreenHistoryMigrationPolicy) async throws -> ScreenHistoryCoastImportPreview {
        calls.append("preview")
        previewPolicies.append(policy)
        if previewDelay > .zero { try await Task.sleep(for: previewDelay) }
        if failure == .preview { throw FakeScreenHistoryCoastImportError.synthetic }
        let preview = ScreenHistoryCoastImportPreview(
            authorizationID: UUID(),
            sourceRows: 12,
            importedRows: 10,
            excludedRows: 1,
            invalidRows: 1,
            policyFingerprint: policy.fingerprint,
            sourceFingerprint: "synthetic-source-fingerprint"
        )
        approvedPreview = preview
        return preview
    }

    func invalidatePreview() {
        approvedPreview = nil
    }

    func importMetadata(
        preview: ScreenHistoryCoastImportPreview,
        policy: ScreenHistoryMigrationPolicy
    ) async throws -> ScreenHistoryMigrationResult {
        calls.append("metadata")
        importPolicies.append(policy)
        if failure == .metadata { throw FakeScreenHistoryCoastImportError.synthetic }
        guard preview == approvedPreview,
              preview.policyFingerprint == policy.fingerprint
        else { throw ScreenHistoryCoastImportError.stalePreview }
        approvedPreview = nil
        return ScreenHistoryMigrationResult(
            source: 12,
            imported: 10,
            excluded: 1,
            invalid: 1,
            ownedRowDelta: 10,
            hashDelta: 10,
            mappingCount: 10,
            ledgerCount: 12,
            lastLegacyFrameID: 12
        )
    }

    func copyVerifiedMedia() async throws -> ScreenHistoryMediaMigrationResult {
        calls.append("media")
        if failure == .media { throw FakeScreenHistoryCoastImportError.synthetic }
        return ScreenHistoryMediaMigrationResult(
            sourceRows: 10,
            uniqueLocators: 7,
            copiedFileDelta: 7,
            hashDelta: 7,
            updatedRowDelta: 10,
            ledgerDelta: 7,
            failures: (0..<mediaFailureCount).map {
                ScreenHistoryMediaMigrationFailure(
                    sourcePathHash: "synthetic-\($0)",
                    status: .failed
                )
            },
            lastFrameID: 10
        )
    }

    func verificationSampleCount(limit: Int) async throws -> Int {
        calls.append("sample:\(limit)")
        if failure == .sample { throw FakeScreenHistoryCoastImportError.synthetic }
        return min(limit, sampleCount)
    }
}

private enum FakeScreenHistoryCoastImportError: Error {
    case synthetic
}

private actor FakeScreenHistoryStore: ScreenHistoryStoring {
    let rows: [ScreenHistoryFrame]
    let searchDelay: Duration
    private(set) var searchCalls = 0
    /// When armed, the next `search` blocks until `releaseSearch()` is called,
    /// so the test controls when results land instead of sleeping a fixed
    /// timeout. Deterministic synchronization: no timing race.
    private var gateArmed = false
    private var gateHeld = false
    private var gateHeldContinuation: CheckedContinuation<Void, Never>?
    private var gateReleaseContinuation: CheckedContinuation<Void, Never>?

    init(rows: [ScreenHistoryFrame], searchDelay: Duration = .zero) {
        self.rows = rows
        self.searchDelay = searchDelay
    }

    /// Arm the gate so the next search blocks until released.
    func armGate() { gateArmed = true }

    /// Resolves once a gated search is actually blocked, so the test can wait
    /// deterministically for the store to be mid-search (no fixed sleep).
    func waitUntilSearchBlocked() async {
        if gateHeld { return }
        await withCheckedContinuation { gateHeldContinuation = $0 }
    }

    /// Release a gated search so it returns its rows.
    func releaseSearch() {
        gateArmed = false
        gateReleaseContinuation?.resume()
        gateReleaseContinuation = nil
    }

    func record(_ frame: ScreenHistoryFrameInput) throws -> Int64 { 1 }
    func record(_ frames: [ScreenHistoryFrameInput]) throws -> Int { frames.count }
    func search(_ query: ScreenHistorySearchQuery) async throws -> [ScreenHistoryFrame] {
        searchCalls += 1
        if searchDelay != .zero { try await Task.sleep(for: searchDelay) }
        if gateArmed {
            gateHeld = true
            gateHeldContinuation?.resume()
            gateHeldContinuation = nil
            await withCheckedContinuation { gateReleaseContinuation = $0 }
            gateHeld = false
        }
        return rows.filter { frame in
            let text = query.text.lowercased()
            return text.isEmpty || frame.ocrText.lowercased().contains(text)
        }
    }
    func sequence(containingFrameID frameID: Int64, limit: Int) throws -> [ScreenHistoryFrame] { rows }
    func count() throws -> Int { rows.count }
    func prune(policy: ScreenHistoryRetentionPolicy, now: Date) throws -> ScreenHistoryPruneResult {
        ScreenHistoryPruneResult(
            rowsPlanned: 0,
            rowsRemoved: 0,
            bytesRemoved: 0,
            filesRemoved: 0,
            filesRetainedShared: 0,
            filesRetainedUnowned: 0,
            filesAbsent: 0,
            pendingRows: 0,
            pendingLocators: 0,
            retryRequired: false,
            resumedQueue: false
        )
    }
}

private actor FakeCoastReader: CoastLegacyReading {
    let rows: [ScreenHistoryFrame]
    private(set) var searchCalls = 0
    private(set) var pageCalls = 0

    init(rows: [ScreenHistoryFrame]) { self.rows = rows }
    func isAvailable() -> Bool { true }
    func search(_ query: ScreenHistorySearchQuery) throws -> [ScreenHistoryFrame] {
        searchCalls += 1
        let text = query.text.lowercased()
        return rows.filter { text.isEmpty || $0.ocrText.lowercased().contains(text) }
    }
    func page(offset: Int, limit: Int) throws -> [ScreenHistoryFrame] {
        pageCalls += 1
        return Array(rows.dropFirst(offset).prefix(limit))
    }
    func moments(from: Date, through: Date, limit: Int) throws -> [ScreenHistoryFrame] {
        rows.filter { $0.capturedAt >= from && $0.capturedAt <= through }
    }
    func importRows(afterFrameID: Int64?, limit: Int) throws -> [ScreenHistoryFrameInput] { [] }
}
