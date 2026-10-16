import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// The saved-media browser: multiple folder roots, image and video types, a
/// stable newest-first order, explicit capability checks for a video, and the
/// explicit "save this capture" path that writes a new owner-only file.
@Suite("Screenshot browser", .serialized)
@MainActor
struct ScreenshotBrowserTests {

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ name: String, in folder: URL) throws {
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: folder.appendingPathComponent(name))
    }

    private func makePNG() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: Discovery

    @Test func scansEveryRootOnceNewestFirstAndSkipsUnlistedNames() throws {
        let a = try makeFolder()
        let b = try makeFolder()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        try write("Screenshot 2026-01-02 at 03.04.05.png", in: a)
        try write("Screenshot 2026-01-03 at 03.04.05.mov", in: a)
        try write("holiday.png", in: a)
        try write("Screenshot 2026-01-01 at 03.04.05.png", in: b)

        // The first root is repeated to prove de-duplication.
        let items = ScreenshotLibrary.items(inFolders: [a, b, a])
        #expect(items.count == 3, "two images plus one video; a non-capture name and a repeated folder are dropped")
        #expect(items.map { ($0.value as NSString).lastPathComponent } == [
            "Screenshot 2026-01-03 at 03.04.05.mov",
            "Screenshot 2026-01-02 at 03.04.05.png",
            "Screenshot 2026-01-01 at 03.04.05.png",
        ])
        #expect(items.first?.screenshotMediaKind == .video)
        #expect(items.dropFirst().allSatisfy { $0.screenshotMediaKind == .image })
    }

    @Test func includeAllMediaListsUnprefixedFiles() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("holiday.png", in: folder)
        try write("clip.mp4", in: folder)

        let custom = ScreenshotLibrary.items(inFolders: [folder])
        #expect(custom.isEmpty, "an unprefixed file is not a screenshot by default")

        let all = ScreenshotLibrary.items(inFolders: [folder], includeAllMedia: true)
        #expect(all.count == 2)
        #expect(all.contains { $0.screenshotMediaKind == .video })
        #expect(all.contains { $0.screenshotMediaKind == .image })
    }

    @Test func missingRootIsSkippedNotFatal() throws {
        let real = try makeFolder()
        defer { try? FileManager.default.removeItem(at: real) }
        try write("Screenshot 2026-01-02 at 03.04.05.png", in: real)
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("ql-missing-\(UUID().uuidString)", isDirectory: true)
        #expect(ScreenshotLibrary.items(inFolders: [gone, real]).count == 1)
    }

    @Test func mediaKindIsByExtension() {
        #expect(ScreenshotLibrary.mediaKind(for: URL(fileURLWithPath: "/tmp/a.PNG")) == .image)
        #expect(ScreenshotLibrary.mediaKind(for: URL(fileURLWithPath: "/tmp/a.mov")) == .video)
        #expect(ScreenshotLibrary.mediaKind(for: URL(fileURLWithPath: "/tmp/a.txt")) == nil)
    }

    // MARK: Capability checks

    @Test func videoItemNeverOffersAnImageAction() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("Screenshot 2026-01-02 at 03.04.05.mov", in: folder)
        guard let video = ScreenshotLibrary.items(inFolders: [folder]).first else {
            Issue.record("the video should be listed")
            return
        }
        let titles = ItemActionCatalog.actions(for: .item(video), pasteTarget: nil).map(\.title)
        #expect(titles.contains("Open"))
        #expect(!titles.contains("Paste Image"))
        #expect(!titles.contains("Copy Image"))
        #expect(!titles.contains("Copy Text from Image"), "a video has no image to read text from")
        #expect(!titles.contains("Annotate in Preview"))
    }

    // MARK: Save an app-made capture

    @Test func savingAnAppCaptureWritesANewOwnedFile() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let vm = QuickViewModel()
        vm.screenshotsFolder = folder
        let png = makePNG()
        vm.pendingImage = QuickImageAttachment(data: png, mimeType: "image/png", pixelWidth: 4, pixelHeight: 4)

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        guard let url = await vm.savePendingImageToScreenshots(now: now) else {
            Issue.record("saving should produce a file: \(vm.errorMessage ?? "no message")")
            return
        }
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(url.lastPathComponent.hasPrefix("Screenshot "))
        #expect(try Data(contentsOf: url) == png, "the saved bytes are byte-for-byte the capture")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600, "a saved capture is private data")
        #expect(vm.pendingImage != nil, "saving keeps the in-memory attachment")

        // A second save with the same instant never overwrites the first.
        guard let second = await vm.savePendingImageToScreenshots(now: now) else {
            Issue.record("the second save should produce a distinct file")
            return
        }
        defer { try? FileManager.default.removeItem(at: second) }
        #expect(second != url)
        #expect(try Data(contentsOf: url) == png, "an existing capture is never overwritten")
        #expect(try Data(contentsOf: second) == png)
    }

    @Test func savingIsDiscoverableByTheCatalog() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let vm = QuickViewModel()
        vm.screenshotsFolder = folder
        vm.pendingImage = QuickImageAttachment(data: makePNG(), mimeType: "image/png", pixelWidth: 4, pixelHeight: 4)
        guard let url = await vm.savePendingImageToScreenshots(now: Date(timeIntervalSince1970: 1_700_000_000)) else {
            Issue.record("saving should produce a file")
            return
        }
        let listed = ScreenshotLibrary.items(inFolders: [folder]).map { ($0.value as NSString).lastPathComponent }
        #expect(listed.contains(url.lastPathComponent), "a saved capture joins the browser like any other")
    }

    // MARK: Annotate in Preview

    @Test func annotationWorkingCopyNeverTouchesTheOriginal() async throws {
        let source = try makeFolder()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-annotations-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: out) }
        let file = source.appendingPathComponent("Screenshot 2026-01-02 at 03.04.05.png")
        let bytes = makePNG()
        try bytes.write(to: file)

        let store = ScreenshotAnnotationStore(directory: out)
        guard let copy = await store.newWorkingCopy(of: file) else {
            Issue.record("a working copy should be produced")
            return
        }
        #expect(copy != file)
        #expect(try Data(contentsOf: copy) == bytes, "the copy is byte-identical")
        #expect(try Data(contentsOf: file) == bytes, "the original is never modified")
        let permissions = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600, "an annotation copy is owner-only")
        let directoryPermissions = try FileManager.default
            .attributesOfItem(atPath: out.path)[.posixPermissions] as? Int
        #expect(directoryPermissions == 0o700, "the annotation folder is owner-only")

        // A second copy is a new file. The store never deletes or overwrites
        // the first copy: annotation copies are the user's to edit and keep.
        guard let second = await store.newWorkingCopy(of: file) else {
            Issue.record("a second working copy should be produced")
            return
        }
        #expect(second != copy)
        #expect(FileManager.default.fileExists(atPath: copy.path), "the first copy is not deleted")
        #expect(try Data(contentsOf: copy) == bytes)
    }

    @Test func annotateOnAVideoReportsInsteadOfDoingNothing() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("Screenshot 2026-01-02 at 03.04.05.mov", in: folder)
        guard let video = ScreenshotLibrary.items(inFolders: [folder]).first else {
            Issue.record("the video should be listed")
            return
        }
        let vm = QuickViewModel()
        await vm.annotateInPreview(video)
        #expect(vm.errorMessage?.contains("Videos") == true)
    }

    // MARK: Grid layout

    @Test func screenshotGridUsesColumnsAndMovesByRow() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for day in 1...4 {
            try write(String(format: "Screenshot 2026-01-%02d at 03.04.05.png", day), in: folder)
        }
        let vm = QuickViewModel()
        vm.settings.screenshotTextSearch = false
        vm.settings.screenshotUseGrid = true
        vm.settings.screenshotColumns = 3
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)
        #expect(vm.isGridCatalog)
        #expect(vm.gridColumnCount == 3)
        #expect(vm.launcherMatches.count == 4)
        vm.moveSelectionVertically(1)
        #expect(vm.applicationSelectionIndex == 3, "a vertical move steps one grid row")
        vm.moveSelectionVertically(-1)
        #expect(vm.applicationSelectionIndex == 0)
        // A grid cell keeps the same item identity the list uses, so Return
        // runs the row's primary action.
        guard case .item(let focused) = vm.launcherMatches[vm.applicationSelectionIndex] else {
            Issue.record("the grid selection should be an item")
            return
        }
        #expect(focused.kind == .screenshot)
        #expect(ItemActionCatalog.actions(for: .item(focused), pasteTarget: nil).contains { $0.kind == .primary })

        // Switching back to the list restores the list layout.
        vm.settings.screenshotUseGrid = false
        #expect(!vm.isGridCatalog)
    }

    @Test func saveCaptureCommandExistsAndIsOfferedOnlyWithACapture() throws {
        let vm = QuickViewModel()
        #expect(vm.systemCommands.contains { $0.value == "screenshot.save" }, "Save is a discoverable command")
        #expect(!vm.screenAwarenessActions.contains { $0.commandValue == "screenshot.save" }, "not offered with nothing to save")
        vm.pendingImage = QuickImageAttachment(data: makePNG(), mimeType: "image/png", pixelWidth: 4, pixelHeight: 4)
        #expect(vm.screenAwarenessActions.contains { $0.commandValue == "screenshot.save" }, "offered when a capture waits")
    }

    // MARK: Dispatch and bounded I/O

    @Test func videoActionsDispatchThroughTheWorkspaceNotImagePaths() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("Screenshot 2026-01-02 at 03.04.05.mov", in: folder)
        guard let video = ScreenshotLibrary.items(inFolders: [folder]).first else {
            Issue.record("the video should be listed")
            return
        }
        let url = URL(fileURLWithPath: video.value)
        let workspace = FakeWorkspace()
        let vm = QuickViewModel(workspace: workspace)
        let actions = ItemActionCatalog.actions(for: .item(video), pasteTarget: nil)
        guard let primary = actions.first(where: { $0.kind == .primary }),
              let secondary = actions.first(where: { $0.kind == .secondary }) else {
            Issue.record("a video needs a primary and a secondary action")
            return
        }
        #expect(primary.title == "Open")
        #expect(secondary.title == "Reveal in Finder")

        await vm.perform(primary, on: .item(video))
        #expect(workspace.openedURLs == [url], "the primary action opens the file itself, not an image path")
        #expect(workspace.revealedURLs.isEmpty)

        await vm.perform(secondary, on: .item(video))
        #expect(workspace.revealedURLs == [url], "the secondary action reveals the file itself")
    }

    @Test func readingImageBytesIsCappedAndOffTheMainPath() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let small = folder.appendingPathComponent("small.bin")
        try Data(repeating: 0xAB, count: 16).write(to: small)
        #expect(await QuickViewModel.readCappedFile(atPath: small.path, limit: 32)?.count == 16)

        let big = folder.appendingPathComponent("big.bin")
        try Data(repeating: 0x00, count: 4096).write(to: big)
        #expect(
            await QuickViewModel.readCappedFile(atPath: big.path, limit: 64) == nil,
            "an over-cap file is refused, not loaded whole"
        )
        #expect(await QuickViewModel.readCappedFile(atPath: folder.appendingPathComponent("missing.bin").path) == nil)
    }

    @Test func listingSkipsPlaceholdersZeroByteAndNonFiles() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = folder.appendingPathComponent("Screenshot 2026-01-02 at 03.04.05.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: good)
        let empty = folder.appendingPathComponent("Screenshot 2026-01-03 at 03.04.05.png")
        try Data().write(to: empty)
        let placeholder = folder.appendingPathComponent("Screenshot 2026-01-04 at 03.04.05.png.icloud")
        try Data([0x00]).write(to: placeholder)
        let directory = folder.appendingPathComponent("Screenshot 2026-01-05 at 03.04.05.png", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        #expect(ScreenshotLibrary.isUnavailable(empty), "a zero-byte file is not readable")
        #expect(ScreenshotLibrary.isUnavailable(placeholder), "a cloud placeholder is not downloaded to list it")
        #expect(ScreenshotLibrary.isUnavailable(directory), "a non-regular entry is skipped")
        #expect(!ScreenshotLibrary.isUnavailable(good))

        let names = ScreenshotLibrary.items(inFolders: [folder]).map { ($0.value as NSString).lastPathComponent }
        #expect(names == ["Screenshot 2026-01-02 at 03.04.05.png"], "only the readable file is listed")
    }

    @Test func inMemoryImageDecodeIsBoundedAndRefusesJunk() throws {
        let png = makePNG()
        let capped = ScreenshotTextIndex.downsampledImage(in: png, maximumPixels: 2)
        #expect(capped != nil)
        #expect(max(capped?.width ?? 0, capped?.height ?? 0) <= 2, "an image is decoded to a bounded thumbnail")
        let full = ScreenshotTextIndex.downsampledImage(in: png, maximumPixels: 64)
        #expect(full?.width == 4 && full?.height == 4)
        #expect(ScreenshotTextIndex.downsampledImage(in: Data([0x00, 0x01, 0x02]), maximumPixels: 64) == nil)
    }

    @Test func changingOCRModeReindexesTheScreenshotText() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Screenshot 2026-01-02 at 03.04.05.png")
        try makePNG().write(to: url)
        guard let item = ScreenshotLibrary.items(inFolders: [folder]).first else {
            Issue.record("the screenshot should be listed")
            return
        }
        let storeURL = folder.appendingPathComponent("index.json")
        let index = ScreenshotTextIndex(storeURL: storeURL)
        index.refresh(for: [item], mode: .accurate)
        await index.waitForIndexing()
        index.waitForPendingWrites()
        #expect(try String(contentsOf: storeURL, encoding: .utf8).contains("\"accurate\""), "the pass records the mode it used")

        // A different mode marks the cached text stale so it is re-read: the
        // Text recognition control is not a dead setting.
        index.refresh(for: [item], mode: .fast)
        await index.waitForIndexing()
        index.waitForPendingWrites()
        #expect(try String(contentsOf: storeURL, encoding: .utf8).contains("\"fast\""), "the new mode is recorded")
    }

    // MARK: QR code reading

    @Test func qrCodeIsReadBackFromGeneratedImage() async throws {
        guard let data = Self.qrCodeImage("https://example.com/quick-launch") else {
            Issue.record("could not generate a QR image")
            return
        }
        let code = await ClipboardTextRecognition.codeString(inImage: data)
        #expect(code == "https://example.com/quick-launch")
    }

    private static func qrCodeImage(_ string: String) -> Data? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}
