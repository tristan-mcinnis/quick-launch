import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screen History maintenance command")
struct ScreenHistoryMaintenanceCommandTests {
    @Test func parsesOnlyTheExplicitMaintenanceFlag() {
        #expect(ScreenHistoryMaintenanceCommand.parse(["quick-launch"]) == nil)
        #expect(ScreenHistoryMaintenanceCommand.parse([
            "quick-launch", "--screen-history-prepare-import",
        ]) == .prepareImport)
    }

    @Test func receiptIsContentFreeAndMachineReadable() throws {
        let receipt = ScreenHistoryMaintenanceReceipt(
            schemaVersion: 7,
            completedAt: Date(timeIntervalSince1970: 100),
            freezeManifestSHA256: String(repeating: "a", count: 64),
            freezeFileCount: 3,
            freezeByteCount: 100,
            sourceRows: 10,
            importedRows: 8,
            excludedRows: 2,
            invalidRows: 0,
            policyFingerprint: String(repeating: "b", count: 64),
            sourceFingerprint: String(repeating: "c", count: 64),
            equations: [
                "frame": ScreenHistoryMaintenanceEquation(
                    ScreenHistoryMigrationFamilyEquation(
                        source: 10,
                        imported: 8,
                        excluded: 2,
                        invalid: 0
                    )
                ),
            ],
            ownedRowDelta: 8,
            migrationHashDelta: 8,
            mappingCount: 8,
            migrationLedgerCount: 10,
            mediaSourceRows: 8,
            uniqueMediaLocators: 2,
            copiedFileDelta: 2,
            mediaHashDelta: 2,
            updatedMediaRows: 8,
            mediaFailureCount: 0,
            verificationSampleCount: 8,
            ownedFrameCount: 8,
            normalizedStructureDrift: 0,
            mediaIntegrityFailureMoments: 0
        )
        let data = try JSONEncoder().encode(receipt)
        let json = String(decoding: data, as: UTF8.self)

        #expect(try JSONDecoder().decode(ScreenHistoryMaintenanceReceipt.self, from: data) == receipt)
        for forbidden in ["ocr_text", "window_title", "domain", "path", "query", "media_locator"] {
            #expect(!json.lowercased().contains(forbidden))
        }
    }
}
