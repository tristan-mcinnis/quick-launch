// CodeBlockChromeTests — the assistant answer's code blocks.
//
// Covers the pieces the answer stack depends on: where MarkdownRenderer
// splits the answer, what the fence's info string says the language is, what
// Copy writes, that wrap starts off, and that the drawn stack and the
// measured answer height agree.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Code block chrome", .serialized)
@MainActor
struct CodeBlockChromeTests {

    // MARK: - Language detection

    @Test func fenceLanguageIsReadFromTheInfoString() {
        let segments = MarkdownRenderer.segments("```swift\nlet x = 1\n```")
        #expect(segments.count == 1)
        guard case .code(let block) = segments.first?.content else {
            Issue.record("a fenced block must be its own segment, got \(segments)")
            return
        }
        #expect(block.language == "swift")
    }

    @Test func fenceInfoStringTakesOnlyItsFirstWord() {
        let segments = MarkdownRenderer.segments("```python title=chart.py\nprint(1)\n```")
        guard case .code(let block) = segments.first?.content else {
            Issue.record("expected one code segment")
            return
        }
        #expect(block.language == "python")
    }

    @Test func fenceWithoutAnInfoStringHasNoLanguage() {
        let segments = MarkdownRenderer.segments("```\nplain text\n```")
        guard case .code(let block) = segments.first?.content else {
            Issue.record("expected one code segment")
            return
        }
        #expect(block.language == nil, "a fence with no info string must draw unlabelled")
    }

    @Test func blankInfoStringHasNoLanguage() {
        let content = CodeBlockContent(infoString: "   ", code: "plain")
        #expect(content.language == nil)
    }

    @Test func missingInfoStringHasNoLanguage() {
        #expect(CodeBlockContent(infoString: nil, code: "plain").language == nil)
    }

    // MARK: - The copy payload

    @Test func copyPayloadIsTheCodeWithoutFences() {
        let markdown = """
        Here is the code:

        ```swift
        let x = 42
        ```

        Done.
        """
        let code = codeBlock(in: markdown)
        #expect(code?.copyPayload == "let x = 42")
        #expect(code?.copyPayload.contains("```") == false)
        #expect(code?.copyPayload.contains("swift") == false)
    }

    @Test func copyPayloadKeepsInternalBlankLinesAndDropsTheFenceNewline() {
        let markdown = "```\nfirst\n\nsecond\n```"
        let code = codeBlock(in: markdown)
        #expect(code?.copyPayload == "first\n\nsecond")
    }

    @Test func copyPayloadOfAnEmptyFenceIsEmpty() {
        let code = codeBlock(in: "```swift\n```")
        #expect(code?.copyPayload == "")
        #expect(code?.lineCount == 1)
    }

    @Test func copyWritesExactlyTheCodeToThePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-launch-code-block-tests"))
        let block = CodeBlockContent(infoString: "swift", code: "let x = 42\nprint(x)")
        CodeBlockView.writeToPasteboard(block.copyPayload, pasteboard: pasteboard)
        #expect(pasteboard.string(forType: .string) == "let x = 42\nprint(x)")
        pasteboard.releaseGlobally()
    }

    // MARK: - Splitting the answer

    @Test func answerSplitsIntoProseCodeProse() {
        let markdown = """
        Here is code:

        ```swift
        let x = 42
        ```

        Done.
        """
        let segments = MarkdownRenderer.segments(markdown)
        #expect(segments.count == 3)
        guard case .prose(let before) = segments[0].content,
              case .code(let block) = segments[1].content,
              case .prose(let after) = segments[2].content
        else {
            Issue.record("expected prose, code, prose, got \(segments.map(\.content))")
            return
        }
        #expect(before.contains("Here is code:"))
        #expect(block.copyPayload == "let x = 42")
        #expect(after.contains("Done."))
    }

    @Test func proseSegmentsCarryNoFenceMarkers() {
        let markdown = "Above\n\n```swift\nlet x = 1\n```\n\nBelow"
        for segment in MarkdownRenderer.segments(markdown) {
            guard case .prose(let source) = segment.content else { continue }
            #expect(!source.contains("```"), "the fence belongs to the code segment, not the prose")
            #expect(!source.contains("let x = 1"))
        }
    }

    @Test func adjacentFencesProduceNoEmptyProseSegment() {
        let markdown = "```\na\n```\n\n```\nb\n```"
        let segments = MarkdownRenderer.segments(markdown)
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { if case .code = $0.content { return true } else { return false } })
    }

    @Test func aCodeOnlyAnswerIsOneCodeSegment() {
        let segments = MarkdownRenderer.segments("```sh\nls\n```")
        #expect(segments.count == 1)
        guard case .code = segments.first?.content else {
            Issue.record("expected one code segment")
            return
        }
    }

    @Test func aCodeFreeAnswerIsOneProseSegment() {
        let segments = MarkdownRenderer.segments("Just prose, with `inline code`.")
        #expect(segments.count == 1)
        guard case .prose(let source) = segments.first?.content else {
            Issue.record("expected one prose segment")
            return
        }
        #expect(source == "Just prose, with `inline code`.")
    }

    @Test func anEmptyAnswerHasNoSegments() {
        #expect(MarkdownRenderer.segments("").isEmpty)
    }

    @Test func anUnclosedFenceStillBecomesACodeSegment() {
        let segments = MarkdownRenderer.segments("While it streams:\n\n```swift\nlet x = 1\n")
        #expect(segments.count == 2)
        guard case .code(let block) = segments.last?.content else {
            Issue.record("an unclosed fence must not crash the split")
            return
        }
        #expect(block.language == "swift")
        #expect(block.copyPayload == "let x = 1")
    }

    @Test func segmentIDsMatchTheirPosition() {
        let markdown = "A\n\n```\nb\n```\n\nC\n\n```\nd\n```\n\nE"
        let segments = MarkdownRenderer.segments(markdown)
        #expect(segments.map(\.id) == Array(0..<segments.count))
        #expect(segments.count == 5)
    }

    @Test func indentedFenceInsideProseStillSplits() {
        let markdown = """
        Intro.

        - Step one:

          ```sh
          make install
          ```

        Outro.
        """
        let segments = MarkdownRenderer.segments(markdown)
        #expect(segments.contains { if case .code = $0.content { return true } else { return false } })
        #expect(segments.first?.content != nil)
    }

    // MARK: - Wrap

    @Test func wrapIsOffByDefault() {
        let state = CodeBlockWrapState.initialState
        #expect(state.isWrapped == false)
        #expect(state.scrollsSideways, "long lines must scroll sideways until the reader asks")
    }

    @Test func wrapToggleFlipsBothWays() {
        var state = CodeBlockWrapState.initialState
        state.toggle()
        #expect(state.isWrapped)
        #expect(!state.scrollsSideways)
        state.toggle()
        #expect(!state.isWrapped)
        #expect(state.scrollsSideways)
    }

    @Test func wrapReadsClearlyInBothStates() {
        var state = CodeBlockWrapState.initialState
        #expect(state.accessibilityValue == "Off")
        #expect(CodeBlockWrapState.label == "Wrap")
        #expect(CodeBlockWrapState.accessibilityLabel == "Wrap long lines")
        #expect(state.helpText.contains("sideways"))
        state.toggle()
        #expect(state.accessibilityValue == "On")
        #expect(CodeBlockWrapState.label == "Wrap", "the visible label must not vanish when wrap is on")
        #expect(state.helpText.contains("Wrapping"))
        #expect(state.helpText.contains("sideways"), "the way back must be discoverable too")
    }

    @Test func theCopyControlNamesBothItsStates() {
        #expect(CodeBlockView.copyAccessibilityLabel(didCopy: false) == "Copy code")
        #expect(CodeBlockView.copyAccessibilityLabel(didCopy: true) == "Copied")
        #expect(CodeBlockView.copyHelpText.contains("fence markers"))
    }

    @Test func theBlockAnnouncesItsLanguageAndSize() {
        let swift = CodeBlockContent(infoString: "swift", code: "let x = 1")
        #expect(swift.accessibilityLabel == "swift code block, 1 line")
        let plain = CodeBlockContent(infoString: nil, code: "a\nb")
        #expect(plain.accessibilityLabel == "Code block, 2 lines")
    }

    // MARK: - Height

    @Test func measuredHeightCountsTheCodeBlockChrome() {
        let code = "```\nlet a = 1\nlet b = 2\n```"
        let measured = MarkdownRenderer.measuredHeight(markdown: code, width: 620)
        let body = 2 * CodeBlockMetrics.lineHeight
        #expect(
            measured > body + CodeBlockMetrics.chromeHeight,
            "the header strip and padding have to be in the measured height, got \(measured)"
        )
    }

    @Test func measuredHeightGrowsWithTheCode() {
        let short = MarkdownRenderer.measuredHeight(markdown: "```\nlet a = 1\n```", width: 620)
        let long = MarkdownRenderer.measuredHeight(
            markdown: "```\nlet a = 1\nlet b = 2\nlet c = 3\n```",
            width: 620
        )
        #expect(long > short)
    }

    @Test func measuredHeightStillSumsProseAndCode() {
        let proseOnly = MarkdownRenderer.measuredHeight(markdown: "Above\n\nBelow", width: 620)
        let withCode = MarkdownRenderer.measuredHeight(
            markdown: "Above\n\n```\nlet a = 1\n```\n\nBelow",
            width: 620
        )
        #expect(withCode > proseOnly)
    }

    @Test func theDrawnStackMatchesTheMeasuredHeight() throws {
        let markdown = "Prose before the block.\n\n```swift\nlet x = 42\nprint(x)\n```\n\nProse after."
        let width = House.Layout.answerMaxWidth
        let host = NSHostingView(
            rootView: MarkdownTextView(markdown: markdown, isStreaming: false)
                .frame(width: width)
        )
        host.layoutSubtreeIfNeeded()
        let drawn = host.fittingSize.height
        let measured = MarkdownRenderer.measuredHeight(markdown: markdown, width: width)
        #expect(
            abs(drawn - measured) <= 8,
            "the answer height must come from what is drawn: drawn \(drawn), measured \(measured)"
        )
    }

    @Test func acodeBlockRendersItsChromeAndBody() throws {
        let markdown = "```swift\nlet x = 42\n```"
        let width = House.Layout.answerMaxWidth
        let host = NSHostingView(
            rootView: MarkdownTextView(markdown: markdown, isStreaming: false)
                .frame(width: width)
        )
        host.frame = NSRect(x: 0, y: 0, width: width, height: host.fittingSize.height)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("no bitmap for the hosted answer")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        #expect(image.size.height > CodeBlockMetrics.chromeHeight)
        #expect(image.size.width == width)
    }

    // MARK: - Accessibility

    // The chrome's controls are SwiftUI Buttons, so they sit in the keyboard
    // focus chain and are exposed to VoiceOver; their names, values, and help
    // text are built by the pure members tested above. An offscreen test
    // process has no accessibility tree to walk (`accessibilityChildren()`
    // comes back empty), so the tree itself is checked by hand in the app.

    // MARK: - Helpers

    private func codeBlock(in markdown: String) -> CodeBlockContent? {
        for segment in MarkdownRenderer.segments(markdown) {
            if case .code(let block) = segment.content { return block }
        }
        return nil
    }
}
