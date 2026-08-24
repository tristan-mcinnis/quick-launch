import AppKit
import CoreGraphics
import Darwin
import Foundation

enum FileVaultStatus: String, Equatable, Sendable {
    case on
    case off
    case unknown
}

protocol ScreenHistorySecurityChecking: Sendable {
    func fileVaultStatus() async -> FileVaultStatus
}

enum ScreenHistoryProtectedSessionStatus: String, Equatable, Sendable {
    case clear
    case locked
    case offConsole
    case activeDisplayCapture
    case unknown

    var permitsCapture: Bool { self == .clear }
}

/// Reads only system session state. It never reads window, application, or
/// screen content.
protocol ScreenHistoryProtectedSessionReading: Sendable {
    func protectedSessionStatus() async -> ScreenHistoryProtectedSessionStatus
}

enum ScreenHistoryProtectedSessionParser {
    static let onConsoleKey = kCGSessionOnConsoleKey as String
    static let loginDoneKey = kCGSessionLoginDoneKey as String
    static let lockedKey = "CGSSessionScreenIsLocked"

    static func parse(
        sessionDictionary: [String: Any]?,
        activeDisplayCapture: Bool?
    ) -> ScreenHistoryProtectedSessionStatus {
        guard let sessionDictionary else { return .unknown }
        guard let onConsole = boolean(
            sessionDictionary[onConsoleKey]
        ) else { return .unknown }
        guard onConsole else { return .offConsole }

        guard let loginDone = boolean(
            sessionDictionary[loginDoneKey]
        ) else { return .unknown }
        guard loginDone else { return .locked }

        guard let isLocked = boolean(sessionDictionary[lockedKey]) else { return .unknown }
        guard !isLocked else { return .locked }

        guard let activeDisplayCapture else { return .unknown }
        return activeDisplayCapture ? .activeDisplayCapture : .clear
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}

/// Fails closed when the Quartz session or display-capture state cannot be
/// read. `CGDisplayIsCaptured` is a legacy signal, so app exclusions provide
/// a second boundary for current screen-sharing and recording applications.
struct CoreGraphicsScreenHistoryProtectedSessionReader: ScreenHistoryProtectedSessionReading {
    func protectedSessionStatus() async -> ScreenHistoryProtectedSessionStatus {
        let sharingAppIsRunning = await MainActor.run {
            Self.hasRunningSharingApplication(
                bundleIdentifiers: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            )
        }
        if sharingAppIsRunning { return .activeDisplayCapture }
        let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        return ScreenHistoryProtectedSessionParser.parse(
            sessionDictionary: dictionary,
            activeDisplayCapture: Self.activeDisplayCaptureStatus()
        )
    }

    static func hasRunningSharingApplication(bundleIdentifiers: [String]) -> Bool {
        bundleIdentifiers.contains { bundleIdentifier in
            ScreenHistoryCaptureConfiguration.safeDefaultCaptureOnlyExcludedBundleIdentifiers
                .contains(bundleIdentifier.lowercased())
        }
    }

    private static func activeDisplayCaptureStatus() -> Bool? {
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0
        else { return nil }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return nil
        }
        guard let coreGraphics = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            RTLD_LAZY | RTLD_LOCAL
        ) else { return nil }
        defer { dlclose(coreGraphics) }
        guard let symbol = dlsym(coreGraphics, "CGDisplayIsCaptured") else { return nil }
        typealias DisplayIsCaptured = @convention(c) (CGDirectDisplayID) -> Int32
        let displayIsCaptured = unsafeBitCast(symbol, to: DisplayIsCaptured.self)
        return displays.prefix(Int(displayCount)).contains { display in
            displayIsCaptured(display) != 0
        }
    }
}

enum FileVaultStatusParser {
    static func parse(output: String, terminationStatus: Int32) -> FileVaultStatus {
        guard terminationStatus == 0 else { return .unknown }
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("filevault is on") { return .on }
        if normalized.contains("filevault is off") { return .off }
        return .unknown
    }
}

/// Checks the system disk-encryption state without a shell. A slow or
/// unexpected response fails closed so ambient capture cannot start.
actor FileVaultScreenHistorySecurityChecker: ScreenHistorySecurityChecking {
    let timeout: TimeInterval
    let minimumRefreshInterval: TimeInterval
    private let clock: @Sendable () -> Date
    private var lastCheckedAt: Date?
    private var lastStatus: FileVaultStatus = .unknown

    init(
        timeout: TimeInterval = 2,
        minimumRefreshInterval: TimeInterval = 60,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.timeout = min(max(timeout, 0.1), 10)
        self.minimumRefreshInterval = min(max(minimumRefreshInterval, 1), 300)
        self.clock = clock
    }

    func fileVaultStatus() async -> FileVaultStatus {
        let now = clock()
        if let lastCheckedAt,
           now.timeIntervalSince(lastCheckedAt) < minimumRefreshInterval {
            return lastStatus
        }
        let timeout = timeout
        let status = await Task.detached(priority: .utility) {
            Self.checkSynchronously(timeout: timeout)
        }.value
        lastCheckedAt = now
        lastStatus = status
        return status
    }

    private static func checkSynchronously(timeout: TimeInterval) -> FileVaultStatus {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        process.arguments = ["status"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .unknown
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard !process.isRunning else {
            process.terminate()
            return .unknown
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return FileVaultStatusParser.parse(
            output: text,
            terminationStatus: process.terminationStatus
        )
    }
}

struct ScreenHistoryStatusPresentation: Equatable, Sendable {
    let statusTitle: String
    let controlTitle: String
    let controlIsEnabled: Bool

    static func make(status: ScreenHistoryCaptureStatus?) -> Self {
        switch status?.state {
        case .running:
            Self(
                statusTitle: "Screen History Running",
                controlTitle: "Pause Screen History",
                controlIsEnabled: true
            )
        case .pausedForInactivity:
            Self(
                statusTitle: "Screen History Paused",
                controlTitle: "Stop Screen History",
                controlIsEnabled: true
            )
        case .stopped, .disabled, nil:
            Self(
                statusTitle: "Screen History Stopped",
                controlTitle: "Stop Screen History",
                controlIsEnabled: false
            )
        }
    }
}
