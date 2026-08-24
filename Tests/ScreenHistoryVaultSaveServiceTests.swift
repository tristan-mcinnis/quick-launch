import Foundation
import Testing
@testable import QuickLaunch

@Suite("Screen History Save to Vault")
struct ScreenHistoryVaultSaveServiceTests {
    @Test func explicitSaveRunsTheLocalHelperAndReturnsTheVerifiedTriagePath() async throws {
        let fixture = try SaveFixture(script: Self.successHelper)
        let service = ScreenHistoryVaultSaveService(
            helperURL: fixture.helperURL,
            vaultRootURL: fixture.vaultURL,
            requestTimeout: .seconds(2)
        )
        let frame = syntheticFrame(ocrText: String(repeating: "x", count: 4_200))

        let created = try await service.save(frame, note: "Synthetic note", projectSlug: nil)

        #expect(created.path == fixture.triageURL.appendingPathComponent("saved.md").path)
        #expect(FileManager.default.fileExists(atPath: created.path))
        let requestData = try Data(contentsOf: fixture.vaultURL.appendingPathComponent("request.json"))
        let request = try #require(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        #expect(request["local_record_id"] as? String == "synthetic-42")
        #expect(request["source"] as? String == "owned")
        #expect((request["ocr_excerpt"] as? String)?.count == 4_000)
        #expect(request["image_locator"] == nil)
        #expect(request["media_locator"] == nil)
    }

    @Test func constructingTheServiceDoesNotCreateOrSaveAnything() throws {
        let fixture = try SaveFixture(script: Self.successHelper)

        _ = ScreenHistoryVaultSaveService(
            helperURL: fixture.helperURL,
            vaultRootURL: fixture.vaultURL
        )

        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.triageURL.path).isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: fixture.vaultURL.appendingPathComponent("request.json").path
        ))
    }

    @Test func previewMatchesEveryBoundedPayloadFieldAndRefusesInvalidIDs() throws {
        let frame = ScreenHistoryFrame(
            id: 77,
            source: .coast,
            sourceIdentifier: "coast-77",
            capturedAt: Date(timeIntervalSince1970: 1_787_600_123.456),
            application: String(repeating: "A", count: 240),
            bundleIdentifier: "test.synthetic.editor",
            domain: nil,
            windowTitle: String(repeating: "W", count: 540),
            ocrText: "",
            imageLocator: nil,
            mediaLocator: nil,
            mediaFrameIndex: nil,
            byteCount: 0,
            sequenceIdentifier: nil,
            sequenceOrdinal: nil,
            contentHash: "hash"
        )
        let preview = ScreenHistorySavePreview(frame: frame)
        let payload = try ScreenHistoryVaultSaveService.payload(
            frame: frame,
            note: nil,
            projectSlug: nil
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        #expect(preview.validationError == nil)
        #expect(preview.source.lowercased() == object["source"] as? String)
        #expect(preview.localRecordID == object["local_record_id"] as? String)
        #expect(preview.seenAt == object["seen_at"] as? String)
        #expect(preview.application == object["application"] as? String)
        #expect(preview.window == object["window_title"] as? String)
        #expect(preview.ocrExcerpt == object["ocr_excerpt"] as? String)

        let invalid = ScreenHistoryFrame(
            id: 78,
            source: .owned,
            sourceIdentifier: String(repeating: "x", count: 161),
            capturedAt: frame.capturedAt,
            application: nil,
            bundleIdentifier: "test.synthetic.editor",
            domain: nil,
            windowTitle: nil,
            ocrText: "",
            imageLocator: nil,
            mediaLocator: nil,
            mediaFrameIndex: nil,
            byteCount: 0,
            sequenceIdentifier: nil,
            sequenceOrdinal: nil,
            contentHash: "hash"
        )
        #expect(ScreenHistorySavePreview(frame: invalid).validationError != nil)
        #expect(throws: ScreenHistoryVaultSaveError.self) {
            _ = try ScreenHistoryVaultSaveService.payload(
                frame: invalid,
                note: nil,
                projectSlug: nil
            )
        }
    }

    @Test func helperResultCannotEscapeTheTriageDirectory() async throws {
        let fixture = try SaveFixture(script: """
        import json, sys
        json.load(sys.stdin)
        print(json.dumps({"ok": True, "path": "../../outside.md"}))
        """)
        let service = ScreenHistoryVaultSaveService(
            helperURL: fixture.helperURL,
            vaultRootURL: fixture.vaultURL
        )

        await #expect(throws: ScreenHistoryVaultSaveError.unsafePath) {
            try await service.save(syntheticFrame(), note: nil, projectSlug: nil)
        }
    }

    @Test func helperValidationFailureIsReportedWithoutSaving() async throws {
        let fixture = try SaveFixture(script: """
        import json, sys
        json.load(sys.stdin)
        print(json.dumps({"ok": False, "error": "synthetic validation failure"}))
        raise SystemExit(2)
        """)
        let service = ScreenHistoryVaultSaveService(
            helperURL: fixture.helperURL,
            vaultRootURL: fixture.vaultURL
        )

        await #expect(throws: ScreenHistoryVaultSaveError.failed("synthetic validation failure")) {
            try await service.save(syntheticFrame(), note: nil, projectSlug: nil)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.triageURL.path).isEmpty)
    }

    @Test func hungHelperHitsTheHardTimeout() async throws {
        let fixture = try SaveFixture(script: """
        import json, sys, time
        json.load(sys.stdin)
        time.sleep(2)
        """)
        let service = ScreenHistoryVaultSaveService(
            helperURL: fixture.helperURL,
            vaultRootURL: fixture.vaultURL,
            requestTimeout: .milliseconds(50)
        )

        await #expect(throws: ScreenHistoryVaultSaveError.timedOut) {
            try await service.save(syntheticFrame(), note: nil, projectSlug: nil)
        }
    }

    private static let successHelper = """
    import json, os, pathlib, sys
    request = json.load(sys.stdin)
    root = pathlib.Path(os.environ["CLAUDE_PROJECT_DIR"])
    (root / "request.json").write_text(json.dumps(request), encoding="utf-8")
    target = root / "kb" / "triage" / "saved.md"
    target.write_text("synthetic", encoding="utf-8")
    print(json.dumps({"ok": True, "path": "kb/triage/saved.md"}))
    """
}

private func syntheticFrame(ocrText: String = "Synthetic visible text") -> ScreenHistoryFrame {
    ScreenHistoryFrame(
        id: 42,
        source: .owned,
        sourceIdentifier: "synthetic-42",
        capturedAt: Date(timeIntervalSince1970: 1_787_600_000),
        application: "Synthetic Editor",
        bundleIdentifier: "test.synthetic.editor",
        domain: "example.test",
        windowTitle: "Synthetic planning window",
        ocrText: ocrText,
        imageLocator: "/synthetic/never-export.jpg",
        mediaLocator: "/synthetic/never-export.mp4",
        mediaFrameIndex: 2,
        byteCount: 100,
        sequenceIdentifier: "synthetic-sequence",
        sequenceOrdinal: 1,
        contentHash: "synthetic-hash"
    )
}

private final class SaveFixture {
    let vaultURL: URL
    let triageURL: URL
    let helperURL: URL

    init(script: String) throws {
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-vault-save-\(UUID().uuidString)")
        triageURL = vaultURL.appendingPathComponent("kb/triage")
        helperURL = vaultURL.appendingPathComponent("fake-save.py")
        try FileManager.default.createDirectory(at: triageURL, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: helperURL, options: .atomic)
    }

    deinit { try? FileManager.default.removeItem(at: vaultURL) }
}
