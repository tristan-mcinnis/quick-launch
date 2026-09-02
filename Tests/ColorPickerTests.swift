import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// The screen eyedropper: conversions, the local history, and the launcher
/// command that ties them together.
@Suite("Color picker", .serialized)
@MainActor
struct ColorPickerTests {

    // MARK: - Conversions

    @Test func hexIsUppercaseWithHash() {
        let color = PickedColor(red: 74 / 255, green: 144 / 255, blue: 217 / 255)
        #expect(color.hexString == "#4A90D9")
    }

    @Test func rgbUsesRoundedBytes() {
        let color = PickedColor(red: 74 / 255, green: 144 / 255, blue: 217 / 255)
        #expect(color.rgbString == "rgb(74, 144, 217)")
    }

    @Test func hslMatchesTheKnownValueForSteelBlue() {
        let color = PickedColor(red: 74 / 255, green: 144 / 255, blue: 217 / 255)
        let (hue, saturation, lightness) = color.hsl
        #expect(Int(hue.rounded()) == 211)
        #expect(abs(saturation - 0.653) < 0.01)
        #expect(abs(lightness - 0.571) < 0.01)
        #expect(color.hslString == "hsl(211, 65%, 57%)")
    }

    @Test func hsbMatchesTheKnownValueForSteelBlue() {
        let color = PickedColor(red: 74 / 255, green: 144 / 255, blue: 217 / 255)
        #expect(color.hsbString == "hsb(211, 66%, 85%)")
    }

    @Test func greysHaveNoHueOrSaturation() {
        let grey = PickedColor(red: 0.5, green: 0.5, blue: 0.5)
        #expect(grey.hsl.hue == 0)
        #expect(grey.hsl.saturation == 0)
        #expect(grey.hsb.saturation == 0)
        #expect(grey.hslString == "hsl(0, 0%, 50%)")
    }

    @Test func primaryHuesLandOnTheirDegrees() {
        #expect(Int(PickedColor(red: 1, green: 0, blue: 0).hsl.hue.rounded()) == 0)
        #expect(Int(PickedColor(red: 0, green: 1, blue: 0).hsl.hue.rounded()) == 120)
        #expect(Int(PickedColor(red: 0, green: 0, blue: 1).hsl.hue.rounded()) == 240)
        #expect(Int(PickedColor(red: 1, green: 1, blue: 0).hsl.hue.rounded()) == 60)
        #expect(Int(PickedColor(red: 0, green: 1, blue: 1).hsl.hue.rounded()) == 180)
        #expect(Int(PickedColor(red: 1, green: 0, blue: 1).hsl.hue.rounded()) == 300)
    }

    @Test func alphaSwitchesToTheFourArgumentNotations() {
        let color = PickedColor(red: 1, green: 0, blue: 0, alpha: 0.5)
        #expect(color.hexString == "#FF000080")
        #expect(color.rgbString == "rgba(255, 0, 0, 0.5)")
        #expect(color.hslString.hasPrefix("hsla("))
        #expect(color.hsbString.hasPrefix("hsba("))
    }

    @Test func hexStringsRoundTrip() throws {
        let color = try #require(PickedColor(hexString: "#4A90D9"))
        #expect(color.red255 == 74)
        #expect(color.green255 == 144)
        #expect(color.blue255 == 217)
        #expect(color.hexString == "#4A90D9")
    }

    @Test func shortAndBareAndAlphaHexAllParse() throws {
        #expect(try #require(PickedColor(hexString: "#fff")).hexString == "#FFFFFF")
        #expect(try #require(PickedColor(hexString: "4a90d9")).hexString == "#4A90D9")
        let translucent = try #require(PickedColor(hexString: "FF000080"))
        #expect(abs(translucent.alpha - 0.502) < 0.01)
    }

    @Test func nonHexTextIsRejected() {
        #expect(PickedColor(hexString: "not a color") == nil)
        #expect(PickedColor(hexString: "#12345") == nil)
        #expect(PickedColor(hexString: "") == nil)
    }

    @Test func componentsAreClampedToTheValidRange() {
        let color = PickedColor(red: 2, green: -1, blue: 0.5, alpha: 9)
        #expect(color.red == 1)
        #expect(color.green == 0)
        #expect(color.alpha == 1)
    }

    @Test func namesFollowTheNearestCommonColor() {
        #expect(PickedColor(red: 1, green: 0, blue: 0).name == "Red")
        #expect(PickedColor(red: 0, green: 0, blue: 0).name == "Black")
        #expect(PickedColor(red: 1, green: 1, blue: 1).name == "White")
        #expect(PickedColor(red: 74 / 255, green: 144 / 255, blue: 217 / 255).name == "Steel Blue")
    }

    @Test func storageIDIsStableAndLowercase() {
        let color = PickedColor(red: 74 / 255, green: 144 / 255, blue: 217 / 255)
        #expect(color.storageID == "4a90d9ff")
        #expect(PickedColor(hexString: color.storageID) == color)
    }

    @Test func sRGBConversionKeepsTheComponents() throws {
        let converted = try #require(PickedColor(nsColor: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)))
        #expect(abs(converted.red - 0.2) < 0.001)
        #expect(abs(converted.green - 0.4) < 0.001)
        #expect(abs(converted.blue - 0.6) < 0.001)
    }

    // MARK: - History store

    private func makeStore() -> (ColorHistoryStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-colors-\(UUID().uuidString)")
            .appendingPathComponent("color-history.json")
        return (ColorHistoryStore(fileURL: url), url)
    }

    @Test func recordingAColorMakesASearchableRow() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let item = store.record(PickedColor(red: 1, green: 0, blue: 0), limit: 10)
        #expect(store.entries.count == 1)
        #expect(item.kind == .color)
        #expect(item.value == "#FF0000")
        #expect(item.detail.contains("Red"))
        // Every notation is searchable from the row.
        #expect(item.keywords.contains("rgb(255, 0, 0)"))
        #expect(item.keywords.contains("Red"))
    }

    @Test func pickingTheSameColorTwiceKeepsOneRow() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        store.record(PickedColor(red: 1, green: 0, blue: 0), limit: 10)
        store.record(PickedColor(red: 0, green: 0, blue: 1), limit: 10)
        store.record(PickedColor(red: 1, green: 0, blue: 0), limit: 10)
        #expect(store.entries.count == 2)
        #expect(store.entries[0].value == "#FF0000", "the newest pick leads the list")
    }

    @Test func theFormatRewritesEveryStoredRow() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        store.record(PickedColor(red: 1, green: 0, blue: 0), limit: 10)
        store.preferredFormat = .rgb
        #expect(store.entries[0].value == "rgb(255, 0, 0)")
        #expect(store.entries[0].title == "rgb(255, 0, 0)")
        store.preferredFormat = .hsl
        #expect(store.entries[0].value == "hsl(0, 100%, 50%)")
    }

    @Test func theLimitPrunesUnpinnedColorsOnly() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = store.record(PickedColor(red: 1, green: 0, blue: 0), limit: 2)
        store.togglePin(first)
        store.record(PickedColor(red: 0, green: 1, blue: 0), limit: 2)
        store.record(PickedColor(red: 0, green: 0, blue: 1), limit: 2)
        store.record(PickedColor(red: 1, green: 1, blue: 0), limit: 2)

        #expect(store.entries.count == 3, "the pin survives beyond the limit")
        #expect(store.entries[0].value == "#FF0000")
        #expect(store.entries[0].isPinned)
        #expect(!store.entries.contains { $0.value == "#00FF00" }, "the oldest unpinned color is dropped")
    }

    @Test func removeAndClearEmptyTheList() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let item = store.record(PickedColor(red: 1, green: 0, blue: 0), limit: 10)
        store.record(PickedColor(red: 0, green: 1, blue: 0), limit: 10)
        store.remove(item)
        #expect(store.entries.count == 1)
        store.clear()
        #expect(store.entries.isEmpty)
    }

    @Test func historySurvivesAReopen() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        store.record(PickedColor(red: 0.1, green: 0.2, blue: 0.3), limit: 10)
        store.waitForPendingWrites()

        let reopened = ColorHistoryStore(fileURL: url)
        #expect(reopened.entries.count == 1)
        #expect(reopened.color(for: reopened.entries[0])?.hexString == store.entries[0].value)
    }

    @Test func theHistoryFileStaysOwnerOnly() throws {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        store.record(PickedColor(red: 0, green: 0, blue: 0), limit: 10)
        store.waitForPendingWrites()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    // MARK: - The launcher command

    private final class StubColorSampler: ScreenColorSampling {
        var next: PickedColor?
        private(set) var sampleCount = 0

        init(next: PickedColor?) { self.next = next }

        func sample() async -> PickedColor? {
            sampleCount += 1
            return next
        }
    }

    private func makeViewModel(
        sampler: StubColorSampler,
        store: ColorHistoryStore
    ) -> QuickViewModel {
        let vm = QuickViewModel(colorHistory: store, colorSampler: sampler, pasteboard: FakePasteboard())
        vm.persistSettings = { _ in }
        return vm
    }

    @Test func pickingCopiesTheColorAndStoresIt() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sampler = StubColorSampler(next: PickedColor(red: 1, green: 0, blue: 0))
        let vm = makeViewModel(sampler: sampler, store: store)

        await vm.pickColorFromScreen()

        #expect(sampler.sampleCount == 1)
        #expect((vm.pasteboard as? FakePasteboard)?.string == "#FF0000")
        #expect(vm.colorItems.count == 1)
        #expect(vm.errorMessage == nil)
        // Picking is finished when the colour is on the clipboard: no answer
        // pane, nothing to read, nothing to dismiss by hand.
        #expect(vm.output.isEmpty)
        #expect(vm.lastQuestion == nil)
    }

    @Test func pickingClosesTheOverlayInsteadOfShowingAnAnswer() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sampler = StubColorSampler(next: PickedColor(red: 0, green: 1, blue: 0))
        let vm = makeViewModel(sampler: sampler, store: store)

        var dismissals = 0
        var presentations = 0
        let dismissToken = NotificationCenter.default.addObserver(
            forName: .dismissOverlay, object: nil, queue: .main
        ) { _ in dismissals += 1 }
        let presentToken = NotificationCenter.default.addObserver(
            forName: .presentOverlay, object: nil, queue: .main
        ) { _ in presentations += 1 }
        defer {
            NotificationCenter.default.removeObserver(dismissToken)
            NotificationCenter.default.removeObserver(presentToken)
        }

        await vm.pickColorFromScreen()

        #expect(dismissals == 1, "the panel closes as soon as the colour is copied")
        #expect(presentations == 0, "the panel never comes back to show the value")
    }

    @Test func theStoredNotationFollowsTheSetting() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sampler = StubColorSampler(next: PickedColor(red: 0, green: 0, blue: 1))
        let vm = makeViewModel(sampler: sampler, store: store)
        vm.settings.colorFormat = .rgb

        await vm.pickColorFromScreen()

        #expect((vm.pasteboard as? FakePasteboard)?.string == "rgb(0, 0, 255)")
        #expect(vm.colorItems[0].value == "rgb(0, 0, 255)")
    }

    @Test func changingTheFormatRewritesTheCatalog() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sampler = StubColorSampler(next: PickedColor(red: 0, green: 0, blue: 1))
        let vm = makeViewModel(sampler: sampler, store: store)

        await vm.pickColorFromScreen()
        #expect(vm.colorItems[0].value == "#0000FF")
        vm.applyColorFormat(.hsl)
        #expect(vm.colorItems[0].value == "hsl(240, 100%, 50%)")
        #expect(vm.settings.colorFormat == .hsl)
    }

    @Test func cancellingTheLoupeChangesNothing() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sampler = StubColorSampler(next: nil)
        let vm = makeViewModel(sampler: sampler, store: store)
        vm.output = ""

        await vm.pickColorFromScreen()

        #expect(vm.colorItems.isEmpty)
        #expect(vm.output.isEmpty)
        #expect(vm.errorMessage == nil, "Escape is not an error")
    }

    @Test func aBuildWithoutASamplerExplainsItself() async {
        let vm = QuickViewModel()
        await vm.pickColorFromScreen()
        #expect(vm.errorMessage != nil)
    }

    @Test func theCommandsAreSearchableFromTheRoot() {
        let vm = QuickViewModel()
        let commands = vm.systemCommands
        #expect(commands.contains { $0.value == "color.pick" })
        #expect(commands.contains { $0.value == "color.pickPaste" })
        let pick = commands.first { $0.value == "color.pick" }
        #expect(pick?.systemImage == "eyedropper")
        #expect(pick?.keywords.contains("eyedropper") == true)
    }

    @Test func theColorsCatalogListsThePicks() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sampler = StubColorSampler(next: PickedColor(red: 1, green: 0, blue: 0))
        let vm = makeViewModel(sampler: sampler, store: store)
        await vm.pickColorFromScreen()

        vm.enterCatalog(.colors)
        #expect(vm.catalogCount(.colors) == 1)
        #expect(vm.catalogItems.count == 1)
        #expect(vm.detailItem?.kind == .color, "the swatch pane opens beside the list")
        #expect(vm.color(for: vm.catalogItems[0])?.hexString == "#FF0000")
    }

    @Test func theColorsRootStaysVisibleBesideLearnedFavourites() {
        let vm = QuickViewModel()
        vm.persistSettings = { _ in }
        vm.input = ""
        let roots = vm.launcherMatches.compactMap { result -> LauncherCatalogScope? in
            guard case .catalog(let scope, _) = result else { return nil }
            return scope
        }
        #expect(roots.contains(.colors), "the root list must not truncate a catalog away")
        #expect(roots.count == LauncherCatalogScope.allCases.count)
    }

    @Test func aColorRowOffersEveryNotation() {
        let color = PickedColor(red: 1, green: 0, blue: 0)
        let item = LauncherCatalogItem(
            kind: .color,
            itemID: color.storageID,
            title: color.hexString,
            detail: "Red",
            value: color.hexString
        )
        let actions = ItemActionCatalog.actions(for: .item(item), pasteTarget: "Notes")
        let copyAs = actions.filter { $0.kind == .copyAs }
        #expect(copyAs.count == ColorFormat.allCases.count)
        #expect(copyAs.contains { $0.commandValue == ColorFormat.rgb.rawValue })
        #expect(copyAs[0].shortcut == .command("1"))
        #expect(actions.contains { $0.kind == .delete })
        #expect(actions.contains { $0.kind == .pin })
        #expect(actions.first?.title == "Paste to Notes")
    }

    @Test func copyAsPutsTheChosenNotationOnTheClipboard() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let vm = makeViewModel(sampler: StubColorSampler(next: nil), store: store)
        let item = store.record(PickedColor(red: 1, green: 0, blue: 0), limit: 10)

        let action = ItemAction(
            kind: .copyAs,
            title: "Copy RGB",
            systemImage: "number",
            shortcut: nil,
            commandValue: ColorFormat.rgb.rawValue
        )
        await vm.perform(action, on: .item(item))
        #expect((vm.pasteboard as? FakePasteboard)?.string == "rgb(255, 0, 0)")
    }

    @Test func pinningAndDeletingAColorGoesThroughTheStore() async {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let vm = makeViewModel(sampler: StubColorSampler(next: nil), store: store)
        let item = store.record(PickedColor(red: 1, green: 0, blue: 0), limit: 10)

        let pin = ItemAction(kind: .pin, title: "Pin", systemImage: "pin", shortcut: nil)
        await vm.perform(pin, on: .item(item))
        #expect(vm.colorItems[0].isPinned)

        let delete = ItemAction(kind: .delete, title: "Delete", systemImage: "trash", shortcut: nil)
        // The first press arms the row, the second one deletes it.
        await vm.perform(delete, on: .item(vm.colorItems[0]))
        #expect(vm.colorItems.count == 1)
        await vm.perform(delete, on: .item(vm.colorItems[0]))
        #expect(vm.colorItems.isEmpty)
    }
}
