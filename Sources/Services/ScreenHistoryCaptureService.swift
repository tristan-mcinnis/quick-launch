import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import Vision

struct ScreenHistoryCaptureConfiguration: Equatable, Sendable {
    static let ownBundleIdentifier = "com.tristanmcinnis.quick-launch"
    /// The cadence every capture caller falls back to when none is chosen.
    static let defaultCadenceSeconds: TimeInterval = 3
    static let minimumCadenceSeconds: TimeInterval = 2
    static let maximumCadenceSeconds: TimeInterval = 60
    static let minimumInactivityThresholdSeconds: TimeInterval = 60
    static let safeDefaultExcludedBundleIdentifiers: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.apple.passwords",
        "com.bitwarden.desktop",
        "com.dashlane.dashlane",
        "com.lastpass.lastpassmacdesktop",
        "com.nordsec.nordpass",
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.authy.authy-mac",
        "com.objective-see.blockblock",
        "com.objective-see.knockknock",
        "com.objective-see.lulu",
        "me.proton.pass",
        "org.keepassxc.keepassxc",
    ]
    /// These apps are capture-only exclusions. Existing imported history stays
    /// searchable unless the user also adds the app to their exclusion list.
    static let safeDefaultCaptureOnlyExcludedBundleIdentifiers: Set<String> = [
        "com.apple.facetime",
        "com.apple.quicktimeplayerx",
        "com.apple.remotedesktop",
        "com.apple.screensharing",
        "com.cisco.webexmeetingsapp",
        "com.cisco.webex2",
        "com.carriez.rustdesk",
        "com.hnc.discord",
        "com.loom.desktop",
        "com.microsoft.rdc.macos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.obsproject.obs-studio",
        "com.philandro.anydesk",
        "com.teamviewer.teamviewer",
        "com.tencent.meeting",
        "com.tencent.meeting.macos",
        "us.zoom.xos",
    ]
    static let safeDefaultExcludedDomains: Set<String> = [
        "accounts.google.com",
        "appleid.apple.com",
        "bankofamerica.com",
        "chase.com",
        "citibank.com",
        "dbs.com",
        "hsbc.com",
        "icbc.com.cn",
        "interactivebrokers.com",
        "login.microsoftonline.com",
        "paypal.com",
        "revolut.com",
        "stripe.com",
        "wise.com",
    ]

    var isEnabled: Bool
    var cadenceSeconds: TimeInterval
    var inactivityThresholdSeconds: TimeInterval
    var excludedBundleIdentifiers: Set<String>
    var excludedDomains: Set<String>

    init(
        isEnabled: Bool = false,
        cadenceSeconds: TimeInterval = Self.defaultCadenceSeconds,
        inactivityThresholdSeconds: TimeInterval = 5 * 60,
        excludedBundleIdentifiers: Set<String> = Self.safeDefaultExcludedBundleIdentifiers,
        excludedDomains: Set<String> = Self.safeDefaultExcludedDomains
    ) {
        self.isEnabled = isEnabled
        self.cadenceSeconds = min(
            max(cadenceSeconds, Self.minimumCadenceSeconds),
            Self.maximumCadenceSeconds
        )
        self.inactivityThresholdSeconds = max(
            inactivityThresholdSeconds,
            Self.minimumInactivityThresholdSeconds
        )
        self.excludedBundleIdentifiers = Set(
            excludedBundleIdentifiers.compactMap(Self.normalizedBundleIdentifier)
        )
        self.excludedDomains = Set(excludedDomains.compactMap(Self.normalizedDomain))
            .union(Self.safeDefaultExcludedDomains)
    }

    func excludes(_ bundleIdentifier: String) -> Bool {
        let normalized = Self.normalizedBundleIdentifier(bundleIdentifier) ?? ""
        return normalized == Self.ownBundleIdentifier
            || Self.safeDefaultExcludedBundleIdentifiers.contains(normalized)
            || Self.safeDefaultCaptureOnlyExcludedBundleIdentifiers.contains(normalized)
            || excludedBundleIdentifiers.contains(normalized)
    }

    static func normalizedBundleIdentifier(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedDomain(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var host = URLComponents(string: candidate)?.host?.lowercased() else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        while host.hasPrefix(".") { host.removeFirst() }
        return host.isEmpty ? nil : host
    }

    static func matches(domain: String, rules: Set<String>) -> Bool {
        guard let domain = normalizedDomain(domain) else { return true }
        return rules.contains { rawRule in
            guard let rule = normalizedDomain(rawRule) else { return false }
            return domain == rule || domain.hasSuffix(".\(rule)")
        }
    }
}

enum ScreenHistoryCaptureState: Equatable, Sendable {
    case disabled
    case stopped
    case running
    case pausedForInactivity
}

enum ScreenHistoryCaptureSkipReason: Equatable, Sendable {
    case fileVault(FileVaultStatus)
    case screenRecordingNotAuthorized
    case storageFailure
    case inactive
    case noFrontWindow
    case unknownBundleIdentifier
    case excludedBundleIdentifier(String)
    case protectedSurface
    case oversizedImage
    case unchanged
    case sourceFailure
    case protectedSession(ScreenHistoryProtectedSessionStatus)
}

struct ScreenHistoryCaptureMetrics: Equatable, Sendable {
    var cycles = 0
    var fileVaultBlockedCycles = 0
    var screenRecordingBlockedCycles = 0
    var storageFailures = 0
    var emittedFrames = 0
    var inactiveCycles = 0
    var excludedFrames = 0
    var unknownApplicationFrames = 0
    var duplicateFrames = 0
    var sourceFailures = 0
    var protectedSessionCycles = 0
    var lockedSessionCycles = 0
    var offConsoleSessionCycles = 0
    var activeDisplayCaptureCycles = 0
    var unknownSessionCycles = 0
}

struct ScreenHistoryCaptureStatus: Equatable, Sendable {
    let state: ScreenHistoryCaptureState
    let lastSkipReason: ScreenHistoryCaptureSkipReason?
    let metrics: ScreenHistoryCaptureMetrics
    let configuration: ScreenHistoryCaptureConfiguration
    let fileVaultStatus: FileVaultStatus
}

/// A background-only capture loop. Nothing in this type is connected to the
/// launcher hotkey or overlay presentation path.
actor ScreenHistoryCaptureService {
    private var configuration: ScreenHistoryCaptureConfiguration
    private let frameSource: any ScreenHistoryFrameSourcing
    private let activityReader: any ScreenHistoryActivityReading
    private let textRecognizer: any ScreenHistoryTextRecognizing
    private let sink: any ScreenHistoryFrameSink
    private let securityChecker: any ScreenHistorySecurityChecking
    private let protectedSessionReader: any ScreenHistoryProtectedSessionReading

    private var state: ScreenHistoryCaptureState
    private var lastSkipReason: ScreenHistoryCaptureSkipReason?
    private var metrics = ScreenHistoryCaptureMetrics()
    private var lastFingerprint: UInt64?
    private var captureTask: Task<Void, Never>?
    private var fileVaultStatus: FileVaultStatus = .unknown
    private var statusContinuations: [
        UUID: AsyncStream<ScreenHistoryCaptureStatus>.Continuation
    ] = [:]

    init(
        configuration: ScreenHistoryCaptureConfiguration = .init(),
        frameSource: any ScreenHistoryFrameSourcing,
        activityReader: any ScreenHistoryActivityReading,
        textRecognizer: any ScreenHistoryTextRecognizing,
        sink: any ScreenHistoryFrameSink,
        securityChecker: any ScreenHistorySecurityChecking,
        protectedSessionReader: any ScreenHistoryProtectedSessionReading = CoreGraphicsScreenHistoryProtectedSessionReader()
    ) {
        self.configuration = configuration
        self.frameSource = frameSource
        self.activityReader = activityReader
        self.textRecognizer = textRecognizer
        self.sink = sink
        self.securityChecker = securityChecker
        self.protectedSessionReader = protectedSessionReader
        state = configuration.isEnabled ? .stopped : .disabled
    }

    func start() async {
        defer { publishStatus() }
        guard configuration.isEnabled else {
            state = .disabled
            return
        }
        guard captureTask == nil else { return }
        fileVaultStatus = await securityChecker.fileVaultStatus()
        guard fileVaultStatus == .on else {
            state = .stopped
            return
        }
        guard await frameSource.screenRecordingIsAuthorized() else {
            lastSkipReason = .screenRecordingNotAuthorized
            metrics.screenRecordingBlockedCycles += 1
            state = .stopped
            return
        }
        state = .running
        captureTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        captureTask?.cancel()
        captureTask = nil
        do {
            try await sink.flush()
        } catch {
            lastSkipReason = .storageFailure
            metrics.storageFailures += 1
        }
        state = configuration.isEnabled ? .stopped : .disabled
        publishStatus()
    }

    /// Enabling a stopped service never starts capture implicitly. A running
    /// service restarts only to apply its updated cadence and exclusions.
    func updateConfiguration(_ newConfiguration: ScreenHistoryCaptureConfiguration) async {
        defer { publishStatus() }
        let wasRunning = captureTask != nil
        captureTask?.cancel()
        captureTask = nil
        configuration = newConfiguration
        // The storage-rate receipt's window is one capture interval, so the
        // sink follows the effective cadence rather than its construction
        // default.
        if let cadenceSink = sink as? ScreenHistorySegmentedCaptureSink {
            await cadenceSink.updateEstimatedCadenceSeconds(newConfiguration.cadenceSeconds)
        }
        if wasRunning {
            do {
                try await sink.flush()
            } catch {
                lastSkipReason = .storageFailure
                metrics.storageFailures += 1
                state = newConfiguration.isEnabled ? .stopped : .disabled
                return
            }
        }
        lastFingerprint = nil
        lastSkipReason = nil
        state = newConfiguration.isEnabled ? .stopped : .disabled
        if wasRunning, newConfiguration.isEnabled {
            await start()
        }
    }

    @discardableResult
    func refreshSecurityStatus() async -> FileVaultStatus {
        fileVaultStatus = await securityChecker.fileVaultStatus()
        if fileVaultStatus != .on, captureTask != nil {
            await stop()
        } else {
            publishStatus()
        }
        return fileVaultStatus
    }

    func requestScreenRecordingAuthorization() async -> Bool {
        let authorized = await frameSource.requestScreenRecordingAuthorization()
        if authorized {
            if lastSkipReason == .screenRecordingNotAuthorized {
                lastSkipReason = nil
            }
        } else {
            lastSkipReason = .screenRecordingNotAuthorized
            metrics.screenRecordingBlockedCycles += 1
        }
        publishStatus()
        return authorized
    }

    func status() -> ScreenHistoryCaptureStatus {
        statusSnapshot
    }

    /// Emits the current status immediately, then every state or metrics
    /// change. Consumers can keep the menu-bar presentation current without
    /// polling the capture actor.
    func statusUpdates() -> AsyncStream<ScreenHistoryCaptureStatus> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            statusContinuations[identifier] = continuation
            continuation.yield(statusSnapshot)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStatusContinuation(identifier) }
            }
        }
    }

    private var statusSnapshot: ScreenHistoryCaptureStatus {
        ScreenHistoryCaptureStatus(
            state: state,
            lastSkipReason: lastSkipReason,
            metrics: metrics,
            configuration: configuration,
            fileVaultStatus: fileVaultStatus
        )
    }

    /// One capture cycle. Kept independent from the timer so permission-free
    /// fakes can verify every privacy gate deterministically.
    func runOneCycle() async {
        guard configuration.isEnabled,
              state == .running || state == .pausedForInactivity
        else { return }
        defer { publishStatus() }

        metrics.cycles += 1
        fileVaultStatus = await securityChecker.fileVaultStatus()
        guard canContinueCurrentCycle else { return }
        guard fileVaultStatus == .on else {
            lastSkipReason = .fileVault(fileVaultStatus)
            metrics.fileVaultBlockedCycles += 1
            captureTask?.cancel()
            captureTask = nil
            state = configuration.isEnabled ? .stopped : .disabled
            return
        }
        guard await frameSource.screenRecordingIsAuthorized() else {
            lastSkipReason = .screenRecordingNotAuthorized
            metrics.screenRecordingBlockedCycles += 1
            captureTask?.cancel()
            captureTask = nil
            state = configuration.isEnabled ? .stopped : .disabled
            return
        }

        let inactiveFor = await activityReader.secondsSinceLastInput()
        guard canContinueCurrentCycle else { return }
        guard inactiveFor < configuration.inactivityThresholdSeconds else {
            state = .pausedForInactivity
            lastSkipReason = .inactive
            metrics.inactiveCycles += 1
            return
        }

        state = .running
        guard await captureIsPermittedBySessionState() else { return }
        guard let target = await frameSource.frontmostWindowTarget() else {
            guard canContinueCurrentCycle else { return }
            lastSkipReason = .noFrontWindow
            return
        }
        guard canContinueCurrentCycle else { return }
        guard let bundleIdentifier = target.bundleIdentifier.flatMap(
            ScreenHistoryCaptureConfiguration.normalizedBundleIdentifier
        ) else {
            lastSkipReason = .unknownBundleIdentifier
            metrics.unknownApplicationFrames += 1
            return
        }
        guard !configuration.excludes(bundleIdentifier) else {
            lastSkipReason = .excludedBundleIdentifier(bundleIdentifier)
            metrics.excludedFrames += 1
            return
        }
        if let privacySkip = ScreenHistoryPrivacyPolicy.captureSkipReason(
            target: target,
            bundleIdentifier: bundleIdentifier,
            excludedDomains: configuration.excludedDomains
        ) {
            lastSkipReason = privacySkip
            metrics.excludedFrames += 1
            return
        }

        // Re-read the state after target inspection. Screen lock or sharing can
        // begin during a cycle, and no ScreenCaptureKit call may cross that gate.
        guard await captureIsPermittedBySessionState() else { return }

        let rawFrame: ScreenHistoryRawFrame
        do {
            guard let captured = try await frameSource.captureWindow(for: target) else {
                guard canContinueCurrentCycle else { return }
                lastSkipReason = .noFrontWindow
                return
            }
            rawFrame = captured
        } catch ScreenHistoryCaptureSourceError.protectedSession(let status) {
            guard canContinueCurrentCycle else { return }
            recordProtectedSessionSkip(status)
            return
        } catch ScreenHistoryCaptureSourceError.screenRecordingNotAuthorized {
            guard canContinueCurrentCycle else { return }
            lastSkipReason = .screenRecordingNotAuthorized
            metrics.screenRecordingBlockedCycles += 1
            captureTask?.cancel()
            captureTask = nil
            state = configuration.isEnabled ? .stopped : .disabled
            return
        } catch {
            guard canContinueCurrentCycle else { return }
            lastSkipReason = .sourceFailure
            metrics.sourceFailures += 1
            return
        }
        guard canContinueCurrentCycle else { return }
        guard !rawFrame.imageData.isEmpty,
              rawFrame.imageData.count <= CapturedScreenFrame.maximumImageBytes
        else {
            lastSkipReason = .oversizedImage
            return
        }

        let fingerprint = ScreenHistoryFrameFingerprint.make(
            imageData: rawFrame.imageData,
            bundleIdentifier: bundleIdentifier,
            windowTitle: rawFrame.windowTitle,
            pixelWidth: rawFrame.pixelWidth,
            pixelHeight: rawFrame.pixelHeight
        )
        guard fingerprint != lastFingerprint else {
            lastSkipReason = .unchanged
            metrics.duplicateFrames += 1
            return
        }

        let recognition = await textRecognizer.recognize(
            in: rawFrame.imageData,
            pixelWidth: rawFrame.pixelWidth,
            pixelHeight: rawFrame.pixelHeight
        )
        guard canContinueCurrentCycle else { return }
        guard let frame = CapturedScreenFrame(
            capturedAt: rawFrame.capturedAt,
            bundleIdentifier: bundleIdentifier,
            applicationName: target.applicationName,
            windowTitle: rawFrame.windowTitle,
            pixelWidth: rawFrame.pixelWidth,
            pixelHeight: rawFrame.pixelHeight,
            imageData: rawFrame.imageData,
            recognizedText: recognition.text,
            recognizedBoxes: recognition.boxes,
            fingerprint: fingerprint
        ) else {
            lastSkipReason = .oversizedImage
            return
        }

        do {
            try await sink.receive(frame)
        } catch {
            lastSkipReason = .storageFailure
            metrics.storageFailures += 1
            return
        }
        lastFingerprint = fingerprint
        lastSkipReason = nil
        metrics.emittedFrames += 1
    }

    private var canContinueCurrentCycle: Bool {
        !Task.isCancelled
            && configuration.isEnabled
            && (state == .running || state == .pausedForInactivity)
    }

    private func captureIsPermittedBySessionState() async -> Bool {
        let status = await protectedSessionReader.protectedSessionStatus()
        guard canContinueCurrentCycle else { return false }
        guard status.permitsCapture else {
            recordProtectedSessionSkip(status)
            return false
        }
        return true
    }

    private func recordProtectedSessionSkip(_ status: ScreenHistoryProtectedSessionStatus) {
        lastSkipReason = .protectedSession(status)
        metrics.protectedSessionCycles += 1
        switch status {
        case .clear:
            break
        case .locked:
            metrics.lockedSessionCycles += 1
        case .offConsole:
            metrics.offConsoleSessionCycles += 1
        case .activeDisplayCapture:
            metrics.activeDisplayCaptureCycles += 1
        case .unknown:
            metrics.unknownSessionCycles += 1
        }
    }

    private func publishStatus() {
        let snapshot = statusSnapshot
        for continuation in statusContinuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeStatusContinuation(_ identifier: UUID) {
        statusContinuations.removeValue(forKey: identifier)
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(configuration.cadenceSeconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await runOneCycle()
        }
    }
}

enum ScreenHistoryFrameFingerprint {
    /// FNV-1a over frame metadata plus at most 4,096 evenly sampled bytes.
    /// This is a change detector, not a security or content identity hash.
    static func make(
        imageData: Data,
        bundleIdentifier: String,
        windowTitle: String?,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        func add(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        func add(_ value: String) {
            value.utf8.forEach(add)
            add(0)
        }

        add(bundleIdentifier)
        add(windowTitle ?? "")
        add(String(pixelWidth))
        add(String(pixelHeight))
        add(String(imageData.count))

        let maximumSamples = 4_096
        let stride = max(1, imageData.count / maximumSamples)
        var index = 0
        while index < imageData.count {
            add(imageData[index])
            index += stride
        }
        return hash
    }
}

enum ScreenHistoryCaptureSourceError: Error, Equatable {
    case screenRecordingNotAuthorized
    case imageEncodingFailed
    case protectedSession(ScreenHistoryProtectedSessionStatus)
}

/// ScreenCaptureKit adapter for the engine. It does not request permission in
/// the background and captures only the frontmost app's normal front window.
@MainActor
final class ScreenCaptureKitHistoryFrameSource: ScreenHistoryFrameSourcing {
    static let maximumLongEdge: CGFloat = 1_600
    private let protectedSessionReader: any ScreenHistoryProtectedSessionReading

    init(
        protectedSessionReader: any ScreenHistoryProtectedSessionReading = CoreGraphicsScreenHistoryProtectedSessionReader()
    ) {
        self.protectedSessionReader = protectedSessionReader
    }

    func screenRecordingIsAuthorized() async -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingAuthorization() async -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func frontmostWindowTarget() async -> ScreenHistoryCaptureTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        guard let window = Self.frontWindowMetadata(
            processIdentifier: application.processIdentifier,
            windowInfo: Self.onScreenWindowInfo()
        ) else { return nil }
        let bundleIdentifier = application.bundleIdentifier
        let declaresWebURLHandling = Self.declaresWebURLHandling(
            in: application.bundleURL.flatMap(Bundle.init(url:))?.infoDictionary
        )
        let isBrowserLike = declaresWebURLHandling || bundleIdentifier.map(
            ScreenHistoryPrivacyPolicy.isKnownBrowser(bundleIdentifier:)
        ) == true
        let browserMetadata = isBrowserLike
            ? BrowserAccessibilityMetadata.read(
                processIdentifier: application.processIdentifier,
                windowIdentifier: window.identifier
            )
            : nil
        return ScreenHistoryCaptureTarget(
            windowIdentifier: window.identifier,
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            applicationName: application.localizedName ?? "Unknown application",
            windowTitle: window.title,
            pageURL: browserMetadata?.url,
            domain: browserMetadata?.domain,
            pageTitle: browserMetadata?.title,
            declaresWebURLHandling: declaresWebURLHandling
        )
    }

    /// Reads only the application manifest. A declaration for either web URL
    /// scheme is enough to fail closed during the capture-off beta.
    nonisolated static func declaresWebURLHandling(in infoDictionary: [String: Any]?) -> Bool {
        guard let urlTypes = infoDictionary?["CFBundleURLTypes"] as? [Any] else { return false }
        return urlTypes.contains { rawType in
            guard let type = rawType as? [String: Any],
                  let schemes = type["CFBundleURLSchemes"] as? [Any]
            else { return false }
            return schemes.contains { rawScheme in
                guard let scheme = rawScheme as? String else { return false }
                let normalized = scheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized == "http" || normalized == "https"
            }
        }
    }

    func captureWindow(for target: ScreenHistoryCaptureTarget) async throws -> ScreenHistoryRawFrame? {
        let initialSessionStatus = await protectedSessionReader.protectedSessionStatus()
        guard initialSessionStatus.permitsCapture else {
            throw ScreenHistoryCaptureSourceError.protectedSession(initialSessionStatus)
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenHistoryCaptureSourceError.screenRecordingNotAuthorized
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = Self.window(matching: target, in: content.windows) else {
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let points = filter.contentRect.size
        let scale = CGFloat(filter.pointPixelScale)
        let pixels = CGSize(width: points.width * scale, height: points.height * scale)
        let fit = min(1, Self.maximumLongEdge / max(pixels.width, pixels.height, 1))
        configuration.width = max(1, Int(pixels.width * fit))
        configuration.height = max(1, Int(pixels.height * fit))
        configuration.showsCursor = false
        configuration.captureResolution = .best

        // This is the final boundary before ScreenCaptureKit reads pixels.
        let finalSessionStatus = await protectedSessionReader.protectedSessionStatus()
        guard finalSessionStatus.permitsCapture else {
            throw ScreenHistoryCaptureSourceError.protectedSession(finalSessionStatus)
        }
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        let representation = NSBitmapImageRep(cgImage: image)
        guard let imageData = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.7]
        ), !imageData.isEmpty else {
            throw ScreenHistoryCaptureSourceError.imageEncodingFailed
        }

        return ScreenHistoryRawFrame(
            capturedAt: Date(),
            windowTitle: window.title,
            pixelWidth: image.width,
            pixelHeight: image.height,
            imageData: imageData
        )
    }

    private static func window(
        matching target: ScreenHistoryCaptureTarget,
        in windows: [SCWindow]
    ) -> SCWindow? {
        windows.first { window in
            window.windowID == target.windowIdentifier
                && window.owningApplication?.processID == target.processIdentifier
                && window.isOnScreen
                && window.windowLayer == 0
                && window.frame.width > 40
                && window.frame.height > 40
        }
    }

    struct FrontWindowMetadata: Equatable, Sendable {
        let identifier: CGWindowID
        let title: String?
    }

    nonisolated static func frontWindowMetadata(
        processIdentifier: pid_t,
        windowInfo: [[String: Any]]
    ) -> FrontWindowMetadata? {
        for value in windowInfo {
            guard (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == processIdentifier,
                  (value[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let rawIdentifier = (value[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  rawIdentifier != 0,
                  let bounds = value[kCGWindowBounds as String] as? NSDictionary,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 40,
                  height > 40
            else { continue }
            return FrontWindowMetadata(
                identifier: CGWindowID(rawIdentifier),
                title: value[kCGWindowName as String] as? String
            )
        }
        return nil
    }

    private static func onScreenWindowInfo() -> [[String: Any]] {
        CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            CGWindowID(0)
        ) as? [[String: Any]] ?? []
    }
}

private struct BrowserAccessibilityMetadata {
    private static let webAreaRole = "AXWebArea"
    let url: URL
    let domain: String
    let title: String?

    /// Reads only Accessibility roles, hierarchy, URL, and web-area title.
    /// It never requests value, description, selected text, or page text.
    @MainActor
    static func read(
        processIdentifier: pid_t,
        windowIdentifier: CGWindowID
    ) -> BrowserAccessibilityMetadata? {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.3)
        guard let window = element(application, kAXFocusedWindowAttribute) else { return nil }
        // AX metadata is accepted only when the focused accessibility window
        // is the exact CGWindow selected above. If the private bridge is not
        // available or focus moved, browser preflight fails closed.
        guard cgWindowIdentifier(for: window) == windowIdentifier else { return nil }
        return readFirstWebArea(in: window)
    }

    @MainActor
    private static func cgWindowIdentifier(for window: AXUIElement) -> CGWindowID? {
        let frameworkPath = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        typealias GetWindow = @convention(c) (
            AXUIElement,
            UnsafeMutablePointer<CGWindowID>
        ) -> AXError
        let getWindow = unsafeBitCast(symbol, to: GetWindow.self)
        var identifier = CGWindowID(0)
        guard getWindow(window, &identifier) == .success, identifier != 0 else { return nil }
        return identifier
    }

    @MainActor
    private static func readFirstWebArea(in root: AXUIElement) -> BrowserAccessibilityMetadata? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 256 {
            let (node, depth) = queue.removeFirst()
            visited += 1
            if role(node) == webAreaRole, let metadata = metadata(for: node) {
                return metadata
            }
            guard depth < 12 else { continue }
            queue.append(contentsOf: children(node).map { ($0, depth + 1) })
        }
        return nil
    }

    @MainActor
    private static func metadata(for webArea: AXUIElement) -> BrowserAccessibilityMetadata? {
        guard let url = url(webArea),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host,
              let domain = ScreenHistoryCaptureConfiguration.normalizedDomain(host)
        else { return nil }
        return BrowserAccessibilityMetadata(
            url: url,
            domain: domain,
            title: string(webArea, kAXTitleAttribute)
        )
    }

    @MainActor
    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    @MainActor
    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    @MainActor
    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    @MainActor
    private static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute)
    }

    @MainActor
    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    @MainActor
    private static func url(_ element: AXUIElement) -> URL? {
        guard let value = attribute(element, kAXURLAttribute) else { return nil }
        if let url = value as? URL { return url }
        if let string = value as? String { return URL(string: string) }
        return nil
    }
}

struct SystemScreenHistoryActivityReader: ScreenHistoryActivityReading {
    func secondsSinceLastInput() async -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: CGEventType(rawValue: UInt32.max)!
        )
    }
}

struct VisionScreenHistoryTextRecognizer: ScreenHistoryTextRecognizing {
    func recognizeText(in imageData: Data) async -> String {
        await recognize(in: imageData, pixelWidth: 1, pixelHeight: 1).text
    }

    func recognize(
        in imageData: Data,
        pixelWidth: Int,
        pixelHeight: Int
    ) async -> ScreenHistoryTextRecognition {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return ScreenHistoryTextRecognition(text: "", boxes: []) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]
            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
            } catch {
                return ScreenHistoryTextRecognition(text: "", boxes: [])
            }
            var lines: [String] = []
            var boxes: [ScreenHistoryOCRBox] = []
            for observation in (request.results ?? []).prefix(1_000) {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = String(candidate.string.prefix(200))
                guard !text.isEmpty else { continue }
                let bounds = observation.boundingBox
                let width = Double(max(1, pixelWidth))
                let height = Double(max(1, pixelHeight))
                boxes.append(ScreenHistoryOCRBox(
                    ordinal: boxes.count,
                    text: text,
                    x: Double(bounds.origin.x) * width,
                    y: (1 - Double(bounds.origin.y) - Double(bounds.height)) * height,
                    width: Double(bounds.width) * width,
                    height: Double(bounds.height) * height
                ))
                lines.append(text)
            }
            return ScreenHistoryTextRecognition(
                text: String(lines.joined(separator: "\n").prefix(
                    CapturedScreenFrame.maximumOCRCharacters
                )),
                boxes: boxes
            )
        }.value
    }
}
