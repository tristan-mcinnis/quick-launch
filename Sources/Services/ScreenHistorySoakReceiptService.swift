import CryptoKit
import Foundation

enum ScreenHistorySoakReceiptError: Error, Equatable {
    case invalidSnapshot
    case receiptCorruption
    case unsafeStorageLocation
}

actor ScreenHistorySoakReceiptService: ScreenHistorySoakReceipting {
    static let schemaVersion = 1
    static let genesisHash = String(repeating: "0", count: 64)

    nonisolated let directoryURL: URL
    nonisolated let logURL: URL
    nonisolated let summaryURL: URL

    private let calendar: Calendar
    private var cumulative: CumulativeState
    private var lastSequence: Int
    private var lastHash: String
    private var lastRecordedAt: Date?
    private var pendingReceiptResume: Bool

    init(
        directoryURL: URL = ScreenHistorySoakReceiptService.defaultDirectoryURL(),
        calendar: Calendar = ScreenHistorySoakReceiptService.defaultCalendar()
    ) throws {
        self.directoryURL = directoryURL
        logURL = directoryURL.appendingPathComponent("receipt.jsonl", isDirectory: false)
        summaryURL = directoryURL.appendingPathComponent("summary.json", isDirectory: false)
        self.calendar = calendar

        try Self.prepareStorage(directoryURL: directoryURL, logURL: logURL)
        let loaded = try Self.load(logURL: logURL)
        cumulative = loaded.cumulative
        lastSequence = loaded.lastSequence
        lastHash = loaded.lastHash
        lastRecordedAt = loaded.lastRecordedAt
        pendingReceiptResume = loaded.lastSequence > 0

        let current = Self.summary(
            cumulative: loaded.cumulative,
            sequence: loaded.lastSequence,
            hash: loaded.lastHash,
            recordedAt: loaded.lastRecordedAt
        )
        try Self.validateOrRefreshSummary(
            at: summaryURL,
            current: current,
            historical: loaded.historicalSummaries
        )
        try Self.enforceOwnerOnlyPermissions(
            directoryURL: directoryURL,
            logURL: logURL,
            summaryURL: summaryURL
        )
    }

    func record(_ snapshot: ScreenHistorySoakSnapshot) async throws -> ScreenHistorySoakReceiptSummary {
        guard Self.isValid(snapshot) else {
            throw ScreenHistorySoakReceiptError.invalidSnapshot
        }

        let resetCounters = snapshot.processEvent != .none
        let deltaResult = Self.delta(
            current: snapshot.captureCounters,
            previous: cumulative.lastCaptureCounters,
            reset: resetCounters
        )

        var next = cumulative
        next.lastCaptureCounters = snapshot.captureCounters
        next.totals = try Self.add(next.totals, deltaResult.delta)
        next.storageBytes = snapshot.storageBytes
        next.storageFiles = snapshot.storageFiles
        next.peakStorageBytes = max(next.peakStorageBytes, snapshot.storageBytes)
        next.peakStorageFiles = max(next.peakStorageFiles, snapshot.storageFiles)
        next.privacyLeakCount = try Self.add(
            next.privacyLeakCount,
            snapshot.privacyLeakCountDelta
        )
        next.unexplainedCorruptionCount = try Self.add(
            next.unexplainedCorruptionCount,
            snapshot.unexplainedCorruptionCountDelta
        )

        if deltaResult.delta.cycles > 0 {
            var days = Set(next.activeDays)
            days.insert(Self.dayString(for: snapshot.observedAt, calendar: calendar))
            next.activeDays = days.sorted()
        }

        if pendingReceiptResume {
            next.receiptResumes = try Self.add(next.receiptResumes, 1)
        }

        var unresolved = Set(next.unresolvedFailures)
        if deltaResult.regressed { unresolved.insert(.counterRegression) }
        if deltaResult.delta.sourceFailures > 0 { unresolved.insert(.captureSourceFailure) }
        if deltaResult.delta.storageFailures > 0 { unresolved.insert(.storageWriteFailure) }
        if deltaResult.delta.screenRecordingBlocks > 0 {
            unresolved.insert(.screenRecordingPermissionMissing)
        }

        switch snapshot.processEvent {
        case .none:
            break
        case .cleanRestart:
            next.cleanRestarts = try Self.add(next.cleanRestarts, 1)
        case .crashRecovery:
            next.crashRecoveries = try Self.add(next.crashRecoveries, 1)
            unresolved.insert(.unexpectedCaptureExit)
        }

        switch snapshot.networkObservation {
        case .notObserved:
            break
        case .observedNoCaptureContentEgress:
            next.successfulNetworkObservations = try Self.add(
                next.successfulNetworkObservations,
                1
            )
        case .captureContentEgressDetected:
            next.captureContentEgressCount = try Self.add(next.captureContentEgressCount, 1)
        case .observationFailed:
            next.failedNetworkObservations = try Self.add(next.failedNetworkObservations, 1)
            unresolved.insert(.networkObservationFailed)
        }

        unresolved.formUnion(snapshot.newFailures)
        unresolved.subtract(snapshot.resolvedFailures)
        next.unresolvedFailures = unresolved.sorted { $0.rawValue < $1.rawValue }

        let sequence = try Self.add(lastSequence, 1)
        let payload = ReceiptPayload(
            schemaVersion: Self.schemaVersion,
            sequence: sequence,
            recordedAt: snapshot.observedAt,
            activeDay: deltaResult.delta.cycles > 0
                ? Self.dayString(for: snapshot.observedAt, calendar: calendar)
                : nil,
            captureState: snapshot.captureState,
            captureDelta: deltaResult.delta,
            processEvent: snapshot.processEvent,
            networkObservation: snapshot.networkObservation,
            privacyLeakCountDelta: snapshot.privacyLeakCountDelta,
            unexplainedCorruptionCountDelta: snapshot.unexplainedCorruptionCountDelta,
            storageBytes: snapshot.storageBytes,
            storageFiles: snapshot.storageFiles,
            previousHash: lastHash,
            cumulative: next
        )
        let entry = ReceiptEntry(payload: payload, hash: Self.hash(payload))
        try Self.append(entry, to: logURL)

        cumulative = next
        lastSequence = sequence
        lastHash = entry.hash
        lastRecordedAt = snapshot.observedAt
        pendingReceiptResume = false

        let result = Self.summary(
            cumulative: next,
            sequence: sequence,
            hash: entry.hash,
            recordedAt: snapshot.observedAt
        )
        try Self.writeSummary(result, to: summaryURL)
        try Self.enforceOwnerOnlyPermissions(
            directoryURL: directoryURL,
            logURL: logURL,
            summaryURL: summaryURL
        )
        return result
    }

    func currentSummary() async -> ScreenHistorySoakReceiptSummary {
        Self.summary(
            cumulative: cumulative,
            sequence: lastSequence,
            hash: lastHash,
            recordedAt: lastRecordedAt
        )
    }
}

private extension ScreenHistorySoakReceiptService {
    struct CumulativeState: Codable, Equatable, Sendable {
        var activeDays: [String] = []
        var totals = ScreenHistorySoakCaptureCounters()
        var lastCaptureCounters: ScreenHistorySoakCaptureCounters?
        var storageBytes: Int64 = 0
        var storageFiles: Int = 0
        var peakStorageBytes: Int64 = 0
        var peakStorageFiles: Int = 0
        var cleanRestarts: Int = 0
        var crashRecoveries: Int = 0
        var receiptResumes: Int = 0
        var privacyLeakCount: Int = 0
        var captureContentEgressCount: Int = 0
        var unexplainedCorruptionCount: Int = 0
        var successfulNetworkObservations: Int = 0
        var failedNetworkObservations: Int = 0
        var unresolvedFailures: [ScreenHistorySoakFailureCode] = []
    }

    struct ReceiptPayload: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let sequence: Int
        let recordedAt: Date
        let activeDay: String?
        let captureState: ScreenHistorySoakCaptureState
        let captureDelta: ScreenHistorySoakCaptureCounters
        let processEvent: ScreenHistorySoakProcessEvent
        let networkObservation: ScreenHistorySoakNetworkObservation
        let privacyLeakCountDelta: Int
        let unexplainedCorruptionCountDelta: Int
        let storageBytes: Int64
        let storageFiles: Int
        let previousHash: String
        let cumulative: CumulativeState
    }

    struct ReceiptEntry: Codable, Equatable, Sendable {
        let payload: ReceiptPayload
        let hash: String
    }

    struct SummaryEnvelope: Codable, Equatable, Sendable {
        let summary: ScreenHistorySoakReceiptSummary
        let hash: String
    }

    struct LoadResult {
        let cumulative: CumulativeState
        let lastSequence: Int
        let lastHash: String
        let lastRecordedAt: Date?
        let historicalSummaries: [Int: ScreenHistorySoakReceiptSummary]
    }

    struct DeltaResult {
        let delta: ScreenHistorySoakCaptureCounters
        let regressed: Bool
    }

    static func defaultDirectoryURL() -> URL {
        AppPaths.directory("Screen History Soak")
    }

    static func defaultCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func prepareStorage(directoryURL: URL, logURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard try !isSymbolicLink(directoryURL) else {
            throw ScreenHistorySoakReceiptError.unsafeStorageLocation
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        if fileManager.fileExists(atPath: logURL.path) {
            guard try !isSymbolicLink(logURL) else {
                throw ScreenHistorySoakReceiptError.unsafeStorageLocation
            }
        } else {
            guard fileManager.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    static func enforceOwnerOnlyPermissions(
        directoryURL: URL,
        logURL: URL,
        summaryURL: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        if fileManager.fileExists(atPath: summaryURL.path) {
            guard try !isSymbolicLink(summaryURL) else {
                throw ScreenHistorySoakReceiptError.unsafeStorageLocation
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: summaryURL.path)
        }
    }

    static func isSymbolicLink(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    static func isValid(_ snapshot: ScreenHistorySoakSnapshot) -> Bool {
        let counters = snapshot.captureCounters
        return counters.cycles >= 0
            && counters.emissions >= 0
            && counters.duplicateSkips >= 0
            && counters.exclusionSkips >= 0
            && counters.sessionSkips >= 0
            && counters.inactivitySkips >= 0
            && counters.sourceFailures >= 0
            && counters.storageFailures >= 0
            && counters.fileVaultBlocks >= 0
            && counters.screenRecordingBlocks >= 0
            && snapshot.storageBytes >= 0
            && snapshot.storageFiles >= 0
            && snapshot.privacyLeakCountDelta >= 0
            && snapshot.unexplainedCorruptionCountDelta >= 0
    }

    static func delta(
        current: ScreenHistorySoakCaptureCounters,
        previous: ScreenHistorySoakCaptureCounters?,
        reset: Bool
    ) -> DeltaResult {
        guard let previous, !reset else {
            return DeltaResult(delta: current, regressed: false)
        }

        let values = [
            (current.cycles, previous.cycles),
            (current.emissions, previous.emissions),
            (current.duplicateSkips, previous.duplicateSkips),
            (current.exclusionSkips, previous.exclusionSkips),
            (current.sessionSkips, previous.sessionSkips),
            (current.inactivitySkips, previous.inactivitySkips),
            (current.sourceFailures, previous.sourceFailures),
            (current.storageFailures, previous.storageFailures),
            (current.fileVaultBlocks, previous.fileVaultBlocks),
            (current.screenRecordingBlocks, previous.screenRecordingBlocks),
        ]
        let regressed = values.contains { $0.0 < $0.1 }
        func difference(_ value: (Int, Int)) -> Int {
            value.0 >= value.1 ? value.0 - value.1 : value.0
        }
        return DeltaResult(
            delta: ScreenHistorySoakCaptureCounters(
                cycles: difference(values[0]),
                emissions: difference(values[1]),
                duplicateSkips: difference(values[2]),
                exclusionSkips: difference(values[3]),
                sessionSkips: difference(values[4]),
                inactivitySkips: difference(values[5]),
                sourceFailures: difference(values[6]),
                storageFailures: difference(values[7]),
                fileVaultBlocks: difference(values[8]),
                screenRecordingBlocks: difference(values[9])
            ),
            regressed: regressed
        )
    }

    static func add(
        _ lhs: ScreenHistorySoakCaptureCounters,
        _ rhs: ScreenHistorySoakCaptureCounters
    ) throws -> ScreenHistorySoakCaptureCounters {
        ScreenHistorySoakCaptureCounters(
            cycles: try add(lhs.cycles, rhs.cycles),
            emissions: try add(lhs.emissions, rhs.emissions),
            duplicateSkips: try add(lhs.duplicateSkips, rhs.duplicateSkips),
            exclusionSkips: try add(lhs.exclusionSkips, rhs.exclusionSkips),
            sessionSkips: try add(lhs.sessionSkips, rhs.sessionSkips),
            inactivitySkips: try add(lhs.inactivitySkips, rhs.inactivitySkips),
            sourceFailures: try add(lhs.sourceFailures, rhs.sourceFailures),
            storageFailures: try add(lhs.storageFailures, rhs.storageFailures),
            fileVaultBlocks: try add(lhs.fileVaultBlocks, rhs.fileVaultBlocks),
            screenRecordingBlocks: try add(lhs.screenRecordingBlocks, rhs.screenRecordingBlocks)
        )
    }

    static func add(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw ScreenHistorySoakReceiptError.invalidSnapshot }
        return result.partialValue
    }

    static func dayString(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func summary(
        cumulative: CumulativeState,
        sequence: Int,
        hash: String,
        recordedAt: Date?
    ) -> ScreenHistorySoakReceiptSummary {
        ScreenHistorySoakReceiptSummary(
            schemaVersion: schemaVersion,
            lastSequence: sequence,
            lastHash: hash,
            lastRecordedAt: recordedAt,
            activeDays: cumulative.activeDays.sorted(),
            totals: cumulative.totals,
            storageBytes: cumulative.storageBytes,
            storageFiles: cumulative.storageFiles,
            peakStorageBytes: cumulative.peakStorageBytes,
            peakStorageFiles: cumulative.peakStorageFiles,
            cleanRestarts: cumulative.cleanRestarts,
            crashRecoveries: cumulative.crashRecoveries,
            receiptResumes: cumulative.receiptResumes,
            privacyLeakCount: cumulative.privacyLeakCount,
            captureContentEgressCount: cumulative.captureContentEgressCount,
            unexplainedCorruptionCount: cumulative.unexplainedCorruptionCount,
            successfulNetworkObservations: cumulative.successfulNetworkObservations,
            failedNetworkObservations: cumulative.failedNetworkObservations,
            unresolvedFailures: cumulative.unresolvedFailures.sorted { $0.rawValue < $1.rawValue }
        )
    }

    static func load(logURL: URL) throws -> LoadResult {
        let data = try Data(contentsOf: logURL)
        guard !data.isEmpty else {
            return LoadResult(
                cumulative: CumulativeState(),
                lastSequence: 0,
                lastHash: genesisHash,
                lastRecordedAt: nil,
                historicalSummaries: [
                    0: summary(
                        cumulative: CumulativeState(),
                        sequence: 0,
                        hash: genesisHash,
                        recordedAt: nil
                    )
                ]
            )
        }
        guard data.last == 0x0A else {
            throw ScreenHistorySoakReceiptError.receiptCorruption
        }

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var expectedSequence = 1
        var expectedPreviousHash = genesisHash
        var cumulative = CumulativeState()
        var lastRecordedAt: Date?
        var historical: [Int: ScreenHistorySoakReceiptSummary] = [
            0: summary(
                cumulative: CumulativeState(),
                sequence: 0,
                hash: genesisHash,
                recordedAt: nil
            )
        ]

        for line in lines {
            let entry: ReceiptEntry
            do {
                entry = try decoder().decode(ReceiptEntry.self, from: Data(line))
            } catch {
                throw ScreenHistorySoakReceiptError.receiptCorruption
            }
            guard entry.payload.schemaVersion == schemaVersion,
                  entry.payload.sequence == expectedSequence,
                  entry.payload.previousHash == expectedPreviousHash,
                  entry.hash == hash(entry.payload)
            else {
                throw ScreenHistorySoakReceiptError.receiptCorruption
            }

            cumulative = entry.payload.cumulative
            lastRecordedAt = entry.payload.recordedAt
            expectedPreviousHash = entry.hash
            historical[expectedSequence] = summary(
                cumulative: cumulative,
                sequence: expectedSequence,
                hash: entry.hash,
                recordedAt: lastRecordedAt
            )
            expectedSequence += 1
        }

        return LoadResult(
            cumulative: cumulative,
            lastSequence: expectedSequence - 1,
            lastHash: expectedPreviousHash,
            lastRecordedAt: lastRecordedAt,
            historicalSummaries: historical
        )
    }

    static func append(_ entry: ReceiptEntry, to logURL: URL) throws {
        var data = try encoder().encode(entry)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    static func validateOrRefreshSummary(
        at summaryURL: URL,
        current: ScreenHistorySoakReceiptSummary,
        historical: [Int: ScreenHistorySoakReceiptSummary]
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: summaryURL.path) {
            guard try !isSymbolicLink(summaryURL) else {
                throw ScreenHistorySoakReceiptError.unsafeStorageLocation
            }
            let envelope: SummaryEnvelope
            do {
                envelope = try decoder().decode(
                    SummaryEnvelope.self,
                    from: Data(contentsOf: summaryURL)
                )
            } catch {
                throw ScreenHistorySoakReceiptError.receiptCorruption
            }
            guard envelope.hash == hash(envelope.summary),
                  let historicalSummary = historical[envelope.summary.lastSequence],
                  envelope.summary == historicalSummary
            else {
                throw ScreenHistorySoakReceiptError.receiptCorruption
            }
            if envelope.summary == current { return }
        }
        try writeSummary(current, to: summaryURL)
    }

    static func writeSummary(_ summary: ScreenHistorySoakReceiptSummary, to summaryURL: URL) throws {
        let envelope = SummaryEnvelope(summary: summary, hash: hash(summary))
        let data = try encoder().encode(envelope)
        let directory = summaryURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".summary-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let fileManager = FileManager.default
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if fileManager.fileExists(atPath: summaryURL.path) {
                _ = try fileManager.replaceItemAt(summaryURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: summaryURL)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: summaryURL.path)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func hash<T: Encodable>(_ value: T) -> String {
        let data = (try? encoder().encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
