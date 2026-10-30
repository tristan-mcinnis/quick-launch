import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// The incremental split and render of a streaming answer must equal the
/// whole-answer split and render at every point of the stream, however the
/// text was chunked.
@Suite("StreamingAnswer", .mainActorRenderLane)
@MainActor
struct StreamingAnswerTests {
    nonisolated static let corpus: [String: String] = [
        "headings and paragraphs": """
        # Release plan

        The release has **three parts**. Build, test, ship.

        ## Build

        Run `swift build` on Thursday.

        Setext heading
        ---

        Last paragraph with a [link](https://example.com) and *emphasis*.
        """,
        "lists": """
        Steps:

        - Check the build number
        - Read the changelog
          - nested item
          - another

        1. First
        2. Second

        Done with the lists.

        - a

        - loose item

        After.
        """,
        "code fences": """
        Intro paragraph.

        ```swift
        let x = 1
        print(x)
        ```

        Between the blocks.

        ```
        plain
        ```

        - item

        ```python
        still streaming
        """,
        "closed then prose": "Before.\n\n```sh\nls\n```\nAfter the fence on the next line.\n\nMore after.\n\n    indented code\n\nTail.",
        "code in a list": "Intro.\n\n- item one\n\n  ```swift\n  let a = 1\n  ```\n\n  more of item one\n\n- item two\n\nOutro paragraph.\n\nLast.",
        "quote table rule": "> quoted line\n> second line\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\nAfter the rule.\n\nEnd.",
        "cjk": "# 发布计划\n\n本次发布分为**三个部分**。周四构建，周五测试。\n\n- 检查版本号\n- 阅读更新日志\n\n```swift\nlet 版本 = 42\n```\n\n完成。😀 emoji 👨‍👩‍👧 here.\n\n结束。",
        "empty list item": "Start.\n\n-\n\nNext paragraph after an empty item.\n\nEnd.",
        "reference definition": "See [the docs][docs] for details.\n\nMiddle paragraph.\n\n[docs]: https://example.com\n\nEnd.",
    ]

    /// The chunk sizes a stream might arrive in, in characters.
    static let chunkSizes = [1, 3, 7, 40]

    private func check(_ snapshot: StreamingAnswer.Snapshot, against prefix: String, label: String) {
        let whole = MarkdownRenderer.segments(prefix)
        #expect(snapshot.segments == whole, "segments differ: \(label)")
        if case .prose(let last)? = whole.last?.content {
            let expected = MarkdownRenderer.render(last)
            let run = snapshot.run
            #expect(run != nil, "no live run: \(label)")
            if let run {
                #expect(run.text.drawsSameAs(expected), "prose differs: \(label)")
            }
        } else {
            #expect(snapshot.run == nil, "run on a code tail: \(label)")
        }
    }

    @Test(arguments: Array(corpus.keys.sorted()))
    func incrementalEqualsWholeAtEveryChunking(name: String) throws {
        let text = try #require(Self.corpus[name])
        let characters = Array(text)
        for size in Self.chunkSizes {
            let model = StreamingAnswer()
            var length = 0
            while length < characters.count {
                length = min(characters.count, length + size)
                let prefix = String(characters[0..<length])
                check(model.update(prefix), against: prefix, label: "\(name) size \(size) at \(length)")
            }
        }
    }

    @Test func irregularChunkingsAgree() throws {
        let text = Self.corpus.keys.sorted().compactMap { Self.corpus[$0] }.joined(separator: "\n\n")
        let characters = Array(text)
        var generator = SplitMix(seed: 7)
        for round in 0..<6 {
            let model = StreamingAnswer()
            var length = 0
            while length < characters.count {
                length = min(characters.count, length + 1 + Int(generator.next() % 60))
                let prefix = String(characters[0..<length])
                check(model.update(prefix), against: prefix, label: "mixed round \(round) at \(length)")
            }
        }
    }

    @Test func replacedTextStartsOver() {
        let model = StreamingAnswer()
        _ = model.update("# One\n\nfirst answer.\n\nsecond block.")
        let snapshot = model.update("Totally different.\n\nAnother.")
        check(snapshot, against: "Totally different.\n\nAnother.", label: "replaced")
    }

    @Test func finishedBlocksFreezeWhileTextAppends() throws {
        let paragraphs = (0..<30).map { "Paragraph \($0) with some **bold** words." }
        let model = StreamingAnswer()
        var frozenLengths: [Int] = []
        var epochs: Set<Int> = []
        var text = ""
        for paragraph in paragraphs {
            for piece in [String(paragraph.prefix(12)), String(paragraph.dropFirst(12)), "\n\n"] {
                text += piece
                let run = try #require(model.update(text).run)
                frozenLengths.append(run.frozen.length)
                epochs.insert(run.epoch)
            }
        }
        #expect(frozenLengths == frozenLengths.sorted(), "frozen text only grows")
        #expect(epochs.count == 1, "one epoch while only appending")
        #expect((frozenLengths.last ?? 0) > 500, "earlier paragraphs are frozen")
    }

    @Test func textStorageFollowsTheStreamWithOnlyTailEdits() throws {
        let text = Self.corpus["lists"]! + "\n\n" + Self.corpus["headings and paragraphs"]!
        let characters = Array(text)
        let model = StreamingAnswer()
        let storage = NSTextStorage()
        let caret = NSAttributedString(string: "\u{258B}")
        var shown = StreamingRun.Shown()
        var length = 0
        while length < characters.count {
            length = min(characters.count, length + 5)
            let prefix = String(characters[0..<length])
            guard let run = model.update(prefix).run else { continue }
            run.apply(to: storage, shown: &shown, suffix: caret)
            let expected = NSMutableAttributedString(attributedString: run.text)
            expected.append(caret)
            #expect(NSAttributedString(attributedString: storage).drawsSameAs(NSAttributedString(attributedString: NSTextStorage(attributedString: expected))), "storage differs at \(length)")
        }
    }

    @Test func runHeightTracksTheWholeRunMeasure() throws {
        let text = Self.corpus["headings and paragraphs"]! + "\n\n" + Self.corpus["lists"]!
        let characters = Array(text)
        let model = StreamingAnswer()
        var length = 0
        while length < characters.count {
            length = min(characters.count, length + 11)
            let prefix = String(characters[0..<length])
            guard let run = model.update(prefix).run,
                  case .prose(let source)? = model.update(prefix).segments.last?.content else { continue }
            let incremental = run.height(width: 560, suffix: nil)
            let whole = MarkdownRenderer.proseHeight(markdown: source, width: 560, transient: true)
            #expect(abs(incremental - whole) <= 3, "height \(incremental) vs \(whole) at \(length)")
        }
    }
}

private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension NSAttributedString {
    /// Equal text and equal attributes, colours compared by what they draw
    /// (dynamic colours are new objects on every read, so `isEqual` fails).
    @MainActor func drawsSameAs(_ other: NSAttributedString) -> Bool {
        guard string == other.string, length == other.length else { return false }
        var index = 0
        while index < length {
            var rangeA = NSRange(), rangeB = NSRange()
            let a = attributes(at: index, effectiveRange: &rangeA)
            let b = other.attributes(at: index, effectiveRange: &rangeB)
            let end = min(NSMaxRange(rangeA), NSMaxRange(rangeB))
            guard Set(a.keys) == Set(b.keys) else { return false }
            for (key, value) in a {
                let o = b[key]!
                if let c1 = value as? NSColor, let c2 = o as? NSColor {
                    var same = false
                    NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {
                        same = c1.usingColorSpace(.sRGB) == c2.usingColorSpace(.sRGB)
                    }
                    if !same { return false }
                } else if !(value as AnyObject).isEqual(o) {
                    return false
                }
            }
            index = end
        }
        return true
    }
}
