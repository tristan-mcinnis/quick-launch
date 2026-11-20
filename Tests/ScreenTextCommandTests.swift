import Foundation
import Testing
@testable import QuickLaunch

/// Copy Text from Screen Area: the commands exist, and the line-break
/// preference shapes what lands on the clipboard.
@Suite("Text from screen", .serialized)
@MainActor
struct ScreenTextCommandTests {

    @Test func bothScreenTextCommandsAreSearchable() {
        let vm = QuickViewModel()
        let commands = vm.systemCommands
        let copy = commands.first { $0.value == "ocr.area" }
        let paste = commands.first { $0.value == "ocr.areaPaste" }
        #expect(copy != nil)
        #expect(paste != nil)
        #expect(copy?.systemImage == "text.viewfinder")
        #expect(copy?.keywords.contains("ocr") == true)
        #expect(paste?.keywords.contains("paste") == true)
    }

    @Test func keepingLineBreaksLeavesTheLayoutAlone() {
        let recognized = "let a = 1\nlet b = 2"
        #expect(
            QuickViewModel.flattenRecognizedText(recognized, keepLineBreaks: true)
                == "let a = 1\nlet b = 2"
        )
    }

    @Test func droppingLineBreaksJoinsTheLinesIntoAParagraph() {
        let recognized = "The quick brown\nfox jumps over\nthe lazy dog"
        #expect(
            QuickViewModel.flattenRecognizedText(recognized, keepLineBreaks: false)
                == "The quick brown fox jumps over the lazy dog"
        )
    }

    @Test func blankLinesAndEdgeWhitespaceAreTrimmed() {
        let recognized = "  first line \n\n  second line  \n"
        #expect(
            QuickViewModel.flattenRecognizedText(recognized, keepLineBreaks: false)
                == "first line second line"
        )
        #expect(
            QuickViewModel.flattenRecognizedText("  hello  ", keepLineBreaks: true) == "hello"
        )
    }

    @Test func aBuildWithoutScreenCaptureExplainsItself() async {
        let vm = QuickViewModel()
        vm.persistSettings = { _ in }
        await vm.copyTextFromScreenArea()
        #expect(vm.errorMessage != nil)
    }

    /// The text goes to the clipboard only: the panel stays closed and
    /// nothing is shown or sent on.
    @Test func copiedScreenTextGoesOnlyToTheClipboard() async {
        let pasteboard = InMemoryPasteboard()
        let presenter = RestoreCountingPresenter()
        let vm = QuickViewModel(screenAwareness: OneArea(), pasteboard: pasteboard)
        vm.persistSettings = { _ in }
        vm.overlayPresenter = presenter
        vm.recognizeImageText = { _ in "Invoice 2041\nDue 30 Nov" }
        await vm.copyTextFromScreenArea()
        #expect(pasteboard.readString() == "Invoice 2041\nDue 30 Nov")
        #expect(presenter.presentations == 0)
        #expect(presenter.dismissals == 1)
        #expect(vm.output.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    /// Escape in the selector leaves the clipboard alone and opens nothing.
    @Test func cancellingTheSelectorShowsNothing() async {
        let pasteboard = InMemoryPasteboard()
        pasteboard.writeString("before")
        let presenter = RestoreCountingPresenter()
        let area = OneArea()
        area.image = nil
        let vm = QuickViewModel(screenAwareness: area, pasteboard: pasteboard)
        vm.persistSettings = { _ in }
        vm.overlayPresenter = presenter
        await vm.copyTextFromScreenArea()
        #expect(pasteboard.readString() == "before")
        #expect(presenter.presentations == 0)
        #expect(presenter.restores == 0)
    }
}

@MainActor
private final class OneArea: ScreenAwarenessReading {
    var image: QuickImageAttachment? = QuickImageAttachment(
        data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png", pixelWidth: 2, pixelHeight: 2
    )
    func readContext(for target: SelectionTarget) -> CaptureContext {
        CaptureContext(appName: target.applicationName)
    }
    func captureArea() async -> QuickImageAttachment? { image }
}
