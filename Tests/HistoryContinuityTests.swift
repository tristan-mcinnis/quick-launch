import AppKit
import Observation
import Synchronization
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("History continuity", .serialized)
@MainActor
struct HistoryContinuityTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-continuity-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func clipboardUpdatesVisibleResultsWhenTheHistoryIsFull() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(fileURL: directory.appendingPathComponent("clipboard-history.json"))
        store.record("first copy", limit: 1)
        let vm = QuickViewModel(clipboardHistory: store)
        vm.enterCatalog(.clipboard)
        #expect(vm.detailItem?.value == "first copy")
        let changed = Mutex(false)
        withObservationTracking {
            _ = vm.launcherMatches
        } onChange: {
            changed.withLock { $0 = true }
        }
        store.record("second copy", limit: 1)
        #expect(changed.withLock { $0 }, "the visible catalog must redraw for a fresh copy")
        #expect(vm.detailItem?.value == "second copy", "same-count captures must invalidate ranking")
    }

    @Test func delayedPasteboardDataIsRetriedWithoutANewOwnershipChange() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(fileURL: directory.appendingPathComponent("clipboard-history.json"))
        let board = NSPasteboard(name: .init("history-delayed-\(UUID())"))
        board.declareTypes([.string], owner: nil)
        let version = board.changeCount
        store.capture(from: board, limit: 10)
        #expect(store.entries.isEmpty)
        board.setString("arrived from another device", forType: .string)
        #expect(board.changeCount == version)
        store.capture(from: board, limit: 10)
        #expect(store.entries.first?.value == "arrived from another device")
    }

    @Test func remoteClipboardMarkerDoesNotBecomeAHistoryItem() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(fileURL: directory.appendingPathComponent("clipboard-history.json"))
        let board = NSPasteboard(name: .init("history-remote-\(UUID())"))
        let remote = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
        board.declareTypes([remote, .string], owner: nil)
        board.setString("1", forType: remote)
        store.capture(from: board, limit: 10)
        #expect(store.entries.isEmpty, "handoff metadata alone is not a copied payload")
        board.setString("remote sentence", forType: .string)
        store.capture(from: board, limit: 10)
        #expect(store.entries.first?.value == "remote sentence")
        #expect(store.entries.first?.clipboardPayload?.kind == .text)
        #expect(store.entries.first?.clipboardPayload?.blobKey == nil)
    }

    @Test func aNewClipboardImageDoesNotReplaceRetainedHistoryWithAnAttachment() throws {
        let board = NSPasteboard(name: .init("history-image-\(UUID())"))
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        board.declareTypes([.png], owner: nil)
        board.setData(png, forType: .png)
        let vm = QuickViewModel()
        vm.enterCatalog(.clipboard)
        vm.captureImageFromClipboard(from: board)
        #expect(vm.catalogScope == .clipboard)
        #expect(vm.pendingImage == nil)
        vm.leaveCatalog()
        vm.captureImageFromClipboard(from: board)
        #expect(vm.pendingImage != nil, "the fresh copy is still available when returning to the AI input")
    }

    @Test func retainedScreenshotCatalogRefreshesForRapidCaptures() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1]).write(to: directory.appendingPathComponent("Screenshot 2026-09-15 at 10.00.00.png"))
        let vm = QuickViewModel()
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = directory
        vm.enterCatalog(.screenshots)
        #expect(vm.screenshotFiles.count == 1)
        try Data([2]).write(to: directory.appendingPathComponent("Screenshot 2026-09-15 at 10.00.01.png"))
        vm.warmScreenshotCatalogIfStale()
        await vm.waitForScreenshotScanForTesting()
        #expect(vm.screenshotFiles.count == 2, "reopening retained screenshots must see a capture from the last two seconds")
        vm.leaveCatalog()
        try Data([3]).write(to: directory.appendingPathComponent("Screenshot 2026-09-15 at 10.00.02.png"))
        vm.enterCatalog(.screenshots)
        await vm.waitForScreenshotScanForTesting()
        #expect(vm.screenshotFiles.count == 3, "Back then Return also refreshes a warm catalog")
    }

    @Test func refreshingScreenshotsKeepsTheOlderItemBeingBrowsedSelected() async throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        func addCapture(_ minute: String) throws {
            try Data([1]).write(to: directory.appendingPathComponent("Screenshot 2026-09-15 at 10.\(minute).00.png"))
        }
        for minute in ["00", "01", "02"] { try addCapture(minute) }
        let vm = QuickViewModel()
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = directory
        vm.enterCatalog(.screenshots)
        vm.applicationSelectionIndex = 1
        let selectedID = try #require(vm.detailItem?.id)
        try addCapture("03")
        vm.refreshScreenshotFilesInBackground()
        await vm.waitForScreenshotScanForTesting()
        #expect(vm.detailItem?.id == selectedID, "a late capture must not change the older screenshot being previewed")
        #expect(vm.applicationSelectionIndex == 2)

        vm.applicationSelectionIndex = 0
        try addCapture("04")
        vm.refreshScreenshotFilesInBackground()
        await vm.waitForScreenshotScanForTesting()
        #expect(vm.applicationSelectionIndex == 0)
        #expect(vm.detailItem?.value.hasSuffix("10.04.00.png") == true, "the newest row follows fresh captures")
    }

    @Test func historyDoesNotReturnToRootWhileReading() async throws {
        let vm = QuickViewModel()
        vm.catalogIdleResetDelay = .milliseconds(10)
        vm.enterCatalog(.clipboard)
        try await Task.sleep(for: .milliseconds(80))
        #expect(vm.catalogScope == .clipboard, "history stays open until the user leaves it")
    }

    @Test func leavingHistoryHighlightsItsRootRowForReturn() {
        let vm = QuickViewModel()
        vm.enterCatalog(.clipboard)
        vm.leaveCatalog()
        guard case .catalog(let scope, _) = vm.focusedLauncherResult else {
            Issue.record("Back should select the history catalog at root")
            return
        }
        #expect(scope == .clipboard)
    }

    @Test func historyPanelKeepsItsSizeWhenFilteringToNoResults() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(fileURL: directory.appendingPathComponent("clipboard-history.json"))
        store.record("a copied sentence", limit: 10)
        let vm = QuickViewModel(clipboardHistory: store)
        vm.enterCatalog(.clipboard)
        let height = vm.estimatedWindowHeight
        #expect(vm.currentPanelWidth == House.Layout.panelWidth)
        vm.input = "nothing-will-match-9a71"
        #expect(vm.launcherMatches.isEmpty)
        #expect(vm.currentPanelWidth == House.Layout.panelWidth)
        #expect(vm.estimatedWindowHeight == height)
    }
    @Test func rendersHistoryAtTheMeasuredSizeInBothAppearances() throws {
        let directory = try folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipboardHistoryStore(fileURL: directory.appendingPathComponent("clipboard-history.json"))
        store.record("The next screenshot and clipboard copy appear in this list.", limit: 10)
        let vm = QuickViewModel(clipboardHistory: store)
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = directory
        let output = URL(fileURLWithPath: "/tmp/quick-launch-history-proof")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (appearance, name) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            for (scope, query, state) in [(LauncherCatalogScope.clipboard, "", "clipboard"),
                                           (.clipboard, "nothing-will-match-9a71", "no-matches"),
                                           (.screenshots, "", "screenshots-empty")] {
                vm.settings.appearance = name == "dark" ? .dark : .light
                vm.enterCatalog(scope)
                vm.input = query
                let size = NSSize(width: vm.currentPanelWidth, height: vm.estimatedWindowHeight)
                let host = NSHostingView(rootView: OverlayView(viewModel: vm))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height <= size.height + 1, "history must fit its measured window")
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("\(state)-\(name).png"))
            }
        }
    }

}
