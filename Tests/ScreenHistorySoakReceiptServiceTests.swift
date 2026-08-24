import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screen History soak receipt", .serialized)
struct ScreenHistorySoakReceiptServiceTests {
    @Test func sevenDistinctActiveDaysProduceRetirementReadinessAndCompleteMetrics() async throws {
        let fixture = try Fixture()
        let service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )

        var result: ScreenHistorySoakReceiptSummary?
        for day in 0..<7 {
            result = try await service.record(Self.snapshot(
                day: day,
                counters: ScreenHistorySoakCaptureCounters(
                    cycles: (day + 1) * 10,
                    emissions: (day + 1) * 4,
                    duplicateSkips: day + 1,
                    exclusionSkips: (day + 1) * 2,
                    sessionSkips: day + 1,
                    inactivitySkips: day + 1
                ),
                storageBytes: Int64((day + 1) * 1_000),
                storageFiles: (day + 1) * 4,
                network: .observedNoCaptureContentEgress
            ))
        }

        let summary = try #require(result)
        #expect(summary.activeDayCount == 7)
        #expect(summary.totals.cycles == 70)
        #expect(summary.totals.emissions == 28)
        #expect(summary.totals.duplicateSkips == 7)
        #expect(summary.totals.exclusionSkips == 14)
        #expect(summary.totals.sessionSkips == 7)
        #expect(summary.totals.inactivitySkips == 7)
        #expect(summary.storageBytes == 7_000)
        #expect(summary.storageFiles == 28)
        #expect(summary.peakStorageBytes == 7_000)
        #expect(summary.peakStorageFiles == 28)
        #expect(summary.successfulNetworkObservations == 7)
        #expect(summary.readinessBlockers.isEmpty)
        #expect(summary.isReadyForCoastRetirement)
    }

    @Test func inactiveSnapshotsDoNotCountAsActiveDays() async throws {
        let fixture = try Fixture()
        let service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )

        _ = try await service.record(Self.snapshot(
            day: 0,
            counters: .init(),
            network: .observedNoCaptureContentEgress
        ))
        _ = try await service.record(Self.snapshot(
            day: 1,
            counters: .init(),
            network: .observedNoCaptureContentEgress
        ))

        let summary = await service.currentSummary()
        #expect(summary.activeDays.isEmpty)
        #expect(summary.readinessBlockers.contains(.insufficientActiveDays))
    }

    @Test func receiptResumesAcrossLaunchesAndHandlesDeclaredCounterResets() async throws {
        let fixture = try Fixture()
        var service: ScreenHistorySoakReceiptService? = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )
        _ = try await service?.record(Self.snapshot(
            day: 0,
            counters: .init(cycles: 5, emissions: 3, duplicateSkips: 1),
            network: .observedNoCaptureContentEgress
        ))
        service = nil

        service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )
        let resumed = try await service?.record(Self.snapshot(
            day: 1,
            counters: .init(cycles: 2, emissions: 1, exclusionSkips: 1),
            processEvent: .cleanRestart
        ))

        #expect(resumed?.totals.cycles == 7)
        #expect(resumed?.totals.emissions == 4)
        #expect(resumed?.totals.duplicateSkips == 1)
        #expect(resumed?.totals.exclusionSkips == 1)
        #expect(resumed?.cleanRestarts == 1)
        #expect(resumed?.receiptResumes == 1)
        #expect(resumed?.lastSequence == 2)
    }

    @Test func crashesFailuresAndResolutionsRemainContentFreeAndExplicit() async throws {
        let fixture = try Fixture()
        let service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )

        let failed = try await service.record(Self.snapshot(
            day: 0,
            counters: .init(cycles: 3, sourceFailures: 1),
            processEvent: .crashRecovery,
            network: .observationFailed,
            newFailures: [.storageObservationFailed]
        ))
        #expect(failed.crashRecoveries == 1)
        #expect(failed.failedNetworkObservations == 1)
        #expect(Set(failed.unresolvedFailures) == [
            .captureSourceFailure,
            .networkObservationFailed,
            .storageObservationFailed,
            .unexpectedCaptureExit,
        ])

        let resolved = try await service.record(Self.snapshot(
            day: 1,
            counters: .init(cycles: 4, sourceFailures: 1),
            network: .observedNoCaptureContentEgress,
            resolvedFailures: Set(ScreenHistorySoakFailureCode.allCases)
        ))
        #expect(resolved.unresolvedFailures.isEmpty)
        #expect(resolved.crashRecoveries == 1)
        #expect(resolved.failedNetworkObservations == 1)
        #expect(resolved.successfulNetworkObservations == 1)
    }

    @Test func privacyEgressAndCorruptionObservationsPermanentlyBlockTheSoak() async throws {
        let fixture = try Fixture()
        let service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )

        for day in 0..<7 {
            _ = try await service.record(Self.snapshot(
                day: day,
                counters: .init(cycles: day + 1),
                network: day == 2
                    ? .captureContentEgressDetected
                    : .observedNoCaptureContentEgress,
                privacyLeaks: day == 3 ? 1 : 0,
                corruptions: day == 4 ? 1 : 0
            ))
        }

        let summary = await service.currentSummary()
        #expect(summary.activeDayCount == 7)
        #expect(summary.privacyLeakCount == 1)
        #expect(summary.captureContentEgressCount == 1)
        #expect(summary.unexplainedCorruptionCount == 1)
        #expect(Set(summary.readinessBlockers) == [
            .privacyLeakDetected,
            .captureContentEgressDetected,
            .unexplainedCorruption,
        ])
        #expect(!summary.isReadyForCoastRetirement)
    }

    @Test func aSuccessfulNetworkObservationIsRequiredToProveNoContentEgress() async throws {
        let fixture = try Fixture()
        let service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )

        for day in 0..<7 {
            _ = try await service.record(Self.snapshot(
                day: day,
                counters: .init(cycles: day + 1)
            ))
        }

        let summary = await service.currentSummary()
        #expect(summary.readinessBlockers == [.noSuccessfulNetworkObservation])
    }

    @Test func counterRegressionIsTrackedInsteadOfSilentlyLosingCycles() async throws {
        let fixture = try Fixture()
        let service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )
        _ = try await service.record(Self.snapshot(
            day: 0,
            counters: .init(cycles: 10, emissions: 5)
        ))
        let result = try await service.record(Self.snapshot(
            day: 1,
            counters: .init(cycles: 2, emissions: 1)
        ))

        #expect(result.totals.cycles == 12)
        #expect(result.totals.emissions == 6)
        #expect(result.unresolvedFailures == [.counterRegression])
    }

    @Test func logAndSummaryContainNoScreenContentFieldsAndUseAHashChain() async throws {
        let fixture = try Fixture()
        let service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )
        _ = try await service.record(Self.snapshot(
            day: 0,
            counters: .init(cycles: 1, emissions: 1),
            storageBytes: 123,
            storageFiles: 1,
            network: .observedNoCaptureContentEgress
        ))
        _ = try await service.record(Self.snapshot(
            day: 1,
            counters: .init(cycles: 2, emissions: 2),
            storageBytes: 234,
            storageFiles: 2
        ))

        let log = try String(contentsOf: service.logURL, encoding: .utf8)
        let summary = try String(contentsOf: service.summaryURL, encoding: .utf8)
        for forbidden in [
            "recognizedText", "ocrText", "windowTitle", "applicationName",
            "bundleIdentifier", "domain", "mediaLocator", "filePath", "pageURL",
        ] {
            #expect(!log.contains(forbidden))
            #expect(!summary.contains(forbidden))
        }

        let lines = log.split(separator: "\n")
        #expect(lines.count == 2)
        let first = try #require(
            JSONSerialization.jsonObject(with: Data(String(lines[0]).utf8)) as? [String: Any]
        )
        let second = try #require(
            JSONSerialization.jsonObject(with: Data(String(lines[1]).utf8)) as? [String: Any]
        )
        let firstHash = try #require(first["hash"] as? String)
        let secondPayload = try #require(second["payload"] as? [String: Any])
        #expect(firstHash.count == 64)
        #expect(secondPayload["previousHash"] as? String == firstHash)
    }

    @Test func storageUsesOwnerOnlyPermissions() async throws {
        let fixture = try Fixture()
        let service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )
        _ = try await service.record(Self.snapshot(day: 0, counters: .init(cycles: 1)))

        #expect(try Self.permissions(service.directoryURL) == 0o700)
        #expect(try Self.permissions(service.logURL) == 0o600)
        #expect(try Self.permissions(service.summaryURL) == 0o600)
    }

    @Test func mutatedLogIsRejectedAsCorruptOnResume() async throws {
        let fixture = try Fixture()
        let service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )
        _ = try await service.record(Self.snapshot(
            day: 0,
            counters: .init(cycles: 1),
            network: .observedNoCaptureContentEgress
        ))

        let original = try String(contentsOf: service.logURL, encoding: .utf8)
        let mutated = original.replacingOccurrences(of: "running", with: "stopped")
        try Data(mutated.utf8).write(to: service.logURL)

        do {
            _ = try ScreenHistorySoakReceiptService(
                directoryURL: fixture.directory,
                calendar: Self.utcCalendar
            )
            Issue.record("A modified hash-chain entry was accepted")
        } catch let error as ScreenHistorySoakReceiptError {
            #expect(error == .receiptCorruption)
        }
    }

    @Test func staleButValidSummaryIsRecoveredFromTheAppendOnlyLog() async throws {
        let fixture = try Fixture()
        var service: ScreenHistorySoakReceiptService? = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )
        _ = try await service?.record(Self.snapshot(day: 0, counters: .init(cycles: 1)))
        let staleSummary = try Data(contentsOf: try #require(service?.summaryURL))
        _ = try await service?.record(Self.snapshot(day: 1, counters: .init(cycles: 2)))
        let summaryURL = try #require(service?.summaryURL)
        service = nil
        try staleSummary.write(to: summaryURL)

        let resumed = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )
        let summary = await resumed.currentSummary()
        #expect(summary.lastSequence == 2)
        #expect(summary.totals.cycles == 2)

        let refreshed = try String(contentsOf: resumed.summaryURL, encoding: .utf8)
        #expect(refreshed.contains("\"lastSequence\":2"))
    }

    @Test func negativeOrOverflowingCountersAreRejected() async throws {
        let fixture = try Fixture()
        let service = try ScreenHistorySoakReceiptService(
            directoryURL: fixture.directory,
            calendar: Self.utcCalendar
        )

        do {
            _ = try await service.record(Self.snapshot(
                day: 0,
                counters: .init(cycles: -1)
            ))
            Issue.record("A negative capture counter was accepted")
        } catch let error as ScreenHistorySoakReceiptError {
            #expect(error == .invalidSnapshot)
        }
    }
}

private extension ScreenHistorySoakReceiptServiceTests {
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    static func snapshot(
        day: Int,
        counters: ScreenHistorySoakCaptureCounters,
        storageBytes: Int64 = 0,
        storageFiles: Int = 0,
        processEvent: ScreenHistorySoakProcessEvent = .none,
        network: ScreenHistorySoakNetworkObservation = .notObserved,
        privacyLeaks: Int = 0,
        corruptions: Int = 0,
        newFailures: Set<ScreenHistorySoakFailureCode> = [],
        resolvedFailures: Set<ScreenHistorySoakFailureCode> = []
    ) -> ScreenHistorySoakSnapshot {
        ScreenHistorySoakSnapshot(
            observedAt: Date(timeIntervalSince1970: 1_767_225_600 + Double(day * 86_400)),
            captureState: .running,
            captureCounters: counters,
            storageBytes: storageBytes,
            storageFiles: storageFiles,
            processEvent: processEvent,
            networkObservation: network,
            privacyLeakCountDelta: privacyLeaks,
            unexplainedCorruptionCountDelta: corruptions,
            newFailures: newFailures,
            resolvedFailures: resolvedFailures
        )
    }

    static func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        return (value as? NSNumber)?.intValue ?? -1
    }

    final class Fixture {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("screen-history-soak-\(UUID().uuidString)", isDirectory: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
