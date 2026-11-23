import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Pick Color from Screen: the system eyedropper, the pixel as `#RRGGBB` on
/// the clipboard, and a cancelled pick that writes nothing.
@Suite("Pick color", .serialized)
@MainActor
struct ColorPickerTests {

    private struct Rig {
        let vm: QuickViewModel
        let sampler: FakeColorSampler
        let pasteboard: InMemoryPasteboard
        let presenter: RestoreCountingPresenter
    }

    private func make(color: SampledColor?, pasteboard: InMemoryPasteboard) -> Rig {
        let sampler = FakeColorSampler(answer: color)
        let presenter = RestoreCountingPresenter()
        let vm = QuickViewModel(colorSampler: sampler, pasteboard: pasteboard)
        vm.persistSettings = { _ in }
        vm.overlayPresenter = presenter
        return Rig(vm: vm, sampler: sampler, pasteboard: pasteboard, presenter: presenter)
    }

    // MARK: - The value

    @Test func aColorIsSixUpperCaseHexDigits() {
        #expect(SampledColor(red: 0x3A, green: 0x7B, blue: 0xD5).hexString == "#3A7BD5")
        #expect(SampledColor(red: 0, green: 0, blue: 0).hexString == "#000000")
        #expect(SampledColor(red: 255, green: 255, blue: 255).hexString == "#FFFFFF")
        #expect(SampledColor(red: 1, green: 2, blue: 3).hexString == "#010203", "every channel keeps its two digits")
    }

    @Test func componentsConvertToBytesRoundedNotTruncated() throws {
        let color = try #require(SampledColor(color: NSColor(srgbRed: 0.5, green: 0, blue: 1, alpha: 1)))
        #expect(color.red == 128, "half is 128, not 127")
        #expect(color.green == 0)
        #expect(color.blue == 255)
        #expect(color.hexString == "#8000FF")
    }

    @Test func aColorFromAnotherSpaceBecomesSRGB() throws {
        // The sampler answers in the display's own space; white is white in
        // every one of them.
        let white = try #require(SampledColor(color: NSColor(calibratedWhite: 1, alpha: 1)))
        #expect(white.hexString == "#FFFFFF")
        let black = try #require(SampledColor(color: NSColor(calibratedWhite: 0, alpha: 1)))
        #expect(black.hexString == "#000000")
    }

    @Test func aColorWithNoSRGBValuePicksNothing() {
        // A pattern has no sRGB value, so there is no hex to copy.
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
        #expect(SampledColor(color: pattern) == nil)
    }

    // MARK: - The command row

    @Test func theCommandIsDiscoverableAndRunsThePicker() throws {
        let vm = QuickViewModel()
        let row = try #require(vm.systemCommands.first { $0.value == QuickViewModel.pickColorCommandID })
        #expect(row.kind == .command)
        #expect(row.itemID == "color.pick")
        #expect(row.title == "Pick Color from Screen")
        #expect(row.systemImage == "eyedropper")
        #expect(row.keywords.contains("eyedropper"))
        #expect(row.keywords.contains("hex"))

        vm.input = "eyedropper"
        #expect(vm.launcherMatches.contains { $0.id == "command:color.pick" })
        vm.input = "pick color"
        #expect(vm.launcherMatches.contains { $0.id == "command:color.pick" })
    }

    // MARK: - Picking

    @Test func thePickedColorGoesOnlyToTheClipboard() async throws {
        let rig = make(
            color: SampledColor(red: 0x3A, green: 0x7B, blue: 0xD5),
            pasteboard: InMemoryPasteboard()
        )
        let vm = rig.vm
        vm.input = "color"

        await vm.pickColorFromScreen()

        #expect(rig.sampler.calls == 1)
        #expect(rig.pasteboard.readString() == "#3A7BD5")
        #expect(vm.output == "#3A7BD5", "the panel shows the value it copied")
        #expect(vm.lastQuestion == "Picked from the screen")
        #expect(vm.justCopied, "the copy is confirmed in the panel")
        #expect(vm.errorMessage == nil)
        #expect(vm.input.isEmpty)
        #expect(rig.presenter.presentations == 1, "the panel comes back with the value")
    }

    @Test func returnOnTheRowRunsThePicker() async throws {
        let rig = make(
            color: SampledColor(red: 0, green: 0x80, blue: 0x40),
            pasteboard: InMemoryPasteboard()
        )
        let vm = rig.vm
        let row = try #require(vm.systemCommands.first { $0.value == QuickViewModel.pickColorCommandID })

        vm.performSystemCommand(row)
        await vm.colorPickerTask?.value

        #expect(rig.sampler.calls == 1)
        #expect(rig.pasteboard.readString() == "#008040")
    }

    /// Escape in the loupe: no clipboard write, no answer, no error, and the
    /// panel comes back so the user is not stranded outside it.
    @Test func cancellingWritesNothing() async {
        let pasteboard = InMemoryPasteboard()
        pasteboard.writeString("before")
        let rig = make(color: nil, pasteboard: pasteboard)
        let vm = rig.vm

        await vm.pickColorFromScreen()

        #expect(rig.sampler.calls == 1)
        #expect(rig.pasteboard.readString() == "before", "the clipboard is untouched")
        #expect(vm.output.isEmpty)
        #expect(vm.lastQuestion == nil)
        #expect(vm.errorMessage == nil)
        #expect(!vm.justCopied)
        #expect(rig.presenter.presentations == 1, "the panel comes back")
    }

    @Test func aBuildWithoutAPickerExplainsItself() async {
        let pasteboard = InMemoryPasteboard()
        pasteboard.writeString("before")
        let vm = QuickViewModel(pasteboard: pasteboard)
        vm.persistSettings = { _ in }

        await vm.pickColorFromScreen()

        #expect(pasteboard.readString() == "before")
        #expect(vm.errorMessage == "The color picker is not available in this build.")
    }
}

/// The eyedropper, answering at once: a colour, or nil for Escape.
@MainActor
private final class FakeColorSampler: ColorSampling {
    var answer: SampledColor?
    private(set) var calls = 0

    init(answer: SampledColor?) {
        self.answer = answer
    }

    func sampleColor() async -> SampledColor? {
        calls += 1
        return answer
    }
}
