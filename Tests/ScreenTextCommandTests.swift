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
}
