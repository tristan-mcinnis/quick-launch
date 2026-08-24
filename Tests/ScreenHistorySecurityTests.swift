import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screen History security controls", .serialized)
@MainActor
struct ScreenHistorySecurityTests {
    @Test func fileVaultOutputParsesOnOffAndFailsClosed() throws {
        let receipt = try Self.receipt("SH-SEC-FILEVAULT")
        #expect(FileVaultStatusParser.parse(output: "FileVault is On.\n", terminationStatus: 0) == .on)
        #expect(FileVaultStatusParser.parse(output: "FileVault is Off.\n", terminationStatus: 0) == .off)
        #expect(FileVaultStatusParser.parse(output: "Deferred enablement", terminationStatus: 0) == .unknown)
        #expect(FileVaultStatusParser.parse(output: "FileVault is On.", terminationStatus: 1) == .unknown)
        try receipt.finish(measurements: .init(
            localFileCount: 0, toolCallCount: 0, helperCallCount: 4, sourceRootCount: 0
        ))
    }

    @Test func protectedSessionParserFailsClosedAndClassifiesSystemState() throws {
        let receipt = try Self.receipt("SH-SEC-SESSION")
        let clearSession: [String: Any] = [
            ScreenHistoryProtectedSessionParser.onConsoleKey: true,
            ScreenHistoryProtectedSessionParser.loginDoneKey: true,
            ScreenHistoryProtectedSessionParser.lockedKey: false,
        ]

        #expect(ScreenHistoryProtectedSessionParser.parse(
            sessionDictionary: clearSession,
            activeDisplayCapture: false
        ) == .clear)
        #expect(ScreenHistoryProtectedSessionParser.parse(
            sessionDictionary: clearSession,
            activeDisplayCapture: true
        ) == .activeDisplayCapture)
        #expect(ScreenHistoryProtectedSessionParser.parse(
            sessionDictionary: clearSession.merging([
                ScreenHistoryProtectedSessionParser.lockedKey: true,
            ]) { _, new in new },
            activeDisplayCapture: false
        ) == .locked)
        #expect(ScreenHistoryProtectedSessionParser.parse(
            sessionDictionary: clearSession.merging([
                ScreenHistoryProtectedSessionParser.onConsoleKey: false,
            ]) { _, new in new },
            activeDisplayCapture: false
        ) == .offConsole)
        #expect(ScreenHistoryProtectedSessionParser.parse(
            sessionDictionary: nil,
            activeDisplayCapture: false
        ) == .unknown)
        #expect(ScreenHistoryProtectedSessionParser.parse(
            sessionDictionary: clearSession,
            activeDisplayCapture: nil
        ) == .unknown)
        #expect(ScreenHistoryProtectedSessionParser.parse(
            sessionDictionary: clearSession.filter {
                $0.key != ScreenHistoryProtectedSessionParser.lockedKey
            },
            activeDisplayCapture: false
        ) == .unknown)
        try receipt.finish(measurements: .init(
            localFileCount: 0, toolCallCount: 0, helperCallCount: 7, sourceRootCount: 0
        ))
    }

    @Test func anyRunningSharingApplicationBlocksTheSessionGate() throws {
        let receipt = try Self.receipt("SH-SEC-SHARING")
        #expect(CoreGraphicsScreenHistoryProtectedSessionReader.hasRunningSharingApplication(
            bundleIdentifiers: ["com.apple.finder", "us.zoom.xos"]
        ))
        #expect(CoreGraphicsScreenHistoryProtectedSessionReader.hasRunningSharingApplication(
            bundleIdentifiers: ["COM.MICROSOFT.TEAMS2"]
        ))
        #expect(!CoreGraphicsScreenHistoryProtectedSessionReader.hasRunningSharingApplication(
            bundleIdentifiers: ["com.apple.finder", "com.apple.iWork.Keynote"]
        ))
        try receipt.finish(measurements: .init(
            localFileCount: 0, toolCallCount: 0, helperCallCount: 3, sourceRootCount: 0
        ))
    }

    @Test func statusMenuAlwaysNamesStateAndOffersOnlyAStopControl() throws {
        let receipt = try Self.receipt("SH-SEC-STATUS")
        let running = ScreenHistoryStatusPresentation.make(status: Self.status(.running))
        #expect(running.statusTitle == "Screen History Running")
        #expect(running.controlTitle == "Pause Screen History")
        #expect(running.controlIsEnabled)

        let paused = ScreenHistoryStatusPresentation.make(status: Self.status(.pausedForInactivity))
        #expect(paused.statusTitle == "Screen History Paused")
        #expect(paused.controlTitle == "Stop Screen History")
        #expect(paused.controlIsEnabled)

        let stopped = ScreenHistoryStatusPresentation.make(status: Self.status(.stopped))
        #expect(stopped.statusTitle == "Screen History Stopped")
        #expect(stopped.controlTitle == "Stop Screen History")
        #expect(!stopped.controlIsEnabled)
        try receipt.finish(measurements: .init(
            localFileCount: 0, toolCallCount: 0, helperCallCount: 3, sourceRootCount: 0
        ))
    }

    @Test func currentExclusionsFeedSearchAndMigrationPolicy() throws {
        let receipt = try Self.receipt("SH-SEC-EXCLUSIONS")
        var settings = QuickSettings()
        settings.screenHistoryExcludedBundleIDs = ["com.example.private"]
        settings.screenHistoryExcludedDomains = ["private.example"]

        let bundleFrame = Self.frame(bundle: "com.example.private", domain: nil)
        let domainFrame = Self.frame(bundle: "com.apple.iWork.Keynote", domain: "notes.private.example")
        #expect(!ScreenHistoryPrivacyPolicy.allowsSearchResult(
            bundleFrame,
            excludedBundleIdentifiers: Set(settings.screenHistoryExcludedBundleIDs),
            excludedDomains: Set(settings.screenHistoryExcludedDomains)
        ))
        #expect(!ScreenHistoryPrivacyPolicy.allowsSearchResult(
            domainFrame,
            excludedBundleIdentifiers: Set(settings.screenHistoryExcludedBundleIDs),
            excludedDomains: Set(settings.screenHistoryExcludedDomains)
        ))

        let migration = settings.screenHistoryMigrationPolicy
        #expect(migration.excludedBundleIdentifiers.contains("com.example.private"))
        #expect(migration.excludedDomains.contains("private.example"))
        try receipt.finish(measurements: .init(
            localFileCount: 0, toolCallCount: 0, helperCallCount: 3, sourceRootCount: 0
        ))
    }

    @Test func systemMeetingAndSharingSurfacesAreHardExcluded() throws {
        let receipt = try Self.receipt("SH-SEC-HARD-EXCLUSIONS")
        let configuration = ScreenHistoryCaptureConfiguration(
            isEnabled: true,
            excludedBundleIdentifiers: [],
            excludedDomains: []
        )
        let migration = ScreenHistoryMigrationPolicy()
        for bundle in [
            "com.apple.systempreferences",
            "us.zoom.xos",
            "com.apple.screensharing",
        ] {
            #expect(configuration.excludes(bundle))
            #expect(migration.excludedBundleIdentifiers.contains(bundle.lowercased()))
        }
        #expect(!migration.excludedBundleIdentifiers.contains("com.apple.mail"))
        #expect(!migration.excludedBundleIdentifiers.contains("com.tinyspeck.slackmacgap"))
        try receipt.finish(measurements: .init(
            localFileCount: 0, toolCallCount: 0, helperCallCount: 0, sourceRootCount: 0
        ))
    }

    @Test func currentExclusionsFilterMergedSearchRows() async throws {
        let receipt = try Self.receipt("SH-SEC-SEARCH")
        var settings = QuickSettings()
        settings.searchLegacyCoastHistory = false
        settings.screenHistoryExcludedBundleIDs = ["com.example.private"]
        settings.screenHistoryExcludedDomains = ["private.example"]
        let store = SecurityHistoryStore(rows: [
            Self.frame(bundle: "com.example.private", domain: nil),
            Self.frame(bundle: "com.apple.iWork.Keynote", domain: "notes.private.example"),
            Self.frame(bundle: "com.apple.iWork.Keynote", domain: "allowed.example"),
        ])
        let vm = QuickViewModel(settings: settings, screenHistoryStore: store)
        vm.catalogScope = .screenHistory

        await vm.loadScreenHistory(query: "notes")

        #expect(vm.screenHistoryFrames.count == 1)
        #expect(vm.screenHistoryFrames.first?.domain == "allowed.example")
        try receipt.finish(measurements: .init(
            localFileCount: 0, toolCallCount: 0, helperCallCount: 1, sourceRootCount: 1
        ))
    }

    @Test func bootstrapClearsPersistedConsentAndBetaCannotStartCapture() async throws {
        let receipt = try Self.receipt("SH-SEC-BOOTSTRAP")
        #expect(!ScreenHistoryReleasePolicy.allowsOwnedCapture)
        var settings = QuickSettings()
        settings.screenHistoryCaptureEnabled = true
        settings.screenHistoryCaptureConfirmed = true
        let source = SecurityHistoryFrameSource()
        let capture = Self.captureService(source: source)
        let vm = QuickViewModel(settings: settings, screenHistoryCaptureService: capture)
        var saved: QuickSettings?
        vm.persistSettings = { saved = $0 }

        await vm.prepareScreenHistoryCaptureForBootstrap()

        #expect(!vm.settings.screenHistoryCaptureConfirmed)
        #expect(saved?.screenHistoryCaptureConfirmed == false)
        #expect(vm.screenHistoryCaptureStatus?.state == .disabled)
        #expect(await source.captureCalls == 0)

        await vm.confirmAndStartScreenHistoryCapture()
        #expect(vm.screenHistoryCaptureStatus?.state == .disabled)
        #expect(vm.errorMessage == "Owned capture is locked in this search-only beta.")

        vm.noteScreenHistorySettingsPresented()
        await vm.confirmAndStartScreenHistoryCapture()
        #expect(vm.screenHistoryCaptureStatus?.state == .disabled)
        #expect(!vm.settings.screenHistoryCaptureConfirmed)
        #expect(await source.captureCalls == 0)
        try receipt.finish(measurements: .init(
            localFileCount: 0, toolCallCount: 0, helperCallCount: 3, sourceRootCount: 0
        ))
    }

    @Test func betaExposesNoCaptureCommandOrResumePath() async throws {
        let receipt = try Self.receipt("SH-SEC-BETA")
        var settings = QuickSettings()
        settings.screenHistoryCaptureEnabled = true
        let capture = Self.captureService(source: SecurityHistoryFrameSource())
        let vm = QuickViewModel(settings: settings, screenHistoryCaptureService: capture)
        await vm.prepareScreenHistoryCaptureForBootstrap()

        #expect(!vm.systemCommands.contains { $0.itemID == "screenHistory.toggleCapture" })
        vm.noteScreenHistorySettingsPresented()
        await vm.toggleScreenHistoryCaptureFromCommand()
        #expect(vm.errorMessage == "Owned capture is locked in this search-only beta.")
        #expect(vm.screenHistoryCaptureStatus?.state == .disabled)
        try receipt.finish(measurements: .init(
            localFileCount: 0, toolCallCount: 0, helperCallCount: 2, sourceRootCount: 0
        ))
    }

    private static func receipt(_ caseID: String) throws -> ScreenHistoryEvaluationRun {
        try ScreenHistoryEvaluationReceiptWriter.shared.begin(suite: .security, caseID: caseID)
    }

    private static func status(_ state: ScreenHistoryCaptureState) -> ScreenHistoryCaptureStatus {
        ScreenHistoryCaptureStatus(
            state: state,
            lastSkipReason: nil,
            metrics: .init(),
            configuration: .init(isEnabled: state != .disabled),
            fileVaultStatus: .on
        )
    }

    private static func captureService(
        source: SecurityHistoryFrameSource
    ) -> ScreenHistoryCaptureService {
        ScreenHistoryCaptureService(
            frameSource: source,
            activityReader: SecurityHistoryActivityReader(),
            textRecognizer: SecurityHistoryTextRecognizer(),
            sink: SecurityHistorySink(),
            securityChecker: SecurityHistoryChecker(),
            protectedSessionReader: SecurityProtectedSessionReader()
        )
    }

    private static func frame(bundle: String, domain: String?) -> ScreenHistoryFrame {
        ScreenHistoryFrame(
            id: 1,
            source: .owned,
            sourceIdentifier: UUID().uuidString,
            capturedAt: Date(timeIntervalSince1970: 100),
            application: "Example",
            bundleIdentifier: bundle,
            domain: domain,
            windowTitle: "Notes",
            ocrText: "Private notes",
            imageLocator: nil,
            mediaLocator: nil,
            mediaFrameIndex: nil,
            byteCount: 0,
            sequenceIdentifier: nil,
            sequenceOrdinal: nil,
            contentHash: "hash"
        )
    }
}

private struct SecurityHistoryChecker: ScreenHistorySecurityChecking {
    func fileVaultStatus() async -> FileVaultStatus { .on }
}

private struct SecurityProtectedSessionReader: ScreenHistoryProtectedSessionReading {
    func protectedSessionStatus() async -> ScreenHistoryProtectedSessionStatus { .clear }
}

private actor SecurityHistoryFrameSource: ScreenHistoryFrameSourcing {
    private(set) var captureCalls = 0

    func frontmostWindowTarget() async -> ScreenHistoryCaptureTarget? {
        ScreenHistoryCaptureTarget(
            windowIdentifier: 7,
            processIdentifier: 42,
            bundleIdentifier: "com.apple.iWork.Keynote",
            applicationName: "Keynote"
        )
    }

    func captureWindow(for target: ScreenHistoryCaptureTarget) async throws -> ScreenHistoryRawFrame? {
        captureCalls += 1
        return nil
    }
}

private struct SecurityHistoryActivityReader: ScreenHistoryActivityReading {
    func secondsSinceLastInput() async -> TimeInterval { 0 }
}

private struct SecurityHistoryTextRecognizer: ScreenHistoryTextRecognizing {
    func recognizeText(in imageData: Data) async -> String { "" }
}

private actor SecurityHistorySink: ScreenHistoryFrameSink {
    func receive(_ frame: CapturedScreenFrame) async throws {}
}

private actor SecurityHistoryStore: ScreenHistoryStoring {
    let rows: [ScreenHistoryFrame]

    init(rows: [ScreenHistoryFrame]) { self.rows = rows }
    func record(_ frame: ScreenHistoryFrameInput) async throws -> Int64 { 0 }
    func record(_ frames: [ScreenHistoryFrameInput]) async throws -> Int { 0 }
    func search(_ query: ScreenHistorySearchQuery) async throws -> [ScreenHistoryFrame] { rows }
    func sequence(containingFrameID frameID: Int64, limit: Int) async throws -> [ScreenHistoryFrame] { [] }
    func count() async throws -> Int { rows.count }
    func prune(policy: ScreenHistoryRetentionPolicy, now: Date) async throws -> ScreenHistoryPruneResult {
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
