import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import QuickLaunch

@Suite("Screen history retirement review")
struct ScreenHistoryRetirementReviewServiceTests {
    @Test func storeSampleCoversFullImportedPopulationWithDeterministicSpread() async throws {
        let fixture = try RetirementFixture()
        let mediaRoot = fixture.directory.appendingPathComponent("owned-media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [mediaRoot]
        )

        for index in 0..<250 {
            var image: String?
            var media: String?
            switch index % 4 {
            case 0: image = mediaRoot.appendingPathComponent("image-\(index).jpg").path
            case 1: media = mediaRoot.appendingPathComponent("video-\(index).mp4").path
            case 2:
                image = mediaRoot.appendingPathComponent("image-\(index).jpg").path
                media = mediaRoot.appendingPathComponent("video-\(index).mp4").path
            default: image = mediaRoot.appendingPathComponent("fallback-\(index).jpg").path
            }
            var mediaPayloads: [(locator: String, payload: Data)] = []
            if let image {
                mediaPayloads.append((image, Data("image-\(index)".utf8)))
            }
            if let media {
                mediaPayloads.append((media, Data("video-\(index)".utf8)))
            }
            for item in mediaPayloads {
                try item.payload.write(to: URL(fileURLWithPath: item.locator))
            }
            let input = ScreenHistoryFrameInput(
                source: .coast,
                sourceIdentifier: String(index + 1),
                capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                application: "App \(index % 13)",
                ocrText: "metadata \(index)",
                imageLocator: image,
                mediaLocator: media,
                mediaFrameIndex: media == nil ? nil : index,
                mediaFrameCount: media == nil ? nil : 300,
                displayGeometry: ScreenHistoryDisplayGeometry(
                    x: Double((index % 3) * 1_728),
                    y: 0,
                    width: 1_728,
                    height: 1_117
                ),
                byteCount: Int64(index + 1)
            )
            _ = try await store.applyMigration(
                input,
                status: .imported,
                migratedAt: Date(timeIntervalSince1970: 1_000)
            )
            for (position, item) in mediaPayloads.enumerated() {
                _ = try await store.recordMediaMigrationOutcome(
                    sourcePathHash: sha256(Data("source-\(index)-\(position)".utf8)),
                    destinationLocator: item.locator,
                    byteCount: Int64(item.payload.count),
                    contentHash: sha256(item.payload),
                    status: .copied,
                    migratedAt: Date(timeIntervalSince1970: 1_001)
                )
            }
        }

        let first = try await store.coastRetirementSample(limit: 100)
        let second = try await store.coastRetirementSample(limit: 100)

        #expect(first == second)
        #expect(first.totalImportedMoments == 250)
        #expect(first.eligibleImportedMoments == 250)
        #expect(first.moments.count == 100)
        #expect(first.moments.first?.capturedAt.timeIntervalSince1970 ?? 99 < 3)
        #expect(first.moments.last?.capturedAt.timeIntervalSince1970 ?? 0 > 246)
        #expect(Set(first.moments.compactMap(\.application)).count >= 10)
        #expect(Set(first.moments.map(mediaKind)).count == 3)
        #expect(Set(first.moments.compactMap { $0.displayGeometry?.stableIdentifier }).count == 3)
    }

    @Test func hashMismatchRemainsInPopulationButCannotEnterReviewSample() async throws {
        let fixture = try RetirementFixture()
        let store = try SQLiteScreenHistoryStore(databaseURL: fixture.databaseURL)
        let original = coastInput(id: "1", text: "original")
        _ = try await store.applyMigration(
            original,
            status: .imported,
            migratedAt: Date(timeIntervalSince1970: 10)
        )
        _ = try await store.record(coastInput(id: "1", text: "changed after import"))

        let sample = try await store.coastRetirementSample(limit: 100)
        #expect(sample.totalImportedMoments == 1)
        #expect(sample.eligibleImportedMoments == 0)
        #expect(sample.moments.isEmpty)
    }

    @Test func ledgerIsOwnerOnlyMinimalAndPersistsDecisionsWithTimestamps() async throws {
        let fixture = try RetirementFixture()
        let population = samplePopulation(count: 3)
        let sampler = MutableRetirementSampler(population)
        let reviewedAt = Date(timeIntervalSince1970: 42_000)
        let service = ScreenHistoryRetirementReviewService(
            sampler: sampler,
            ledgerURL: fixture.ledgerURL,
            clock: { reviewedAt }
        )

        let initial = try await service.refresh()
        let first = try #require(initial.moments.first)
        let decided = try await service.decide(
            sampleID: first.sampleID,
            contentHash: first.contentHash,
            decision: .accepted
        )
        #expect(decided.moments.first?.decision == .accepted)
        #expect(decided.moments.first?.reviewedAt == reviewedAt)

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.ledgerURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.ledgerURL.deletingLastPathComponent().path
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let json = try String(contentsOf: fixture.ledgerURL, encoding: .utf8)
        #expect(json.contains(first.sampleID))
        #expect(json.contains(first.contentHash))
        #expect(!json.contains("secret OCR"))
        #expect(!json.contains("definitely-not-opened"))

        let reopened = ScreenHistoryRetirementReviewService(
            sampler: sampler,
            ledgerURL: fixture.ledgerURL
        )
        let restored = try await reopened.refresh()
        #expect(restored.moments.first?.decision == .accepted)
        #expect(restored.moments.first?.reviewedAt == reviewedAt)
    }

    @Test func exactlyOneHundredAcceptancesAndZeroFlagsGateLargePopulation() async throws {
        let fixture = try RetirementFixture()
        let sampler = MutableRetirementSampler(samplePopulation(count: 125))
        let service = ScreenHistoryRetirementReviewService(
            sampler: sampler,
            ledgerURL: fixture.ledgerURL,
            clock: { Date(timeIntervalSince1970: 55_000) }
        )
        let initial = try await service.refresh()
        #expect(initial.moments.count == 100)
        #expect(initial.readiness.requiredAcceptedMoments == 100)
        #expect(initial.readiness.isReady == false)

        var current = initial
        for moment in initial.moments {
            current = try await service.decide(
                sampleID: moment.sampleID,
                contentHash: moment.contentHash,
                decision: .accepted
            )
        }
        #expect(current.readiness.acceptedMoments == 100)
        #expect(current.readiness.flaggedMoments == 0)
        #expect(current.readiness.isReady)

        let first = try #require(current.moments.first)
        current = try await service.decide(
            sampleID: first.sampleID,
            contentHash: first.contentHash,
            decision: .flagged
        )
        #expect(current.readiness.acceptedMoments == 99)
        #expect(current.readiness.flaggedMoments == 1)
        #expect(current.readiness.isReady == false)
    }

    @Test func everyMomentMustBeAcceptedWhenPopulationIsBelowOneHundred() async throws {
        let fixture = try RetirementFixture()
        let sampler = MutableRetirementSampler(samplePopulation(count: 3))
        let service = ScreenHistoryRetirementReviewService(
            sampler: sampler,
            ledgerURL: fixture.ledgerURL
        )
        let initial = try await service.refresh()
        #expect(initial.readiness.requiredAcceptedMoments == 3)

        var current = initial
        for moment in initial.moments {
            current = try await service.decide(
                sampleID: moment.sampleID,
                contentHash: moment.contentHash,
                decision: .accepted
            )
        }
        #expect(current.readiness.acceptedMoments == 3)
        #expect(current.readiness.flaggedMoments == 0)
        #expect(current.readiness.pendingMoments == 0)
        #expect(current.readiness.isReady)
    }

    @Test func contentOrSampleDriftInvalidatesEveryPriorDecision() async throws {
        let fixture = try RetirementFixture()
        let original = samplePopulation(count: 4)
        let sampler = MutableRetirementSampler(original)
        let service = ScreenHistoryRetirementReviewService(
            sampler: sampler,
            ledgerURL: fixture.ledgerURL,
            clock: { Date(timeIntervalSince1970: 70_000) }
        )
        let initial = try await service.refresh()
        for moment in initial.moments.prefix(2) {
            _ = try await service.decide(
                sampleID: moment.sampleID,
                contentHash: moment.contentHash,
                decision: .accepted
            )
        }

        var changedFrames = original.moments
        changedFrames[3] = sampleFrame(index: 3, hashSalt: 900)
        await sampler.set(ScreenHistoryRetirementSamplePopulation(
            totalImportedMoments: 4,
            eligibleImportedMoments: 4,
            moments: changedFrames
        ))
        let hashChanged = try await service.refresh()
        #expect(hashChanged.moments.allSatisfy { $0.decision == .pending && $0.reviewedAt == nil })

        let first = try #require(hashChanged.moments.first)
        _ = try await service.decide(
            sampleID: first.sampleID,
            contentHash: first.contentHash,
            decision: .accepted
        )
        let replaced = [sampleFrame(index: 99)] + Array(changedFrames.dropFirst())
        await sampler.set(ScreenHistoryRetirementSamplePopulation(
            totalImportedMoments: 4,
            eligibleImportedMoments: 4,
            moments: replaced
        ))
        let sampleChanged = try await service.refresh()
        #expect(sampleChanged.moments.allSatisfy { $0.decision == .pending && $0.reviewedAt == nil })
    }

    @Test func staleDecisionFailsClosedAndPreparesNewPendingLedger() async throws {
        let fixture = try RetirementFixture()
        let original = samplePopulation(count: 2)
        let sampler = MutableRetirementSampler(original)
        let service = ScreenHistoryRetirementReviewService(
            sampler: sampler,
            ledgerURL: fixture.ledgerURL
        )
        let initial = try await service.refresh()
        let stale = try #require(initial.moments.first)

        await sampler.set(samplePopulation(count: 3))
        await #expect(throws: ScreenHistoryRetirementReviewError.staleSample) {
            try await service.decide(
                sampleID: stale.sampleID,
                contentHash: stale.contentHash,
                decision: .accepted
            )
        }
        let current = try await service.refresh()
        #expect(current.moments.count == 3)
        #expect(current.moments.allSatisfy { $0.decision == .pending })
    }

    @Test func incompleteImportedPopulationCanNeverBeReady() async throws {
        let fixture = try RetirementFixture()
        let eligible = Array(samplePopulation(count: 2).moments.prefix(1))
        let sampler = MutableRetirementSampler(ScreenHistoryRetirementSamplePopulation(
            totalImportedMoments: 2,
            eligibleImportedMoments: 1,
            moments: eligible
        ))
        let service = ScreenHistoryRetirementReviewService(
            sampler: sampler,
            ledgerURL: fixture.ledgerURL
        )
        let initial = try await service.refresh()
        let only = try #require(initial.moments.first)
        let reviewed = try await service.decide(
            sampleID: only.sampleID,
            contentHash: only.contentHash,
            decision: .accepted
        )
        #expect(reviewed.readiness.hasCompleteImportedPopulation == false)
        #expect(reviewed.readiness.isReady == false)
        #expect(reviewed.readiness.requiredAcceptedMoments == 2)
    }

    @Test func retirementFailsForPhysicalMediaMismatchAndNormalizedDrift() async throws {
        let fixture = try RetirementFixture()
        let mediaURL = fixture.directory.appendingPathComponent("owned.mp4")
        let original = Data("synthetic-owned-media".utf8)
        try original.write(to: mediaURL)
        let input = ScreenHistoryFrameInput(
            source: .coast,
            sourceIdentifier: "1",
            capturedAt: Date(timeIntervalSince1970: 100),
            application: "Synthetic",
            bundleIdentifier: "test.synthetic.retirement",
            ocrText: "synthetic metadata",
            mediaLocator: mediaURL.path,
            mediaFrameIndex: 0,
            mediaFrameCount: 1,
            byteCount: Int64(original.count)
        )
        let store = try SQLiteScreenHistoryStore(
            databaseURL: fixture.databaseURL,
            ownedMediaRootURLs: [fixture.directory]
        )
        _ = try await store.applyMigration(
            input,
            status: .imported,
            migratedAt: Date(timeIntervalSince1970: 101)
        )
        _ = try await store.recordMediaMigrationOutcome(
            sourcePathHash: sha256(Data("synthetic-source".utf8)),
            destinationLocator: mediaURL.path,
            byteCount: Int64(original.count),
            contentHash: sha256(original),
            status: .copied,
            migratedAt: Date(timeIntervalSince1970: 102)
        )

        let complete = try await store.coastRetirementSample(limit: 100)
        #expect(complete.totalImportedMoments == 1)
        #expect(complete.eligibleImportedMoments == 1)
        #expect(complete.mediaIntegrityFailureMoments == 0)
        #expect(complete.normalizedStructureDrift == 0)

        try Data("tampered-media-same-purpose".utf8).write(to: mediaURL)
        let mismatched = try await store.coastRetirementSample(limit: 100)
        #expect(mismatched.eligibleImportedMoments == 0)
        #expect(mismatched.mediaIntegrityFailureMoments == 1)
        let mismatchService = ScreenHistoryRetirementReviewService(
            sampler: store,
            ledgerURL: fixture.ledgerURL
        )
        let mismatchInitial = try await mismatchService.refresh()
        let mismatchMoment = try #require(mismatchInitial.moments.first)
        let mismatchReviewed = try await mismatchService.decide(
            sampleID: mismatchMoment.sampleID,
            contentHash: mismatchMoment.contentHash,
            decision: .accepted
        )
        #expect(!mismatchReviewed.readiness.isReady)

        try FileManager.default.removeItem(at: mediaURL)
        let missing = try await store.coastRetirementSample(limit: 100)
        #expect(missing.eligibleImportedMoments == 0)
        #expect(missing.mediaIntegrityFailureMoments == 1)

        try original.write(to: mediaURL)
        do {
            let database = try LocalSQLiteConnection(
                url: fixture.databaseURL,
                flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            )
            try database.execute("UPDATE screen_history_frame SET media_ref_id = NULL WHERE source = 'coast';")
        }
        let drifted = try await store.coastRetirementSample(limit: 100)
        #expect(drifted.eligibleImportedMoments == 1)
        #expect(drifted.mediaIntegrityFailureMoments == 0)
        #expect(drifted.normalizedStructureDrift == 1)
        let driftInitial = try await mismatchService.refresh()
        let driftMoment = try #require(driftInitial.moments.first)
        let driftReviewed = try await mismatchService.decide(
            sampleID: driftMoment.sampleID,
            contentHash: driftMoment.contentHash,
            decision: .accepted
        )
        #expect(!driftReviewed.readiness.isReady)
        #expect(driftReviewed.readiness.normalizedStructureDrift == 1)
    }

    @Test func malformedLedgerIsNotSilentlyReplaced() async throws {
        let fixture = try RetirementFixture()
        try Data("not-json".utf8).write(to: fixture.ledgerURL)
        let service = ScreenHistoryRetirementReviewService(
            sampler: MutableRetirementSampler(samplePopulation(count: 1)),
            ledgerURL: fixture.ledgerURL
        )

        await #expect(throws: ScreenHistoryRetirementReviewError.invalidLedger) {
            try await service.refresh()
        }
        #expect(try String(contentsOf: fixture.ledgerURL, encoding: .utf8) == "not-json")
    }
}

private actor MutableRetirementSampler: ScreenHistoryRetirementSampling {
    private var population: ScreenHistoryRetirementSamplePopulation

    init(_ population: ScreenHistoryRetirementSamplePopulation) {
        self.population = population
    }

    func coastRetirementSample(limit: Int) -> ScreenHistoryRetirementSamplePopulation {
        ScreenHistoryRetirementSamplePopulation(
            totalImportedMoments: population.totalImportedMoments,
            eligibleImportedMoments: population.eligibleImportedMoments,
            mediaIntegrityFailureMoments: population.mediaIntegrityFailureMoments,
            normalizedStructureDrift: population.normalizedStructureDrift,
            moments: Array(population.moments.prefix(limit))
        )
    }

    func set(_ population: ScreenHistoryRetirementSamplePopulation) {
        self.population = population
    }
}

private final class RetirementFixture {
    let directory: URL
    let databaseURL: URL
    let ledgerURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-retirement-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("screen-history.sqlite3")
        ledgerURL = directory.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("review.json")
        try FileManager.default.createDirectory(
            at: ledgerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private func samplePopulation(count: Int) -> ScreenHistoryRetirementSamplePopulation {
    let frames = (0..<min(count, 100)).map { sampleFrame(index: $0) }
    return ScreenHistoryRetirementSamplePopulation(
        totalImportedMoments: count,
        eligibleImportedMoments: count,
        moments: frames
    )
}

private func sampleFrame(index: Int, hashSalt: Int = 0) -> ScreenHistoryFrame {
    let sourceIdentifier = String(index + 1)
    let digest = SHA256.hash(data: Data("\(index)-\(hashSalt)".utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    return ScreenHistoryFrame(
        id: Int64(index + 1),
        source: .coast,
        sourceIdentifier: sourceIdentifier,
        capturedAt: Date(timeIntervalSince1970: TimeInterval(index)),
        application: "App \(index % 7)",
        bundleIdentifier: "synthetic.app.\(index % 7)",
        domain: nil,
        windowTitle: "Synthetic \(index)",
        ocrText: "secret OCR \(index)",
        imageLocator: nil,
        mediaLocator: "/definitely-not-opened/\(index).mp4",
        mediaFrameIndex: index,
        byteCount: 100,
        sequenceIdentifier: nil,
        sequenceOrdinal: nil,
        contentHash: digest
    )
}

private func coastInput(id: String, text: String) -> ScreenHistoryFrameInput {
    ScreenHistoryFrameInput(
        source: .coast,
        sourceIdentifier: id,
        capturedAt: Date(timeIntervalSince1970: 1),
        application: "Synthetic",
        bundleIdentifier: "synthetic.bundle",
        ocrText: text
    )
}

private func mediaKind(_ frame: ScreenHistoryFrame) -> String {
    switch (frame.imageLocator != nil, frame.mediaLocator != nil) {
    case (true, true): "both"
    case (true, false): "image"
    case (false, true): "video"
    case (false, false): "none"
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
