import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// The Screenshots catalog is a dated file list: newest capture first,
/// always. Learned favourites must never shuffle it, and the app's own
/// paste buffer must never come back as an attachment.
@Suite("Screenshot ordering and paste buffer", .serialized)
@MainActor
struct ScreenshotOrderingTests {

    private func makeFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-shot-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        for name in files {
            try png.write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    @Test func learnedFavouritesNeverReorderTheScreenshotList() throws {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let today = dayFormatter.string(from: Date())
        let old = "Screenshot \(dayFormatter.string(from: Date(timeIntervalSinceNow: -3 * 86_400))) at 10.00.00.png"
        let mid = "Screenshot \(dayFormatter.string(from: Date(timeIntervalSinceNow: -86_400))) at 10.00.00.png"
        let new = "Screenshot \(today) at 0.00.01.png"
        let folder = try makeFolder(files: [old, mid, new])
        defer { try? FileManager.default.removeItem(at: folder) }

        let vm = QuickViewModel()
        vm.settings.screenshotTextSearch = false
        vm.settings.launcherLearningEnabled = true
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)
        vm.input = ""

        // Use the OLDEST file heavily: with learning on, it must still not
        // outrank the date order on an empty query.
        let oldItem = vm.catalogItems.first { ($0.value as NSString).lastPathComponent == old }!
        for _ in 0..<5 {
            vm.launcherUsage.recordSelection(
                query: "",
                scope: LauncherCatalogScope.screenshots.rawValue,
                itemID: LauncherSearchResult.item(oldItem).id
            )
        }
        let names = vm.catalogMatches.map { ($0.value as NSString).lastPathComponent }
        #expect(names == [new, mid, old], "empty-query screenshots stay newest-first")
    }

    @Test func pinnedScreenshotStillFloatsAboveTheDateOrder() throws {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let old = "Screenshot \(dayFormatter.string(from: Date(timeIntervalSinceNow: -3 * 86_400))) at 10.00.00.png"
        let new = "Screenshot \(dayFormatter.string(from: Date())) at 0.00.01.png"
        let folder = try makeFolder(files: [old, new])
        defer { try? FileManager.default.removeItem(at: folder) }

        let vm = QuickViewModel()
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)
        let oldItem = vm.catalogItems.first { ($0.value as NSString).lastPathComponent == old }!
        vm.togglePinLauncherItem(oldItem)

        let names = vm.catalogMatches.map { ($0.value as NSString).lastPathComponent }
        #expect(names == [old, new], "a deliberate pin floats above the dates")
        let pinnedItem = vm.catalogMatches.first!
        #expect(pinnedItem.isPinned, "the row carries the pin flag so ⌘K offers Unpin")
        let titles = ItemActionCatalog.actions(for: .item(pinnedItem), pasteTarget: nil).map(\.title)
        #expect(titles.contains("Unpin"))
        #expect(!titles.contains("Pin to Top"))

        // The live path: select the pinned row, hit ⌘K. The pane resolves
        // the item by ID, and that resolution must carry the pin flag too.
        vm.applicationSelectionIndex = 0
        vm.handleCommandK()
        #expect(vm.isCatalogActionPanePresented)
        let paneTitles = vm.focusedItemActions.map(\.title)
        #expect(paneTitles.contains("Unpin"), "the ⌘K pane on a pinned row offers Unpin")
        #expect(!paneTitles.contains("Pin to Top"))

        // Unpin from the pane restores the pure date order.
        vm.togglePinLauncherItem(vm.contextualCatalogItem!)
        #expect(vm.focusedItemActions.map(\.title).contains("Pin to Top"))
        vm.closeItemActionPane()
        let unpinnedNames = vm.catalogMatches.map { ($0.value as NSString).lastPathComponent }
        #expect(unpinnedNames == [new, old])
    }

    @Test func selfMadePasteBufferIsNeverOfferedBack() throws {
        let folder = try makeFolder(files: [])
        defer { try? FileManager.default.removeItem(at: folder) }
        // A real decodable image, written through the same path the Paste
        // Image and Copy Image actions use.
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        let url = folder.appendingPathComponent("Screenshot copy.png")
        let tiff = image.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try png.write(to: url)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-launch-order-test-\(UUID().uuidString)"))
        #expect(ScreenshotLibrary.copyImage(at: url, pasteboard: pasteboard))
        #expect(ClipboardImageReader.attachmentIfFresh(from: pasteboard) == nil,
                "the app's own paste buffer must not reappear as an attachment")
        // A copy the user makes afterwards is fresh again.
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        #expect(ClipboardImageReader.attachmentIfFresh(from: pasteboard) != nil)
    }
}
