import Foundation

enum ScreenHistorySoakCaptureState: String, Codable, Equatable, Sendable {
    case disabled
    case stopped
    case running
    case pausedForInactivity

    init(_ state: ScreenHistoryCaptureState) {
        switch state {
        case .disabled: self = .disabled
        case .stopped: self = .stopped
        case .running: self = .running
        case .pausedForInactivity: self = .pausedForInactivity
        }
    }
}

struct ScreenHistorySoakCaptureCounters: Codable, Equatable, Sendable {
    var cycles: Int
    var emissions: Int
    var duplicateSkips: Int
    var exclusionSkips: Int
    var sessionSkips: Int
    var inactivitySkips: Int
    var sourceFailures: Int
    var storageFailures: Int
    var fileVaultBlocks: Int
    var screenRecordingBlocks: Int

    init(
        cycles: Int = 0,
        emissions: Int = 0,
        duplicateSkips: Int = 0,
        exclusionSkips: Int = 0,
        sessionSkips: Int = 0,
        inactivitySkips: Int = 0,
        sourceFailures: Int = 0,
        storageFailures: Int = 0,
        fileVaultBlocks: Int = 0,
        screenRecordingBlocks: Int = 0
    ) {
        self.cycles = cycles
        self.emissions = emissions
        self.duplicateSkips = duplicateSkips
        self.exclusionSkips = exclusionSkips
        self.sessionSkips = sessionSkips
        self.inactivitySkips = inactivitySkips
        self.sourceFailures = sourceFailures
        self.storageFailures = storageFailures
        self.fileVaultBlocks = fileVaultBlocks
        self.screenRecordingBlocks = screenRecordingBlocks
    }

    init(_ metrics: ScreenHistoryCaptureMetrics) {
        self.init(
            cycles: metrics.cycles,
            emissions: metrics.emittedFrames,
            duplicateSkips: metrics.duplicateFrames,
            exclusionSkips: metrics.excludedFrames + metrics.unknownApplicationFrames,
            sessionSkips: metrics.protectedSessionCycles,
            inactivitySkips: metrics.inactiveCycles,
            sourceFailures: metrics.sourceFailures,
            storageFailures: metrics.storageFailures,
            fileVaultBlocks: metrics.fileVaultBlockedCycles,
            screenRecordingBlocks: metrics.screenRecordingBlockedCycles
        )
    }
}

enum ScreenHistorySoakProcessEvent: String, Codable, Equatable, Sendable {
    case none
    case cleanRestart
    case crashRecovery
}

enum ScreenHistorySoakNetworkObservation: String, Codable, Equatable, Sendable {
    case notObserved
    case observedNoCaptureContentEgress
    case captureContentEgressDetected
    case observationFailed
}

/// Fixed codes prevent screen content, paths, domains, and free-form details
/// from entering the soak receipt.
enum ScreenHistorySoakFailureCode: String, Codable, CaseIterable, Equatable, Sendable {
    case captureSourceFailure
    case counterRegression
    case networkObservationFailed
    case storageObservationFailed
    case unexpectedCaptureExit
    case unexplainedDataLoss
    case unresolvedPrivacyControl
    case storageWriteFailure
    case screenRecordingPermissionMissing
}

struct ScreenHistorySoakSnapshot: Equatable, Sendable {
    let observedAt: Date
    let captureState: ScreenHistorySoakCaptureState
    let captureCounters: ScreenHistorySoakCaptureCounters
    let storageBytes: Int64
    let storageFiles: Int
    let processEvent: ScreenHistorySoakProcessEvent
    let networkObservation: ScreenHistorySoakNetworkObservation
    let privacyLeakCountDelta: Int
    let unexplainedCorruptionCountDelta: Int
    let newFailures: Set<ScreenHistorySoakFailureCode>
    let resolvedFailures: Set<ScreenHistorySoakFailureCode>

    init(
        observedAt: Date,
        captureState: ScreenHistorySoakCaptureState,
        captureCounters: ScreenHistorySoakCaptureCounters,
        storageBytes: Int64,
        storageFiles: Int,
        processEvent: ScreenHistorySoakProcessEvent = .none,
        networkObservation: ScreenHistorySoakNetworkObservation = .notObserved,
        privacyLeakCountDelta: Int = 0,
        unexplainedCorruptionCountDelta: Int = 0,
        newFailures: Set<ScreenHistorySoakFailureCode> = [],
        resolvedFailures: Set<ScreenHistorySoakFailureCode> = []
    ) {
        self.observedAt = observedAt
        self.captureState = captureState
        self.captureCounters = captureCounters
        self.storageBytes = storageBytes
        self.storageFiles = storageFiles
        self.processEvent = processEvent
        self.networkObservation = networkObservation
        self.privacyLeakCountDelta = privacyLeakCountDelta
        self.unexplainedCorruptionCountDelta = unexplainedCorruptionCountDelta
        self.newFailures = newFailures
        self.resolvedFailures = resolvedFailures
    }

    init(
        observedAt: Date,
        captureStatus: ScreenHistoryCaptureStatus,
        storageBytes: Int64,
        storageFiles: Int,
        processEvent: ScreenHistorySoakProcessEvent = .none,
        networkObservation: ScreenHistorySoakNetworkObservation = .notObserved,
        privacyLeakCountDelta: Int = 0,
        unexplainedCorruptionCountDelta: Int = 0,
        newFailures: Set<ScreenHistorySoakFailureCode> = [],
        resolvedFailures: Set<ScreenHistorySoakFailureCode> = []
    ) {
        self.init(
            observedAt: observedAt,
            captureState: ScreenHistorySoakCaptureState(captureStatus.state),
            captureCounters: ScreenHistorySoakCaptureCounters(captureStatus.metrics),
            storageBytes: storageBytes,
            storageFiles: storageFiles,
            processEvent: processEvent,
            networkObservation: networkObservation,
            privacyLeakCountDelta: privacyLeakCountDelta,
            unexplainedCorruptionCountDelta: unexplainedCorruptionCountDelta,
            newFailures: newFailures,
            resolvedFailures: resolvedFailures
        )
    }
}

enum ScreenHistorySoakReadinessBlocker: String, Codable, Equatable, Sendable {
    case insufficientActiveDays
    case noSuccessfulNetworkObservation
    case privacyLeakDetected
    case captureContentEgressDetected
    case unexplainedCorruption
    case unresolvedFailures
}

struct ScreenHistorySoakReceiptSummary: Codable, Equatable, Sendable {
    static let requiredActiveDays = 7

    let schemaVersion: Int
    let lastSequence: Int
    let lastHash: String
    let lastRecordedAt: Date?
    let activeDays: [String]
    let totals: ScreenHistorySoakCaptureCounters
    let storageBytes: Int64
    let storageFiles: Int
    let peakStorageBytes: Int64
    let peakStorageFiles: Int
    let cleanRestarts: Int
    let crashRecoveries: Int
    let receiptResumes: Int
    let privacyLeakCount: Int
    let captureContentEgressCount: Int
    let unexplainedCorruptionCount: Int
    let successfulNetworkObservations: Int
    let failedNetworkObservations: Int
    let unresolvedFailures: [ScreenHistorySoakFailureCode]

    var activeDayCount: Int { activeDays.count }

    var readinessBlockers: [ScreenHistorySoakReadinessBlocker] {
        var blockers: [ScreenHistorySoakReadinessBlocker] = []
        if activeDayCount < Self.requiredActiveDays { blockers.append(.insufficientActiveDays) }
        if successfulNetworkObservations == 0 { blockers.append(.noSuccessfulNetworkObservation) }
        if privacyLeakCount > 0 { blockers.append(.privacyLeakDetected) }
        if captureContentEgressCount > 0 { blockers.append(.captureContentEgressDetected) }
        if unexplainedCorruptionCount > 0 { blockers.append(.unexplainedCorruption) }
        if !unresolvedFailures.isEmpty { blockers.append(.unresolvedFailures) }
        return blockers
    }

    var isReadyForCoastRetirement: Bool { readinessBlockers.isEmpty }
}

protocol ScreenHistorySoakReceipting: Sendable {
    func record(_ snapshot: ScreenHistorySoakSnapshot) async throws -> ScreenHistorySoakReceiptSummary
    func currentSummary() async -> ScreenHistorySoakReceiptSummary
}
