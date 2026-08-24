import Foundation
@testable import QuickLaunch

enum ScreenHistoryEvaluationSuite: String, Codable, Sendable {
    case product
    case security
}

enum ScreenHistoryEvaluationResult: String, Codable, Sendable {
    /// The test body reached its receipt boundary. Swift Testing remains the
    /// authority for assertion pass or failure.
    case completed
    /// The body left scope before it reached its receipt boundary.
    case aborted
}

enum ScreenHistoryNetworkObservationMode: String, Codable, Sendable {
    case notMeasured = "not_measured"
    case staticScan = "static_scan"
}

struct ScreenHistoryNetworkObservation: Codable, Equatable, Sendable {
    let mode: ScreenHistoryNetworkObservationMode
    let observedCallCount: Int?
    let runtimeDenied: Bool?

    private enum CodingKeys: String, CodingKey {
        case mode
        case observedCallCount = "observed_call_count"
        case runtimeDenied = "runtime_denied"
    }

    static let notMeasured = ScreenHistoryNetworkObservation(
        mode: .notMeasured,
        observedCallCount: nil,
        runtimeDenied: nil
    )

    static func staticScan(observedCallCount: Int, runtimeDenied: Bool) -> Self {
        ScreenHistoryNetworkObservation(
            mode: .staticScan,
            observedCallCount: max(0, observedCallCount),
            runtimeDenied: runtimeDenied
        )
    }
}

struct ScreenHistoryEvaluationMeasurements: Codable, Equatable, Sendable {
    let localFileCount: Int?
    let localStatementCount: Int?
    let toolCallCount: Int?
    let helperCallCount: Int?
    let network: ScreenHistoryNetworkObservation
    let sourceRootCount: Int

    private enum CodingKeys: String, CodingKey {
        case localFileCount = "local_file_count"
        case localStatementCount = "local_statement_count"
        case toolCallCount = "tool_call_count"
        case helperCallCount = "helper_call_count"
        case network
        case sourceRootCount = "source_root_count"
    }

    init(
        localFileCount: Int? = nil,
        localStatementCount: Int? = nil,
        toolCallCount: Int? = nil,
        helperCallCount: Int? = nil,
        network: ScreenHistoryNetworkObservation = .notMeasured,
        sourceRootCount: Int
    ) {
        self.localFileCount = localFileCount.map { max(0, $0) }
        self.localStatementCount = localStatementCount.map { max(0, $0) }
        self.toolCallCount = toolCallCount.map { max(0, $0) }
        self.helperCallCount = helperCallCount.map { max(0, $0) }
        self.network = network
        self.sourceRootCount = max(0, sourceRootCount)
    }
}

struct ScreenHistoryEvaluationReceiptRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let storeSchemaVersion: Int32
    let runID: String
    let recordedAt: Date
    let suite: ScreenHistoryEvaluationSuite
    let caseID: String
    let result: ScreenHistoryEvaluationResult
    let elapsedMilliseconds: UInt64
    let measurements: ScreenHistoryEvaluationMeasurements

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case storeSchemaVersion = "store_schema_version"
        case runID = "run_id"
        case recordedAt = "recorded_at"
        case suite
        case caseID = "case_id"
        case result
        case elapsedMilliseconds = "elapsed_milliseconds"
        case measurements
    }
}

enum ScreenHistoryEvaluationReceiptError: Error, Equatable {
    case invalidCaseID
    case unableToCreateReceipt
}

final class ScreenHistoryEvaluationReceiptWriter: @unchecked Sendable {
    static let shared: ScreenHistoryEvaluationReceiptWriter = {
        let runID = UUID().uuidString.lowercased()
        return ScreenHistoryEvaluationReceiptWriter(
            receiptURL: defaultReceiptURL(runID: runID),
            runID: runID
        )
    }()

    let receiptURL: URL
    let runID: String

    private let now: () -> Date
    private let uptimeNanoseconds: () -> UInt64
    private let lock = NSLock()

    init(
        receiptURL: URL,
        runID: String,
        now: @escaping () -> Date = Date.init,
        uptimeNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.receiptURL = receiptURL.standardizedFileURL
        self.runID = runID
        self.now = now
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    func begin(
        suite: ScreenHistoryEvaluationSuite,
        caseID: String
    ) throws -> ScreenHistoryEvaluationRun {
        guard Self.isValidCaseID(caseID) else {
            throw ScreenHistoryEvaluationReceiptError.invalidCaseID
        }
        return ScreenHistoryEvaluationRun(
            writer: self,
            suite: suite,
            caseID: caseID,
            startedAtNanoseconds: uptimeNanoseconds()
        )
    }

    fileprivate func append(
        suite: ScreenHistoryEvaluationSuite,
        caseID: String,
        result: ScreenHistoryEvaluationResult,
        startedAtNanoseconds: UInt64,
        measurements: ScreenHistoryEvaluationMeasurements
    ) throws {
        let finishedAt = uptimeNanoseconds()
        let elapsed = finishedAt >= startedAtNanoseconds
            ? (finishedAt - startedAtNanoseconds) / 1_000_000
            : 0
        let record = ScreenHistoryEvaluationReceiptRecord(
            schemaVersion: 1,
            storeSchemaVersion: SQLiteScreenHistoryStore.schemaVersion,
            runID: runID,
            recordedAt: now(),
            suite: suite,
            caseID: caseID,
            result: result,
            elapsedMilliseconds: elapsed,
            measurements: measurements
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        let directory = receiptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: receiptURL.path) {
            guard FileManager.default.createFile(
                atPath: receiptURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw ScreenHistoryEvaluationReceiptError.unableToCreateReceipt
            }
        }
        let handle = try FileHandle(forWritingTo: receiptURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func isValidCaseID(_ value: String) -> Bool {
        value.count >= 4
            && value.count <= 64
            && value.hasPrefix("SH-")
            && value.unicodeScalars.allSatisfy {
                (65...90).contains($0.value)
                    || (48...57).contains($0.value)
                    || $0 == "-"
            }
    }

    private static func defaultReceiptURL(runID: String) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let directory: URL
        if let override = environment["SCREEN_HISTORY_EVALUATION_RECEIPT_DIRECTORY"],
           !override.isEmpty {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("screen-history-evaluation-receipts", isDirectory: true)
        }
        return directory.appendingPathComponent("screen-history-evaluation-\(runID).jsonl")
    }
}

final class ScreenHistoryEvaluationRun: @unchecked Sendable {
    private let writer: ScreenHistoryEvaluationReceiptWriter
    private let suite: ScreenHistoryEvaluationSuite
    private let caseID: String
    private let startedAtNanoseconds: UInt64
    private let lock = NSLock()
    private var isFinished = false

    fileprivate init(
        writer: ScreenHistoryEvaluationReceiptWriter,
        suite: ScreenHistoryEvaluationSuite,
        caseID: String,
        startedAtNanoseconds: UInt64
    ) {
        self.writer = writer
        self.suite = suite
        self.caseID = caseID
        self.startedAtNanoseconds = startedAtNanoseconds
    }

    func finish(
        result: ScreenHistoryEvaluationResult = .completed,
        measurements: ScreenHistoryEvaluationMeasurements
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        try writer.append(
            suite: suite,
            caseID: caseID,
            result: result,
            startedAtNanoseconds: startedAtNanoseconds,
            measurements: measurements
        )
        isFinished = true
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        try? writer.append(
            suite: suite,
            caseID: caseID,
            result: .aborted,
            startedAtNanoseconds: startedAtNanoseconds,
            measurements: ScreenHistoryEvaluationMeasurements(sourceRootCount: 0)
        )
    }
}

extension URL {
    func screenHistoryEvaluationLocalFileCount() -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: self,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let fileURL as URL in enumerator {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
            }
        }
        return count
    }
}
