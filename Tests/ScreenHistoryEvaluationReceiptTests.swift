import Foundation
import Testing

@Suite("Screen History evaluation receipt", .serialized)
struct ScreenHistoryEvaluationReceiptTests {
    @Test func writesDeterministicContentFreeJSONLine() throws {
        let fixture = try ReceiptFixture(ticks: [1_000_000_000, 1_125_000_000])
        let run = try fixture.writer.begin(suite: .product, caseID: "SH-R01")
        try run.finish(measurements: ScreenHistoryEvaluationMeasurements(
            localFileCount: 3,
            localStatementCount: 4,
            toolCallCount: 0,
            helperCallCount: 2,
            network: .staticScan(observedCallCount: 0, runtimeDenied: true),
            sourceRootCount: 1
        ))

        let records = try fixture.records()
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.schemaVersion == 1)
        #expect(record.storeSchemaVersion == 7)
        #expect(record.runID == fixture.runID)
        #expect(record.recordedAt == fixture.now)
        #expect(record.suite == .product)
        #expect(record.caseID == "SH-R01")
        #expect(record.result == .completed)
        #expect(record.elapsedMilliseconds == 125)
        #expect(record.measurements.localFileCount == 3)
        #expect(record.measurements.localStatementCount == 4)
        #expect(record.measurements.toolCallCount == 0)
        #expect(record.measurements.helperCallCount == 2)
        #expect(record.measurements.sourceRootCount == 1)
        #expect(record.measurements.network == .staticScan(
            observedCallCount: 0,
            runtimeDenied: true
        ))

        let persisted = try String(contentsOf: fixture.receiptURL, encoding: .utf8).lowercased()
        for forbiddenField in ["ocr", "title", "domain", "path", "query"] {
            #expect(!persisted.contains(forbiddenField))
        }
        #expect(try fixture.permissions(fixture.directory) == 0o700)
        #expect(try fixture.permissions(fixture.receiptURL) == 0o600)
    }

    @Test func appendsOneRecordPerCaseInStartOrder() throws {
        let fixture = try ReceiptFixture(ticks: [10, 20, 30, 50])
        let first = try fixture.writer.begin(suite: .product, caseID: "SH-F01")
        try first.finish(measurements: .init(sourceRootCount: 1))
        let second = try fixture.writer.begin(suite: .security, caseID: "SH-SEC-01")
        try second.finish(measurements: .init(sourceRootCount: 0))

        let records = try fixture.records()
        #expect(records.map(\.caseID) == ["SH-F01", "SH-SEC-01"])
        #expect(records.map(\.result) == [.completed, .completed])
    }

    @Test func unfinishedRunRecordsAbortedWithoutFreeFormFields() throws {
        let fixture = try ReceiptFixture(ticks: [100, 250])
        var run: ScreenHistoryEvaluationRun? = try fixture.writer.begin(
            suite: .security,
            caseID: "SH-SEC-ABORT"
        )
        run = nil
        #expect(run == nil)

        let record = try #require(try fixture.records().first)
        #expect(record.result == .aborted)
        #expect(record.elapsedMilliseconds == 0)
        #expect(record.measurements.sourceRootCount == 0)
    }

    @Test func rejectsIdentifiersThatCouldCarryContent() throws {
        let fixture = try ReceiptFixture(ticks: [])
        #expect(throws: ScreenHistoryEvaluationReceiptError.invalidCaseID) {
            _ = try fixture.writer.begin(suite: .product, caseID: "starter plan site:private.example")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.receiptURL.path))
    }
}

private final class ReceiptFixture: @unchecked Sendable {
    let directory: URL
    let receiptURL: URL
    let runID = "00000000-0000-0000-0000-000000000001"
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let writer: ScreenHistoryEvaluationReceiptWriter
    private let clock: ReceiptClock

    init(ticks: [UInt64]) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-evaluation-receipt-\(UUID().uuidString)")
        receiptURL = directory.appendingPathComponent("receipt.jsonl")
        clock = ReceiptClock(ticks)
        writer = ScreenHistoryEvaluationReceiptWriter(
            receiptURL: receiptURL,
            runID: runID,
            now: { [now] in now },
            uptimeNanoseconds: { [clock] in clock.next() }
        )
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func records() throws -> [ScreenHistoryEvaluationReceiptRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: receiptURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(ScreenHistoryEvaluationReceiptRecord.self, from: Data($0.utf8)) }
    }

    func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }
}

private final class ReceiptClock: @unchecked Sendable {
    private var ticks: [UInt64]
    private let lock = NSLock()

    init(_ ticks: [UInt64]) { self.ticks = ticks }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return ticks.isEmpty ? 0 : ticks.removeFirst()
    }
}
