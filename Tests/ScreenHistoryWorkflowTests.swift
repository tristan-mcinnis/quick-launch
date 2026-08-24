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
        await vm.loadScreenHistory(query: "coral")

        #expect(vm.screenHistoryItems.count == 2)
        #expect(vm.screenHistoryItems.allSatisfy { $0.title == "Project Juniper" })
        #expect(vm.screenHistoryItems.contains { $0.keywords.contains("Owned") })
        #expect(vm.screenHistoryItems.contains { $0.keywords.contains("Coast") })
        #expect(vm.screenHistoryItems.contains { $0.detail.hasPrefix("Owned · Seen ") })
        #expect(vm.screenHistoryItems.contains { $0.detail.hasPrefix("Coast · Seen ") })
        #expect(vm.screenHistoryItems.allSatisfy { $0.kind == .screenHistory })
        #expect(vm.screenHistoryLoadState == .ready)
        #expect(vm.footerHints.contains { $0.label == "Copy text" && $0.keys == ["⌘", "↩"] })
        vm.handleCommandK()
        #expect(vm.isCatalogActionPanePresented)
        #expect(vm.contextualCatalogItem?.kind == .screenHistory)
    }

    @Test func futureAndCurrentTruthQueriesDoNotReadStores() async {
        let owned = FakeScreenHistoryStore(rows: [])
        let vm = QuickViewModel(screenHistoryStore: owned)
        vm.enterCatalog(.screenHistory)
        await vm.loadScreenHistory(query: "what will be on my screen tomorrow")
        #expect(vm.screenHistoryLoadState == .refusedFuture)
        await vm.loadScreenHistory(query: "where does Project Juniper stand now?")
        #expect(vm.screenHistoryLoadState == .routedToVaultSearch)
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
        await vm.loadScreenHistory(query: "coral")
        await vm.openScreenHistorySequence(for: anchor)

        #expect(vm.screenHistoryShowsTimeline)
        #expect(vm.screenHistoryTimelineFrames.map(\.sourceIdentifier) == ["1", "2", "3"])
        vm.input = ""
        #expect(vm.popLayerForEmptyBackspace())
        #expect(!vm.screenHistoryShowsTimeline)
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

        await vm.openScreenHistorySequence(for: anchor)

        #expect(vm.screenHistoryTimelineFrames.map(\.sourceIdentifier) == ["1", "2", "3"])
    }

    @Test func actionTableUsesTheLauncherGrammarAndVaultWriteUsesConfirmedForm() async throws {
        let frame = Self.frame(id: "one", image: "/tmp/not-owned.jpg")
        let store = FakeScreenHistoryStore(rows: [frame])
        let saver = FakeScreenHistoryVaultSaver()
        let vm = QuickViewModel(screenHistoryStore: store, screenHistoryVaultSaver: saver)
        vm.enterCatalog(.screenHistory)
        await vm.loadScreenHistory(query: "coral")
        let item = try #require(vm.screenHistoryItems.first)
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
        #expect(await vm.saveScreenHistoryNote(
            for: .item(item),
            projectSlug: "project-juniper",
            note: "Follow up with the team"
        ))
        #expect(await saver.savedRecordIDs == ["one"])
        #expect(await saver.savedProjectSlugs == ["project-juniper"])
        #expect(await saver.savedNotes == ["Follow up with the team"])
        #expect(vm.screenHistoryResultAnnouncement == "Saved this screen moment to Vault triage.")
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
        await vm.loadScreenHistory(query: vm.input)
        vm.moveSelectionVertically(1)
        #expect(vm.applicationSelectionIndex == 1)
        #expect(vm.screenHistoryResultAnnouncement.contains("selected"))

        let selected = try #require(vm.screenHistoryFrame(for: vm.screenHistoryItems[1]))
        await vm.openScreenHistorySequence(for: selected)
        #expect(vm.screenHistoryShowsTimeline)
        vm.handleCommandK()
        #expect(vm.isCatalogActionPanePresented)
        #expect(!vm.focusedItemActions.contains { $0.kind == .showTimeline })
        vm.dismissItemActionLayer()
        #expect(!vm.isCatalogActionPanePresented)
        vm.closeScreenHistoryTimeline()
        #expect(!vm.screenHistoryShowsTimeline)
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
        await vm.loadScreenHistory(query: "visible")
        let firstRevision = vm.screenHistoryAnnouncementRevision
        await vm.loadScreenHistory(query: "visible")
        #expect(vm.screenHistoryAnnouncementRevision == firstRevision + 1)
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

        let item = try #require(vm.screenHistoryItems.first)
        vm.openActionPane(for: .item(item), form: .screenHistorySave)
        let focusBeforeSave = vm.inputFocusRequest
        #expect(await vm.saveScreenHistoryNote(for: .item(item), projectSlug: "", note: ""))
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
        await vm.loadScreenHistory(query: "coral")
        vm.applicationSelectionIndex = 1
        let stableIDs = vm.screenHistoryItems.map(\.itemID)
        _ = vm.detailItem
        #expect(vm.applicationSelectionIndex == 1)
        #expect(vm.screenHistoryItems.map(\.itemID) == stableIDs)
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

        let slowStore = FakeScreenHistoryStore(
            rows: [Self.frame(id: "slow", text: "coral")],
            searchDelay: .milliseconds(240)
        )
        let vm = QuickViewModel(screenHistoryStore: slowStore)
        vm.enterCatalog(.screenHistory)
        let search = Task { await vm.loadScreenHistory(query: "coral") }
        try await Task.sleep(for: .milliseconds(60))
        #expect(vm.screenHistoryLoadState != .loading)
        try await Task.sleep(for: .milliseconds(100))
        #expect(vm.screenHistoryLoadState == .loading)
        await search.value
        #expect(vm.screenHistoryLoadState == .ready)
    }

    @Test func explicitCoastImportUsesCurrentPolicyAndReportsTheHundredMomentSample() async throws {
        var settings = QuickSettings()
        settings.screenHistoryCaptureEnabled = true
        settings.screenHistoryCaptureConfirmed = true
        settings.screenHistoryExcludedBundleIDs = ["com.example.current-private"]
        settings.screenHistoryExcludedDomains = ["current-private.example"]
        let importer = FakeScreenHistoryCoastImporter(sampleCount: 100)
        let vm = QuickViewModel(settings: settings, screenHistoryCoastImporter: importer)

        await vm.refreshScreenHistoryCoastImportAvailability()
        #expect(vm.screenHistoryCoastImportState == .ready)
        await vm.previewCoastHistoryImport()
        guard case .previewReady(let preview) = vm.screenHistoryCoastImportState else {
            Issue.record("Expected reviewed Coast preview")
            return
        }
        #expect(preview.sourceRows == 12)
        #expect(preview.importedRows == 10)
        #expect(preview.excludedRows == 1)
        #expect(preview.invalidRows == 1)
        #expect(vm.screenHistoryCoastImportCanImport)
        await vm.importCoastHistory()

        let summary: ScreenHistoryCoastImportSummary
        guard case .completed(let completed) = vm.screenHistoryCoastImportState else {
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
        #expect(vm.screenHistoryCoastImportMessage?.contains("Prepared 100 of 100") == true)
        #expect(vm.screenHistoryCoastImportMessage?.contains("Coast stays unchanged") == true)
    }

    @Test func coastImportFailureStopsSafelyAndCanResumeWithoutSamplingEarly() async {
        var settings = QuickSettings()
        settings.screenHistoryCaptureEnabled = true
        settings.screenHistoryCaptureConfirmed = true
        let importer = FakeScreenHistoryCoastImporter(failure: .media)
        let vm = QuickViewModel(settings: settings, screenHistoryCoastImporter: importer)

        await vm.previewCoastHistoryImport()
        await vm.importCoastHistory()

        #expect(vm.screenHistoryCoastImportState == .failed(.media))
        #expect(!vm.settings.screenHistoryCaptureConfirmed)
        #expect(await importer.calls == ["available", "preview", "available", "metadata", "media"])
        #expect(vm.screenHistoryCoastImportMessage?.contains("Coast stayed unchanged") == true)
        #expect(vm.screenHistoryCoastImportMessage?.contains("resume") == true)
    }

    @Test func coastImportUnavailableDoesNotReadOrWriteMigrationStages() async {
        let importer = FakeScreenHistoryCoastImporter(isAvailable: false)
        let vm = QuickViewModel(screenHistoryCoastImporter: importer)

        await vm.refreshScreenHistoryCoastImportAvailability()
        #expect(vm.screenHistoryCoastImportState == .unavailable)
        await vm.importCoastHistory()

        #expect(vm.screenHistoryCoastImportState == .previewInvalidated)
        #expect(await importer.calls == ["available"])
    }

    @Test func coastImportCannotCompleteWithMediaFailuresOrAShortReviewSample() async {
        let mediaFailure = FakeScreenHistoryCoastImporter(mediaFailureCount: 1)
        let mediaVM = QuickViewModel(screenHistoryCoastImporter: mediaFailure)
        await mediaVM.previewCoastHistoryImport()
        await mediaVM.importCoastHistory()
        #expect(mediaVM.screenHistoryCoastImportState == .failed(.media))
        #expect(await mediaFailure.calls == ["available", "preview", "available", "metadata", "media"])

        let shortSample = FakeScreenHistoryCoastImporter(sampleCount: 99)
        let sampleVM = QuickViewModel(screenHistoryCoastImporter: shortSample)
        await sampleVM.previewCoastHistoryImport()
        await sampleVM.importCoastHistory()
        #expect(sampleVM.screenHistoryCoastImportState == .failed(.verificationSample))
        #expect(await shortSample.calls == ["available", "preview", "available", "metadata", "media", "sample:100"])
    }

    @Test func coastImportRequiresPreviewAndExclusionEditsInvalidateIt() async {
        let importer = FakeScreenHistoryCoastImporter()
        let vm = QuickViewModel(screenHistoryCoastImporter: importer)

        await vm.importCoastHistory()
        #expect(vm.screenHistoryCoastImportState == .previewInvalidated)
        #expect(await importer.calls.isEmpty)

        await vm.previewCoastHistoryImport()
        #expect(vm.screenHistoryCoastImportCanImport)
        vm.settings.screenHistoryExcludedDomains = ["new-private.example"]
        vm.invalidateScreenHistoryCoastImportPreview()
        #expect(vm.screenHistoryCoastImportState == .previewInvalidated)
        #expect(!vm.screenHistoryCoastImportCanImport)

        await vm.importCoastHistory()
        #expect(await importer.calls == ["available", "preview"])
    }

    @Test func coastImportRejectsSilentPolicyDriftEvenWithoutUIInvalidation() async {
        let importer = FakeScreenHistoryCoastImporter()
        let vm = QuickViewModel(screenHistoryCoastImporter: importer)
        await vm.previewCoastHistoryImport()
        vm.settings.screenHistoryExcludedBundleIDs.append("com.example.changed")

        await vm.importCoastHistory()

        #expect(vm.screenHistoryCoastImportState == .previewInvalidated)
        #expect(!vm.screenHistoryCoastImportCanImport)
        #expect(await importer.calls == ["available", "preview"])
    }

    @Test func coastPreviewShowsProgressAndFailsBeforeImportStages() async throws {
        let slowImporter = FakeScreenHistoryCoastImporter(previewDelay: .milliseconds(120))
        let slowVM = QuickViewModel(screenHistoryCoastImporter: slowImporter)
        let preview = Task { await slowVM.previewCoastHistoryImport() }
        try await Task.sleep(for: .milliseconds(30))
        #expect(slowVM.screenHistoryCoastImportState == .previewingMetadata)
        #expect(slowVM.screenHistoryCoastImportIsRunning)
        await preview.value
        #expect(slowVM.screenHistoryCoastImportCanImport)

        let failedImporter = FakeScreenHistoryCoastImporter(failure: .preview)
        let failedVM = QuickViewModel(screenHistoryCoastImporter: failedImporter)
        await failedVM.previewCoastHistoryImport()
        #expect(failedVM.screenHistoryCoastImportState == .failed(.preview))
        #expect(!failedVM.screenHistoryCoastImportCanImport)
        #expect(failedVM.screenHistoryCoastImportMessage?.contains("before any import write") == true)
        #expect(await failedImporter.calls == ["available", "preview"])
    }

    @Test func unavailableOrDisabledCaptureHasNoResumeCommandAndNamesTheFooter() {
        var disabledSettings = QuickSettings()
        disabledSettings.screenHistoryCaptureEnabled = false
        let disabled = QuickViewModel(settings: disabledSettings)
        #expect(!disabled.systemCommands.contains { $0.itemID == "screenHistory.toggleCapture" })
        #expect(disabled.screenHistoryCaptureStatusLabel == "Capture unavailable")

        disabled.screenHistoryCaptureStatus = ScreenHistoryCaptureStatus(
            state: .running,
            lastSkipReason: nil,
            metrics: .init(),
            configuration: .init(isEnabled: true),
            fileVaultStatus: .on
        )
        #expect(disabled.screenHistoryMenuBarCanBeHidden)
        #expect(!disabled.screenHistoryCaptureIsActive)
        #expect(!disabled.systemCommands.contains { $0.itemID == "screenHistory.toggleCapture" })

        let running = ScreenHistoryMenuBarPresentation.make(status: disabled.screenHistoryCaptureStatus)
        #expect(running.symbolName == "record.circle.fill")
        #expect(running.accessibilityName == "Quick Launch, Screen History running")
        #expect(running.forcesVisibility)
        let stopped = ScreenHistoryMenuBarPresentation.make(status: nil)
        #expect(stopped.symbolName == "bolt.fill")
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

    init(rows: [ScreenHistoryFrame], searchDelay: Duration = .zero) {
        self.rows = rows
        self.searchDelay = searchDelay
    }
    func record(_ frame: ScreenHistoryFrameInput) throws -> Int64 { 1 }
    func record(_ frames: [ScreenHistoryFrameInput]) throws -> Int { frames.count }
    func search(_ query: ScreenHistorySearchQuery) async throws -> [ScreenHistoryFrame] {
        searchCalls += 1
        if searchDelay != .zero { try await Task.sleep(for: searchDelay) }
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
