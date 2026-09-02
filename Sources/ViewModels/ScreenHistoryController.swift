import Foundation
import AppKit
import Observation

/// The few core overlay hooks Screen History needs. `QuickViewModel` is the
/// production host; the controller never reaches past this surface.
@MainActor protocol ScreenHistoryHost: AnyObject {
    var input: String { get set }
    var catalogScope: LauncherCatalogScope? { get set }
    var inputMode: QuickViewModel.InputMode? { get set }
    var settings: QuickSettings { get set }
    var errorMessage: String? { get set }
    var applicationSelectionIndex: Int { get set }
    var overlayPresenter: any OverlayPresenting { get }
    var prepareForExternalAction: (() -> Void)? { get }
    var persistSettings: (QuickSettings) -> Void { get }
    func requestInputFocus()
    func invalidateLauncherRanking()
    func closeItemActionPane()
}

enum ScreenHistoryLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case unavailable
    case failed(String)
    case refusedFuture
    case routedToVaultSearch
}

/// Owns every Screen History state, service, task, and workflow so the core
/// overlay only knows the catalog scope and the ⌘K hooks.
@Observable @MainActor final class ScreenHistoryController {

    // MARK: - Published state

    var frames: [ScreenHistoryFrame] = []
    private(set) var ocrBoxesByFrameID: [String: [ScreenHistoryOCRBox]] = [:]
    var timelineFrames: [ScreenHistoryFrame] = []
    var showsTimeline = false
    var queryBeforeTimeline = ""
    var loadState: ScreenHistoryLoadState = .idle
    private(set) var resultAnnouncement = ""
    private(set) var announcementRevision = 0
    var saveError: String?
    var captureStatus: ScreenHistoryCaptureStatus?
    var retentionMessage: String?
    private(set) var retentionPreview: ScreenHistoryPrunePreview?
    private(set) var pendingRetentionPolicy: ScreenHistoryRetentionPolicy?
    private(set) var coastImportState: ScreenHistoryCoastImportState = .idle
    @ObservationIgnored private var approvedCoastPreview: ScreenHistoryCoastImportPreview?
    private(set) var retirementReviewSnapshot: ScreenHistoryRetirementReviewSnapshot?
    private(set) var retirementReviewMessage: String?
    var isRetirementReviewing = false
    private(set) var soakSummary: ScreenHistorySoakReceiptSummary?
    private(set) var soakMessage: String?
    private(set) var coastFreezeReceipt: ScreenHistoryCoastFreezeReceipt?
    private(set) var coastFreezeMessage: String?
    private(set) var coastFreezeIsRunning = false
    private(set) var settingsPresentedThisRun = false

    // MARK: - Dependencies

    var store: (any ScreenHistoryStoring)?
    var coastLegacyReader: (any CoastLegacyReading)?
    var captureService: ScreenHistoryCaptureService?
    var vaultSaver: (any ScreenHistoryVaultSaving)?
    var coastImporter: (any ScreenHistoryCoastImporting)?
    var retirementReviewer: (any ScreenHistoryRetirementReviewing)?
    var soakReceipt: (any ScreenHistorySoakReceipting)?
    var coastFreezeReceipter: (any ScreenHistoryCoastFreezeReceipting)?

    @ObservationIgnored weak var host: (any ScreenHistoryHost)?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var lastSoakRecordAt: Date?

    init(
        store: (any ScreenHistoryStoring)? = nil,
        coastLegacyReader: (any CoastLegacyReading)? = nil,
        captureService: ScreenHistoryCaptureService? = nil,
        vaultSaver: (any ScreenHistoryVaultSaving)? = nil,
        coastImporter: (any ScreenHistoryCoastImporting)? = nil,
        retirementReviewer: (any ScreenHistoryRetirementReviewing)? = nil,
        soakReceipt: (any ScreenHistorySoakReceipting)? = nil,
        coastFreezeReceipter: (any ScreenHistoryCoastFreezeReceipting)? = nil
    ) {
        self.store = store
        self.coastLegacyReader = coastLegacyReader
        self.captureService = captureService
        self.vaultSaver = vaultSaver
        self.coastImporter = coastImporter
        self.retirementReviewer = retirementReviewer
        self.soakReceipt = soakReceipt
        self.coastFreezeReceipter = coastFreezeReceipter
    }

    // MARK: - Host forwarding

    private var input: String {
        get { host?.input ?? "" }
        set { host?.input = newValue }
    }
    private var catalogScope: LauncherCatalogScope? {
        get { host?.catalogScope }
        set { host?.catalogScope = newValue }
    }
    private var inputMode: QuickViewModel.InputMode? {
        get { host?.inputMode }
        set { host?.inputMode = newValue }
    }
    private var settings: QuickSettings {
        get { host?.settings ?? QuickSettings() }
        set { host?.settings = newValue }
    }
    private var errorMessage: String? {
        get { host?.errorMessage }
        set { host?.errorMessage = newValue }
    }
    private var applicationSelectionIndex: Int {
        get { host?.applicationSelectionIndex ?? 0 }
        set { host?.applicationSelectionIndex = newValue }
    }
    private var overlayPresenter: any OverlayPresenting {
        host?.overlayPresenter ?? NotificationOverlayPresenter()
    }
    private var prepareForExternalAction: (() -> Void)? { host?.prepareForExternalAction }
    private func persistSettings(_ settings: QuickSettings) { host?.persistSettings(settings) }
    private func requestInputFocus() { host?.requestInputFocus() }
    private func invalidateLauncherRanking() { host?.invalidateLauncherRanking() }
    private func closeItemActionPane() { host?.closeItemActionPane() }

    // MARK: - Core hooks

    /// `enterCatalog(.screenHistory)`: fresh results, no timeline, no review.
    func enterCatalogScope() {
        isRetirementReviewing = false
        showsTimeline = false
        loadState = .idle
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.load(query: "")
        }
    }

    /// Backspace or Escape inside the catalog: a timeline closes first and
    /// keeps the catalog open. Returns `true` when it handled the key.
    func leaveCatalogIfTimeline() -> Bool {
        guard catalogScope == .screenHistory, showsTimeline else { return false }
        closeTimeline()
        return true
    }

    /// `reset(.layers)`: the save form's error goes with the pane.
    func resetForLayers() {
        saveError = nil
    }

    /// `reset(.mode)`: leaving the catalog drops the timeline and review.
    func resetForMode() {
        searchTask?.cancel()
        showsTimeline = false
        isRetirementReviewing = false
    }

    // MARK: - Catalog rows

    var items: [LauncherCatalogItem] {
        let frames = showsTimeline ? timelineFrames : frames
        return frames.map(item(for:))
    }

    func frame(for item: LauncherCatalogItem) -> ScreenHistoryFrame? {
        guard item.kind == .screenHistory else { return nil }
        return (showsTimeline ? timelineFrames : frames).first {
            itemID(for: $0) == item.itemID
        } ?? frames.first { itemID(for: $0) == item.itemID }
    }

    func ocrBoxes(for frame: ScreenHistoryFrame) -> [ScreenHistoryOCRBox] {
        ocrBoxesByFrameID[Self.stableID(for: frame)] ?? []
    }

    func loadOCRBoxes(for frame: ScreenHistoryFrame) async {
        let key = Self.stableID(for: frame)
        guard ocrBoxesByFrameID[key] == nil else { return }
        do {
            var boxes = try await store?.ocrBoxes(
                source: frame.source,
                sourceIdentifier: frame.sourceIdentifier
            ) ?? []
            if boxes.isEmpty, frame.source == .coast,
               let coastLegacyReader, await coastLegacyReader.isAvailable() {
                boxes = try await coastLegacyReader.ocrBoxes(
                    sourceIdentifier: frame.sourceIdentifier
                )
            }
            ocrBoxesByFrameID[key] = Array(boxes.prefix(1_000))
        } catch {
            ocrBoxesByFrameID[key] = []
        }
    }

    private func item(for frame: ScreenHistoryFrame) -> LauncherCatalogItem {
        let title = Self.stableTitle(for: frame)
        let excerpt = Self.excerpt(frame.ocrText, fallback: "No text found")
        let stamp = frame.capturedAt.formatted(date: .abbreviated, time: .shortened)
        let app = frame.application ?? "Unknown app"
        let source = frame.source == .owned ? "Owned" : "Coast"
        let locatorCue = (frame.imageLocator ?? frame.mediaLocator) == nil ? nil : "has-local-file"
        var context = [source, "Seen \(stamp)"]
        if isRetirementReviewing,
           let review = retirementReviewSnapshot?.moments.first(where: {
               $0.frame.sourceIdentifier == frame.sourceIdentifier
                   && $0.frame.contentHash == frame.contentHash
           }) {
            let reviewLabel: String
            switch review.decision {
            case .pending: reviewLabel = "Review pending"
            case .accepted: reviewLabel = "Accepted"
            case .flagged: reviewLabel = "Flagged"
            }
            context.append(reviewLabel)
        }
        if title.caseInsensitiveCompare(app) != .orderedSame { context.append(app) }
        context.append(excerpt)
        return LauncherCatalogItem(
            kind: .screenHistory,
            itemID: itemID(for: frame),
            title: title,
            detail: context.joined(separator: " · "),
            value: String(frame.ocrText.prefix(12_000)),
            keywords: [frame.application, frame.domain, frame.windowTitle, source, locatorCue].compactMap { $0 }.joined(separator: " "),
            capturedAt: frame.capturedAt
        )
    }

    private func itemID(for frame: ScreenHistoryFrame) -> String {
        Self.stableID(for: frame)
    }

    nonisolated private static func stableID(for frame: ScreenHistoryFrame) -> String {
        "\(frame.source.rawValue):\(frame.sourceIdentifier)"
    }

    private static func excerpt(_ text: String, fallback: String) -> String {
        let flattened = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        let value = flattened.isEmpty ? fallback : flattened
        return value.count > 220 ? String(value.prefix(217)) + "…" : value
    }

    nonisolated private static func stableTitle(for frame: ScreenHistoryFrame) -> String {
        for candidate in [frame.windowTitle, frame.application, frame.domain] {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !value.isEmpty { return value }
        }
        return "Screen moment"
    }

    func startStatusObservation() {
        statusTask?.cancel()
        guard let captureService else { return }
        statusTask = Task { [weak self] in
            let updates = await captureService.statusUpdates()
            for await status in updates {
                guard !Task.isCancelled, let self else { return }
                self.captureStatus = status
                self.invalidateLauncherRanking()
                await self.recordSoakSnapshot(status: status)
            }
        }
    }

    private func recordSoakSnapshot(status: ScreenHistoryCaptureStatus) async {
        guard let soakReceipt else { return }
        let now = Date()
        let isActive = status.state == .running || status.state == .pausedForInactivity
        if isActive,
           let lastSoakRecordAt,
           now.timeIntervalSince(lastSoakRecordAt) < 300 {
            return
        }
        let gauge = await Task.detached(priority: .utility) {
            Self.ownedStorageGauge()
        }.value
        let failures: Set<ScreenHistorySoakFailureCode> = gauge.succeeded
            ? [] : [.storageObservationFailed]
        do {
            let summary = try await soakReceipt.record(ScreenHistorySoakSnapshot(
                observedAt: now,
                captureStatus: status,
                storageBytes: gauge.bytes,
                storageFiles: gauge.files,
                processEvent: lastSoakRecordAt == nil ? .cleanRestart : .none,
                newFailures: failures,
                resolvedFailures: gauge.succeeded ? [.storageObservationFailed] : []
            ))
            lastSoakRecordAt = now
            soakSummary = summary
            soakMessage = summary.isReadyForCoastRetirement
                ? "Seven-day soak gate passed."
                : "Soak: \(summary.activeDayCount) of 7 active days; \(summary.readinessBlockers.count) gates remain."
        } catch {
            soakMessage = "Unable to update the content-free soak receipt."
        }
    }

    private nonisolated static func ownedStorageGauge() -> (
        bytes: Int64,
        files: Int,
        succeeded: Bool
    ) {
        let root = SQLiteScreenHistoryStore.defaultDatabaseURL().deletingLastPathComponent()
        let allowedNames = Set([
            "screen-history.sqlite3",
            "screen-history.sqlite3-wal",
            "screen-history.sqlite3-shm",
            "Screen History Frames",
            "Screen History Legacy Media",
        ])
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0, false) }
        var bytes: Int64 = 0
        var files = 0
        for entry in entries where allowedNames.contains(entry.lastPathComponent) {
            if let enumerator = manager.enumerator(
                at: entry,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let file as URL in enumerator {
                    guard let values = try? file.resourceValues(
                        forKeys: [.isRegularFileKey, .fileSizeKey]
                    ), values.isRegularFile == true else { continue }
                    files += 1
                    bytes += Int64(values.fileSize ?? 0)
                }
            } else if let values = try? entry.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), values.isRegularFile == true {
                files += 1
                bytes += Int64(values.fileSize ?? 0)
            }
        }
        return (bytes, files, true)
    }

    func setAnnouncement(_ announcement: String) {
        resultAnnouncement = announcement
        announcementRevision &+= 1
    }

    func announceActionSelection(_ action: ItemAction, position: Int, total: Int) {
        guard catalogScope == .screenHistory else { return }
        setAnnouncement("\(action.title), selected, \(position) of \(total).")
    }

    func saveNote(
        for result: LauncherSearchResult,
        projectSlug: String,
        note: String
    ) async -> Bool {
        guard case .item(let item) = result,
              let frame = self.frame(for: item),
              let vaultSaver
        else {
            saveError = "Save to Vault is unavailable. Check the local vault helper and try again."
            return false
        }
        let cleanProject = projectSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await vaultSaver.save(
                frame,
                note: cleanNote.isEmpty ? nil : cleanNote,
                projectSlug: cleanProject.isEmpty ? nil : cleanProject
            )
            saveError = nil
            closeItemActionPane()
            setAnnouncement("Saved this screen moment to Vault triage.")
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    /// Called by the input field after each edit. Root typing stays free of
    /// Screen History I/O; only the open catalog schedules a local query.
    func inputDidChange(debounce: Duration = .zero) {
        guard catalogScope == .screenHistory,
              !showsTimeline,
              !isRetirementReviewing else { return }
        let query = input
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            if debounce != .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled else { return }
            await self?.load(query: query)
        }
    }

    func load(query: String, now: Date = Date(), calendar: Calendar = .current) async {
        guard catalogScope == .screenHistory else { return }
        guard !isRetirementReviewing else { return }
        let decision = ScreenHistoryQueryParser.parse(query, now: now, calendar: calendar)
        switch decision {
        case .refuseFuture:
            frames = []
            loadState = .refusedFuture
            setAnnouncement("Future screen activity cannot be known.")
            invalidateLauncherRanking()
            return
        case .routeVaultSearch:
            frames = []
            loadState = .routedToVaultSearch
            setAnnouncement("Use Vault Search for current project status.")
            invalidateLauncherRanking()
            return
        case .search(let parsed):
            await runSearch(parsed)
        }
    }

    private func runSearch(_ parsed: ScreenHistoryParsedQuery) async {
        let ownedStore = store
        let coast = settings.searchLegacyCoastHistory ? coastLegacyReader : nil
        let coastIsAvailable = await coast?.isAvailable() ?? false
        guard ownedStore != nil || coastIsAvailable else {
            frames = []
            loadState = .unavailable
            setAnnouncement("Screen History is unavailable on this Mac.")
            invalidateLauncherRanking()
            return
        }

        let loadingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.loadState = .loading
        }
        defer { loadingTask.cancel() }

        do {
            let ownedRows = try await ownedStore?.search(parsed.storageQuery) ?? []
            var coastRows: [ScreenHistoryFrame] = []
            if let coast, coastIsAvailable {
                coastRows = try await coast.search(parsed.storageQuery)
            }
            let excludedBundles = Set(settings.screenHistoryExcludedBundleIDs)
            let excludedDomains = Set(settings.screenHistoryExcludedDomains)
            let merged = ownedRows + coastRows
            let unique = Dictionary(grouping: merged, by: { Self.stableID(for: $0) })
                .compactMap { $0.value.first }
                .filter {
                    ScreenHistoryPrivacyPolicy.allowsSearchResult(
                        $0,
                        excludedBundleIdentifiers: excludedBundles,
                        excludedDomains: excludedDomains
                    )
                }
                .sorted {
                    if $0.capturedAt == $1.capturedAt { return Self.stableID(for: $0) < Self.stableID(for: $1) }
                    return $0.capturedAt > $1.capturedAt
                }
            guard !Task.isCancelled else { return }
            frames = Array(unique.prefix(50))
            loadState = .ready
            setAnnouncement(unique.count == 1
                ? "1 screen history result"
                : "\(unique.count) screen history results")
        } catch {
            guard !Task.isCancelled else { return }
            frames = []
            loadState = .failed("Unable to search Screen History. Check the local store and try again.")
            setAnnouncement("Screen History search failed.")
        }
        applicationSelectionIndex = 0
        invalidateLauncherRanking()
    }

    func openSequence(for frame: ScreenHistoryFrame) async {
        let radius: TimeInterval = 10 * 60
        let from = frame.capturedAt.addingTimeInterval(-radius)
        let through = frame.capturedAt.addingTimeInterval(radius)
        do {
            let owned = try await store?.search(
                ScreenHistorySearchQuery(from: from, through: through, limit: 200)
            ) ?? []
            var coast: [ScreenHistoryFrame] = []
            if settings.searchLegacyCoastHistory, let coastLegacyReader,
               await coastLegacyReader.isAvailable() {
                coast = try await coastLegacyReader.moments(from: from, through: through, limit: 200)
            }
            let excludedBundles = Set(settings.screenHistoryExcludedBundleIDs)
            let excludedDomains = Set(settings.screenHistoryExcludedDomains)
            let candidates = (owned + coast).filter {
                ScreenHistoryPrivacyPolicy.allowsSearchResult(
                    $0,
                    excludedBundleIdentifiers: excludedBundles,
                    excludedDomains: excludedDomains
                )
            }
            timelineFrames = ScreenHistoryTimeline.sequence(around: frame, in: candidates)
            if timelineFrames.isEmpty { timelineFrames = [frame] }
            showsTimeline = true
            queryBeforeTimeline = input
            input = ""
            applicationSelectionIndex = timelineFrames.firstIndex {
                $0.source == frame.source && $0.sourceIdentifier == frame.sourceIdentifier
            } ?? 0
            setAnnouncement("\(timelineFrames.count) moments in this timeline")
            invalidateLauncherRanking()
        } catch {
            loadState = .failed("Unable to open this timeline. Try again.")
        }
    }

    func closeTimeline() {
        guard showsTimeline else { return }
        showsTimeline = false
        timelineFrames = []
        input = queryBeforeTimeline
        queryBeforeTimeline = ""
        applicationSelectionIndex = 0
        invalidateLauncherRanking()
        requestInputFocus()
    }

    func openMoment(_ frame: ScreenHistoryFrame) {
        guard let locator = frame.imageLocator ?? frame.mediaLocator,
              Self.validLocator(locator) else {
            errorMessage = "No local preview is available for this moment."
            requestInputFocus()
            return
        }
        Task { [weak self] in
            guard let self,
                  let previewURL = await ScreenHistoryMediaPreviewService.materializedMomentURL(
                    for: frame
                  ) else {
                self?.errorMessage = "No exact local preview is available for this moment."
                self?.requestInputFocus()
                return
            }
            self.prepareForExternalAction?()
            NSWorkspace.shared.open(previewURL)
            overlayPresenter.dismissOverlay()
        }
    }

    func revealMoment(_ frame: ScreenHistoryFrame) {
        guard let locator = frame.imageLocator ?? frame.mediaLocator,
              Self.validLocator(locator) else {
            errorMessage = "No local file is available for this moment."
            requestInputFocus()
            return
        }
        prepareForExternalAction?()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: locator)])
        overlayPresenter.dismissOverlay()
    }

    private static func validLocator(_ locator: String) -> Bool {
        guard locator.hasPrefix("/"), !locator.contains("\0") else { return false }
        let standardized = URL(fileURLWithPath: locator).standardizedFileURL.path
        let ownedRoot = SQLiteScreenHistoryStore.defaultDatabaseURL().deletingLastPathComponent().path + "/"
        let coastRoot = CoastLegacyReader.defaultDatabaseURL().deletingLastPathComponent().path + "/"
        return standardized.hasPrefix(ownedRoot) || standardized.hasPrefix(coastRoot)
    }

    func applyCaptureSettings(startIfConfirmed: Bool = false) async {
        guard let captureService else {
            captureStatus = nil
            return
        }
        let configuration = ScreenHistoryCaptureConfiguration(
            isEnabled: ScreenHistoryReleasePolicy.allowsOwnedCapture
                && settings.screenHistoryCaptureEnabled,
            excludedBundleIdentifiers: Set(settings.screenHistoryExcludedBundleIDs),
            excludedDomains: Set(settings.screenHistoryExcludedDomains)
        )
        await captureService.updateConfiguration(configuration)
        _ = await captureService.refreshSecurityStatus()
        if startIfConfirmed, settings.screenHistoryCaptureEnabled, settings.screenHistoryCaptureConfirmed,
           captureStartBlocker == nil {
            await captureService.start()
        } else if !settings.screenHistoryCaptureEnabled {
            await captureService.stop()
        }
        captureStatus = await captureService.status()
        invalidateLauncherRanking()
    }

    func prepareCaptureForBootstrap() async {
        startStatusObservation()
        settingsPresentedThisRun = false
        settings.screenHistoryCaptureConfirmed = false
        persistSettings(settings)
        await captureService?.stop()
        await applyCaptureSettings(startIfConfirmed: false)
    }

    func noteSettingsPresented() {
        settingsPresentedThisRun = true
    }

    func requestScreenRecordingAuthorization() async {
        guard let captureService else {
            errorMessage = "Screen History capture is unavailable in this build."
            return
        }
        let authorized = await captureService.requestScreenRecordingAuthorization()
        captureStatus = await captureService.status()
        errorMessage = authorized
            ? nil
            : "Screen Recording is still off. Enable Quick Launch in System Settings, then reopen the app."
        invalidateLauncherRanking()
    }

    func confirmAndStartCapture() async {
        guard ScreenHistoryReleasePolicy.allowsOwnedCapture else {
            errorMessage = "Owned capture is locked in this search-only beta."
            return
        }
        guard settings.screenHistoryCaptureEnabled else { return }
        guard settingsPresentedThisRun else {
            errorMessage = "Open Screen History settings before starting capture."
            return
        }
        await applyCaptureSettings()
        guard captureStartBlocker == nil else {
            errorMessage = captureStartBlocker
            return
        }
        settings.screenHistoryCaptureConfirmed = true
        persistSettings(settings)
        await applyCaptureSettings(startIfConfirmed: true)
        guard captureStatus?.state == .running else {
            settings.screenHistoryCaptureConfirmed = false
            persistSettings(settings)
            errorMessage = captureStartBlocker
                ?? "Unable to start Screen History. Capture stays stopped."
            return
        }
        errorMessage = nil
    }

    func stopCapture() async {
        settings.screenHistoryCaptureConfirmed = false
        persistSettings(settings)
        await captureService?.stop()
        captureStatus = await captureService?.status()
        invalidateLauncherRanking()
    }

    /// Stops the active loop without clearing this run's explicit consent.
    /// The Commands catalog can resume it without opening Settings again.
    func pauseCapture() async {
        await captureService?.stop()
        captureStatus = await captureService?.status()
        invalidateLauncherRanking()
    }

    func toggleCaptureFromCommand() async {
        guard ScreenHistoryReleasePolicy.allowsOwnedCapture else {
            errorMessage = "Owned capture is locked in this search-only beta."
            requestInputFocus()
            return
        }
        if captureIsActive {
            await pauseCapture()
            return
        }
        guard settings.screenHistoryCaptureEnabled,
              settings.screenHistoryCaptureConfirmed,
              settingsPresentedThisRun
        else {
            errorMessage = "Start Screen History once in Settings before using Resume."
            requestInputFocus()
            return
        }
        await applyCaptureSettings(startIfConfirmed: true)
        if captureStatus?.state != .running {
            errorMessage = captureStartBlocker
                ?? "Unable to resume Screen History. Capture stays stopped."
            requestInputFocus()
        }
    }

    func applyRetention(now: Date = Date()) async {
        guard let store else { return }
        do {
            let policy = ScreenHistoryRetentionPolicy(
                retentionDays: settings.screenHistoryRetentionDays,
                storageCapBytes: Int64(settings.screenHistoryStorageCapGB) * 1_024 * 1_024 * 1_024
            )
            let result = try await store.prune(policy: policy, now: now)
            if result.retryRequired {
                retentionMessage = "Retention will retry \(result.pendingRows) records and \(result.pendingLocators) files. No searchable record was removed early."
            } else if result.rowsRemoved == 0 {
                retentionMessage = "Retention is current."
            } else {
                retentionMessage = "Removed \(result.rowsRemoved) old records and \(result.filesRemoved) owned files."
            }
        } catch {
            retentionMessage = "Unable to apply Screen History retention."
        }
    }

    var retentionDaysSelection: Int {
        get { pendingRetentionPolicy?.retentionDays ?? settings.screenHistoryRetentionDays }
        set {
            let capGB = pendingRetentionPolicy?.storageCapBytes.map {
                Int($0 / 1_024 / 1_024 / 1_024)
            } ?? settings.screenHistoryStorageCapGB
            Task { await previewRetention(days: newValue, capGB: capGB) }
        }
    }

    var storageCapGBSelection: Int {
        get {
            pendingRetentionPolicy?.storageCapBytes.map {
                Int($0 / 1_024 / 1_024 / 1_024)
            } ?? settings.screenHistoryStorageCapGB
        }
        set {
            let days = pendingRetentionPolicy?.retentionDays
                ?? settings.screenHistoryRetentionDays
            Task { await previewRetention(days: days, capGB: newValue) }
        }
    }

    func previewRetention(days: Int, capGB: Int, now: Date = Date()) async {
        guard let store else { return }
        let policy = ScreenHistoryRetentionPolicy(
            retentionDays: days,
            storageCapBytes: Int64(capGB) * 1_024 * 1_024 * 1_024
        )
        do {
            let preview = try await store.previewPrune(policy: policy, now: now)
            pendingRetentionPolicy = policy
            retentionPreview = preview
            if preview.rowsPlanned == 0 {
                retentionMessage = "This change removes no current history. Apply it to save the new limits."
            } else {
                let range: String
                if let earliest = preview.earliestRemoval, let latest = preview.latestRemoval {
                    range = "\(earliest.formatted(date: .abbreviated, time: .omitted)) to \(latest.formatted(date: .abbreviated, time: .omitted))"
                } else {
                    range = "the selected range"
                }
                retentionMessage = "Review before applying: remove \(preview.rowsPlanned) records and \(preview.ownedFilesPlanned) owned files from \(range), freeing about \(ByteCountFormatter.string(fromByteCount: preview.bytesPlanned, countStyle: .file))."
            }
        } catch {
            retentionMessage = "Unable to preview Screen History retention. Nothing changed."
            pendingRetentionPolicy = nil
            retentionPreview = nil
        }
    }

    func applyReviewedRetention(now: Date = Date()) async {
        guard let policy = pendingRetentionPolicy,
              retentionPreview?.policy == policy else {
            retentionMessage = "Preview the retention change before applying it."
            return
        }
        settings.screenHistoryRetentionDays = policy.retentionDays
            ?? settings.screenHistoryRetentionDays
        if let bytes = policy.storageCapBytes {
            settings.screenHistoryStorageCapGB = Int(bytes / 1_024 / 1_024 / 1_024)
        }
        persistSettings(settings)
        pendingRetentionPolicy = nil
        retentionPreview = nil
        await applyRetention(now: now)
    }

    func refreshCoastImportAvailability() async {
        guard let coastImporter else {
            coastImportState = .unavailable
            return
        }
        switch coastImportState {
        case .completed, .failed, .previewReady, .previewInvalidated, .previewingMetadata,
                .importingMetadata, .copyingVerifiedMedia, .preparingVerificationSample:
            return
        case .idle, .checkingSource, .ready, .unavailable:
            break
        }
        coastImportState = .checkingSource
        coastImportState = await coastImporter.sourceIsAvailable()
            ? .ready
            : .unavailable
    }

    /// Reads Coast metadata and applies the current exclusion policy without
    /// writing an owned row or opening any media file. Import remains disabled
    /// until this exact policy and source snapshot has been reviewed.
    func previewCoastImport() async {
        guard let coastImporter else {
            coastImportState = .unavailable
            return
        }

        await stopCapture()
        approvedCoastPreview = nil
        guard await coastImporter.sourceIsAvailable() else {
            coastImportState = .unavailable
            return
        }

        coastImportState = .previewingMetadata
        do {
            let preview = try await coastImporter.previewMetadata(
                policy: settings.screenHistoryMigrationPolicy
            )
            guard preview.reconciles,
                  preview.policyFingerprint == settings.screenHistoryMigrationPolicy.fingerprint
            else {
                coastImportState = .failed(.preview)
                return
            }
            approvedCoastPreview = preview
            coastImportState = .previewReady(preview)
        } catch {
            coastImportState = .failed(.preview)
        }
    }

    func freezeCoastSourceForImport() async {
        guard let coastFreezeReceipter else {
            coastFreezeMessage = "Coast freeze receipt is unavailable in this build."
            return
        }
        await stopCapture()
        coastFreezeIsRunning = true
        coastFreezeMessage = "Hashing the stopped Coast source. No screen content is opened."
        defer { coastFreezeIsRunning = false }
        do {
            let progress = try await coastFreezeReceipter.makePrimaryReceipt(
                maximumNewFiles: nil
            )
            guard progress.isComplete, let receipt = progress.receipt else {
                coastFreezeMessage = "Coast freeze is incomplete. Run it again to resume."
                return
            }
            coastFreezeReceipt = receipt
            coastFreezeMessage = "Coast source frozen: \(receipt.primary.database.counts.frames) frames and \(receipt.primary.files.count) files hashed."
        } catch ScreenHistoryCoastFreezeReceiptError.sourceIsActive {
            coastFreezeMessage = "Close Coast before freezing its source."
        } catch {
            coastFreezeMessage = "Unable to freeze Coast safely. No import was authorized."
        }
    }

    func refreshCoastFreezeReceipt() async {
        guard let coastFreezeReceipter else { return }
        do {
            coastFreezeReceipt = try await coastFreezeReceipter.currentReceipt()
            if let receipt = coastFreezeReceipt {
                coastFreezeMessage = "Coast source freeze is available for \(receipt.primary.database.counts.frames) frames."
            }
        } catch {
            coastFreezeMessage = "The Coast freeze receipt failed its integrity check."
        }
    }

    /// Exclusion edits revoke the reviewed authorization immediately. The
    /// importer also verifies this fingerprint before any owned write.
    func invalidateCoastImportPreview() {
        guard approvedCoastPreview != nil else { return }
        approvedCoastPreview = nil
        coastImportState = .previewInvalidated
        let importer = coastImporter
        Task { await importer?.invalidatePreview() }
    }

    /// Runs only after the visible Settings button is pressed. Capture is
    /// stopped first. Coast remains read-only, and another press resumes from
    /// the migration ledgers if a prior run stopped.
    func importCoastHistory() async {
        guard let coastImporter else {
            coastImportState = .unavailable
            return
        }

        await stopCapture()
        if coastFreezeReceipter != nil,
           coastFreezeReceipt == nil {
            coastImportState = .previewInvalidated
            coastFreezeMessage = "Freeze the Coast source before importing."
            return
        }
        guard let preview = approvedCoastPreview,
              preview.policyFingerprint == settings.screenHistoryMigrationPolicy.fingerprint
        else {
            approvedCoastPreview = nil
            coastImportState = .previewInvalidated
            return
        }
        guard await coastImporter.sourceIsAvailable() else {
            coastImportState = .unavailable
            return
        }

        coastImportState = .importingMetadata
        let metadata: ScreenHistoryMigrationResult
        do {
            metadata = try await coastImporter.importMetadata(
                preview: preview,
                policy: settings.screenHistoryMigrationPolicy
            )
            guard metadata.reconciles else {
                coastImportState = .failed(.metadata)
                return
            }
            approvedCoastPreview = nil
        } catch ScreenHistoryCoastImportError.stalePreview,
                ScreenHistoryCoastImportError.sourceChanged {
            approvedCoastPreview = nil
            coastImportState = .previewInvalidated
            return
        } catch {
            coastImportState = .failed(.metadata)
            return
        }

        coastImportState = .copyingVerifiedMedia
        let media: ScreenHistoryMediaMigrationResult
        do {
            media = try await coastImporter.copyVerifiedMedia()
            guard media.failures.isEmpty else {
                coastImportState = .failed(.media)
                return
            }
        } catch {
            coastImportState = .failed(.media)
            return
        }

        coastImportState = .preparingVerificationSample
        let sampleCount: Int
        do {
            if let retirementReviewer {
                let review = try await retirementReviewer.refresh()
                retirementReviewSnapshot = review
                sampleCount = review.moments.count
                let required = min(
                    metadata.imported,
                    ScreenHistoryRetirementReadiness.requiredSampleSize
                )
                guard review.readiness.hasCompleteImportedPopulation,
                      sampleCount == required
                else {
                    coastImportState = .failed(.verificationSample)
                    return
                }
            } else {
                sampleCount = try await coastImporter.verificationSampleCount(
                    limit: ScreenHistoryCoastImportSummary.verificationSampleTarget
                )
                guard sampleCount == ScreenHistoryCoastImportSummary.verificationSampleTarget else {
                    coastImportState = .failed(.verificationSample)
                    return
                }
            }
        } catch {
            coastImportState = .failed(.verificationSample)
            return
        }

        coastImportState = .completed(ScreenHistoryCoastImportSummary(
            sourceRows: metadata.source,
            importedRows: metadata.imported,
            excludedRows: metadata.excluded,
            invalidRows: metadata.invalid,
            newOwnedRows: metadata.ownedRowDelta,
            copiedFiles: media.copiedFileDelta,
            mediaFailures: media.failures.count,
            verificationSampleCount: sampleCount
        ))
        await applyRetention()
    }

    func refreshRetirementReview() async {
        guard let retirementReviewer else {
            retirementReviewMessage = "Coast review is unavailable in this build."
            return
        }
        do {
            let snapshot = try await retirementReviewer.refresh()
            retirementReviewSnapshot = snapshot
            retirementReviewMessage = Self.reviewMessage(for: snapshot)
        } catch {
            retirementReviewMessage = "Unable to prepare the Coast review sample."
        }
    }

    func openRetirementReview() async {
        await refreshRetirementReview()
        guard let snapshot = retirementReviewSnapshot,
              !snapshot.moments.isEmpty else { return }
        searchTask?.cancel()
        isRetirementReviewing = true
        showsTimeline = false
        timelineFrames = []
        frames = snapshot.moments.map(\.frame)
        loadState = .ready
        catalogScope = .screenHistory
        inputMode = nil
        input = ""
        applicationSelectionIndex = snapshot.moments.firstIndex {
            $0.decision == .pending
        } ?? 0
        setAnnouncement(
            "Coast review. \(snapshot.readiness.acceptedMoments) accepted, \(snapshot.readiness.pendingMoments) pending, \(snapshot.readiness.flaggedMoments) flagged."
        )
        overlayPresenter.presentOverlay()
        requestInputFocus()
    }

    func decideRetirementMoment(
        frame: ScreenHistoryFrame,
        decision: ScreenHistoryRetirementReviewDecision
    ) async {
        guard isRetirementReviewing,
              let retirementReviewer else { return }
        let sampleID = "coast:\(frame.sourceIdentifier)"
        do {
            let snapshot = try await retirementReviewer.decide(
                sampleID: sampleID,
                contentHash: frame.contentHash,
                decision: decision
            )
            retirementReviewSnapshot = snapshot
            frames = snapshot.moments.map(\.frame)
            retirementReviewMessage = Self.reviewMessage(for: snapshot)
            closeItemActionPane()
            if let next = snapshot.moments.firstIndex(where: { $0.decision == .pending }) {
                applicationSelectionIndex = next
            }
            setAnnouncement(
                decision == .accepted
                    ? "Accepted this imported moment."
                    : "Flagged this imported moment for review."
            )
        } catch {
            retirementReviewMessage = "The review sample changed. Refresh it before continuing."
        }
    }

    private static func reviewMessage(
        for snapshot: ScreenHistoryRetirementReviewSnapshot
    ) -> String {
        let readiness = snapshot.readiness
        if readiness.totalImportedMoments == 0 {
            return "No imported Coast moments are ready for review."
        }
        if readiness.isReady {
            return "Coast review passed: \(readiness.acceptedMoments) accepted and no flags."
        }
        return "Coast review: \(readiness.acceptedMoments) accepted, \(readiness.pendingMoments) pending, \(readiness.flaggedMoments) flagged."
    }

    var coastImportIsRunning: Bool {
        switch coastImportState {
        case .checkingSource, .previewingMetadata, .importingMetadata,
                .copyingVerifiedMedia, .preparingVerificationSample:
            return true
        case .idle, .ready, .unavailable, .previewReady, .previewInvalidated,
                .completed, .failed:
            return false
        }
    }

    var coastImportCanImport: Bool {
        if coastFreezeReceipter != nil,
           coastFreezeReceipt == nil { return false }
        guard let preview = approvedCoastPreview,
              preview.policyFingerprint == settings.screenHistoryMigrationPolicy.fingerprint
        else { return false }
        guard case .previewReady(let visiblePreview) = coastImportState else { return false }
        return visiblePreview == preview
    }

    var coastImportMessage: String? {
        switch coastImportState {
        case .idle:
            return nil
        case .checkingSource:
            return "Checking for Coast history…"
        case .ready:
            return "Coast history is available. Preview the current exclusions before import. Coast stays unchanged."
        case .unavailable:
            return "No usable Coast history was found on this Mac."
        case .previewingMetadata:
            return "Previewing Coast text and metadata with the current exclusions. Nothing is being written, and media stays closed."
        case .previewReady(let preview):
            return "Preview: \(preview.sourceRows) source records. \(preview.importedRows) will import, \(preview.excludedRows) are excluded, and \(preview.invalidRows) are invalid. Review these counts, then use the separate Import button."
        case .previewInvalidated:
            return "The Coast preview expired because the exclusions or source changed. Run Preview again before import."
        case .importingMetadata:
            return "Importing Coast text and metadata. Capture is stopped."
        case .copyingVerifiedMedia:
            return "Copying and checking Coast media. Source files stay unchanged."
        case .preparingVerificationSample:
            return "Preparing a 100-moment metadata sample for later review."
        case .completed(let result):
            return "Imported \(result.importedRows) of \(result.sourceRows) Coast records. Added \(result.newOwnedRows) records and \(result.copiedFiles) verified media files. Prepared \(result.verificationSampleCount) of \(result.verificationSampleTarget) moments for review. \(result.mediaFailures) media files need retry. Coast stays unchanged."
        case .failed(.metadata):
            return "Import stopped while reading metadata. Coast stayed unchanged. Run Preview again before resuming."
        case .failed(.preview):
            return "Coast preview stopped before any import write. Coast stayed unchanged. Run Preview again."
        case .failed(.media):
            return "Metadata is safe, but media copying stopped. Coast stayed unchanged. Run Preview again to resume."
        case .failed(.verificationSample):
            return "The import is safe, but the 100-moment review sample was not prepared. Coast stayed unchanged. Run Preview again."
        }
    }

    var captureStartBlocker: String? {
        guard ScreenHistoryReleasePolicy.allowsOwnedCapture else {
            return "Owned capture is locked in this search-only beta."
        }
        guard captureService != nil else {
            return "Screen History capture is unavailable in this build."
        }
        guard settings.screenHistorySameUserAccessRiskAccepted else {
            return "Review and accept the same-user storage risk before capture."
        }
        if captureStatus?.lastSkipReason == .screenRecordingNotAuthorized {
            return "Allow Screen Recording for Quick Launch in System Settings before capture."
        }
        switch captureStatus?.fileVaultStatus {
        case .on:
            return nil
        case .off:
            return "Turn on FileVault before starting Screen History."
        case .unknown, nil:
            return "Quick Launch could not verify FileVault. Capture stays stopped."
        }
    }

    var captureIsActive: Bool {
        ScreenHistoryReleasePolicy.allowsOwnedCapture
            && (captureStatus?.state == .running
            || captureStatus?.state == .pausedForInactivity
            )
    }

    var captureCanResume: Bool {
        ScreenHistoryReleasePolicy.allowsOwnedCapture
            && captureService != nil
            && settings.screenHistoryCaptureEnabled
            && captureStartBlocker == nil
    }

    var menuBarCanBeHidden: Bool {
        !captureIsActive
    }

    var captureStatusLabel: String {
        guard ScreenHistoryReleasePolicy.allowsOwnedCapture else { return "Capture unavailable" }
        switch captureStatus?.state {
        case .running: return "Running"
        case .pausedForInactivity: return "Paused"
        case .stopped, .disabled: return "Stopped"
        case nil: return captureService == nil ? "Capture unavailable" : "Stopped"
        }
    }
}
