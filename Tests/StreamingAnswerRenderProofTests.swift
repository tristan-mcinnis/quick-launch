// StreamingAnswerRenderProofTests — the answer streamed in 23-character
// flushes into a hosted view, written to /tmp/quick-launch-render-proof/:
//   b1-streaming-mid-{dark,light}.png   part-way through, caret at the tail
//   b1-streaming-done-{dark,light}.png  the full text still marked streaming
//   b1-finished-{dark,light}.png        the same text as a finished answer
// The last two must read the same apart from the caret.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch
import HouseDesign

@Suite("Streaming answer render proof", .serialized)
@MainActor
struct StreamingAnswerRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
    private static let width: CGFloat = 520

    private static let answer = """
    # Release plan

    The release has **three parts**: build it on Thursday, run `swift test` with the team, and ship it after lunch. 发布分为三个部分。

    - Check the build number
    - Read the changelog
      - Tag the commit

    1. First, freeze the branch
    2. Second, cut the build

    ```swift
    let release = Release(build: 42)
    print(release.notes)
    ```

    > Ship only what the notes describe.

    | Step | Owner |
    |------|-------|
    | Build | Ana |
    | Ship | Ben |

    Then a closing paragraph that is still being written when the picture is taken, with a [link](https://example.com).
    """

    private static func host(_ markdown: String, streaming: Bool, appearance: NSAppearance.Name) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: view(markdown, streaming: streaming))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 640)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private static func view(_ markdown: String, streaming: Bool) -> AnyView {
        AnyView(
            MarkdownTextView(markdown: markdown, isStreaming: streaming, scrolls: false)
                .padding(House.Spacing.lg)
                .frame(width: width, alignment: .topLeading)
                .background(House.ColorToken.surface)
        )
    }

    private static func textViews(in view: NSView) -> [AnswerTextView] {
        var found: [AnswerTextView] = []
        if let text = view as? AnswerTextView { found.append(text) }
        for sub in view.subviews { found += textViews(in: sub) }
        return found
    }

    private static func save(_ host: NSView, name: String) throws {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProofError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw ProofError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    enum ProofError: Error { case noBitmap }

    @Test(arguments: [(NSAppearance.Name.darkAqua, "dark"), (NSAppearance.Name.aqua, "light")])
    func streamedAnswerDrawsLikeTheFinishedOne(appearance: NSAppearance.Name, suffix: String) throws {
        let characters = Array(Self.answer)
        let streaming = Self.host("x", streaming: true, appearance: appearance)
        var length = 0
        var midSaved = false
        while length < characters.count {
            length = min(characters.count, length + 23)
            streaming.rootView = Self.view(String(characters[0..<length]), streaming: true)
            streaming.layoutSubtreeIfNeeded()
            if !midSaved, length >= characters.count * 6 / 10 {
                try Self.save(streaming, name: "b1-streaming-mid-\(suffix).png")
                midSaved = true
            }
        }
        try Self.save(streaming, name: "b1-streaming-done-\(suffix).png")

        let finished = Self.host(Self.answer, streaming: false, appearance: appearance)
        try Self.save(finished, name: "b1-finished-\(suffix).png")

        // The streamed run holds the same prose as the finished answer: the
        // last run's text is the finished run's text plus the caret.
        let streamed = Self.textViews(in: streaming).compactMap { $0.textStorage?.string }
            .map { $0.hasSuffix("\u{258B}") ? String($0.dropLast()) : $0 }.sorted()
        let done = Self.textViews(in: finished).compactMap { $0.textStorage?.string }.sorted()
        #expect(streamed == done)
    }
}
