// ChatPerformanceBaselineTests — the AI Chat baseline: what one streaming
// flush costs as an answer grows to ~6,000 characters, and how long a
// 60-answer chat takes to build and lay out. Wall-clock numbers mean nothing
// while other builds share the machine, so this runs only when asked, on a
// quiet machine, and it asserts nothing about time: it prints the numbers
// for docs/polish-chat-baseline-20261018.md.
//   QUICK_LAUNCH_PERF=1 swift test --filter ChatPerformanceBaselineTests

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch
import HouseDesign

@Suite(
    "Chat performance baseline",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["QUICK_LAUNCH_PERF"] == "1")
)
@MainActor
struct ChatPerformanceBaselineTests {
    private static let width = House.Layout.answerMaxWidth

    /// A varied ~6,000-character answer: prose with bold and code spans,
    /// a list, and one fenced block, so a flush meets what real answers hold.
    static func sampleAnswer(targetLength: Int = 6_000) -> String {
        let paragraph = "The release has **three parts**. Build the app on Thursday, run `swift test` with the team on Friday morning, and ship it after lunch once the notes are ready. "
        let list = "- Check the build number\n- Read the changelog\n- Tag the commit\n\n"
        let code = "```swift\nlet release = Release(build: 42)\nprint(release.notes)\n```\n\n"
        var text = ""
        var index = 0
        while text.count < targetLength {
            switch index % 4 {
            case 1: text += list
            case 3: text += code
            default: text += paragraph + "\n\n"
            }
            index += 1
        }
        return String(text.prefix(targetLength))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    private static func answerTextViews(in view: NSView) -> [AnswerTextView] {
        var found: [AnswerTextView] = []
        if let text = view as? AnswerTextView { found.append(text) }
        for sub in view.subviews { found += answerTextViews(in: sub) }
        return found
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }

    private static func report(_ label: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(max(samples.count, 1))
        print(String(
            format: "PERF %@: n=%d mean=%.3f ms median=%.3f ms p95=%.3f ms max=%.3f ms",
            label, samples.count, mean, percentile(sorted, 0.5), percentile(sorted, 0.95), sorted.last ?? 0
        ))
    }

    /// The pure render path a flush runs on every body pass: segment split,
    /// attributed render of each prose run, and its measured height.
    @Test func streamingFlushRenderCost() {
        let full = Self.sampleAnswer()
        let chunk = 40
        let clock = ContinuousClock()
        var samples: [Double] = []
        var length = chunk
        while length <= full.count {
            let partial = String(full.prefix(length))
            let start = clock.now
            let segments = MarkdownRenderer.cachedSegments(partial, transient: true)
            for segment in segments {
                if case .prose(let source) = segment.content {
                    _ = MarkdownRenderer.proseHeight(markdown: source, width: Self.width, transient: true)
                }
            }
            samples.append(Self.milliseconds(start.duration(to: clock.now)))
            length += chunk
        }
        Self.report("flush render+measure (\(full.count) chars, \(chunk)-char chunks)", samples)
        #expect(!samples.isEmpty)
    }

    /// The same flush through the incremental path the streaming view uses:
    /// `StreamingAnswer` split and render, and the live run's measure.
    @Test func streamingFlushIncrementalCost() {
        let full = Self.sampleAnswer()
        let chunk = 40
        let model = StreamingAnswer()
        let clock = ContinuousClock()
        var samples: [Double] = []
        var length = chunk
        while length <= full.count {
            let partial = String(full.prefix(length))
            let start = clock.now
            let snapshot = model.update(partial)
            _ = snapshot.run?.height(width: Self.width, suffix: nil)
            samples.append(Self.milliseconds(start.duration(to: clock.now)))
            length += chunk
        }
        Self.report("flush incremental split+render+measure (\(full.count) chars, \(chunk)-char chunks)", samples)
        #expect(!samples.isEmpty)
    }

    /// The whole flush as the user's window does it: the streaming answer
    /// view re-hosted with the longer text, text storage replaced, and the
    /// layout settled.
    @Test func streamingFlushHostedViewCost() {
        let full = Self.sampleAnswer()
        let chunk = 40
        let host = NSHostingView(
            rootView: MarkdownTextView(markdown: "x", isStreaming: true, scrolls: false)
                .frame(width: Self.width)
        )
        host.frame = NSRect(x: 0, y: 0, width: Self.width, height: 600)
        host.layoutSubtreeIfNeeded()
        let clock = ContinuousClock()
        var samples: [Double] = []
        var length = chunk
        while length <= full.count {
            let partial = String(full.prefix(length))
            let start = clock.now
            host.rootView = MarkdownTextView(markdown: partial, isStreaming: true, scrolls: false)
                .frame(width: Self.width)
            host.layoutSubtreeIfNeeded()
            samples.append(Self.milliseconds(start.duration(to: clock.now)))
            length += chunk
        }
        Self.report("flush hosted view update (\(full.count) chars, \(chunk)-char chunks)", samples)
        // The flushes really drew: the text views hold the final text.
        let drawn = Self.answerTextViews(in: host).reduce(0) { $0 + $1.textStorage!.length }
        print("PERF hosted view holds \(drawn) drawn characters after the last flush")
        #expect(drawn > full.count / 2)
    }

    /// 60 finished answers (120 messages) built into a chat and laid out in
    /// the AI Chat window's thread, cold caches first, then warm.
    @Test func sixtyAnswerChatBuildAndLayout() {
        var settings = QuickSettings()
        settings.autoCopy = false
        settings.historyEnabled = false
        let chat = QuickViewModel(settings: settings, service: MockQuickService())
        let provider = settings.providers[0].id
        var messages: [QuickMessage] = []
        for index in 0..<60 {
            messages.append(QuickMessage(role: .user, content: "Question \(index): walk me through the release plan"))
            let answer = Self.sampleAnswer(targetLength: 800 + (index % 5) * 400)
            messages.append(QuickMessage(role: .assistant, content: "Answer \(index).\n\n" + answer))
        }
        let characters = messages.reduce(0) { $0 + $1.content.count }
        let clock = ContinuousClock()

        let buildStart = clock.now
        chat.loadConversation(QuickConversation(providerID: provider, model: "model", messages: messages))
        let buildTime = Self.milliseconds(buildStart.duration(to: clock.now))

        let size = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
        let host = NSHostingView(rootView: QuickAIThread(viewModel: chat).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)

        let coldStart = clock.now
        host.layoutSubtreeIfNeeded()
        let coldTime = Self.milliseconds(coldStart.duration(to: clock.now))

        let warmStart = clock.now
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let warmTime = Self.milliseconds(warmStart.duration(to: clock.now))

        let materialized = Self.answerTextViews(in: host).count
        print("PERF 60-answer chat: \(materialized) prose text views materialized at first layout")
        print(String(
            format: "PERF 60-answer chat (%d messages, %d chars): load conversation %.3f ms, first layout %.3f ms, relayout %.3f ms",
            messages.count, characters, buildTime, coldTime, warmTime
        ))
        #expect(chat.conversationMessages.count == 120)

        // The thread is lazy, so the lines above time only the first screen.
        // The cost of every answer, eagerly: each one measured cold, then
        // all 60 hosted in one non-lazy stack and laid out.
        let answers = messages.filter { $0.role == .assistant }.map(\.content)
        let measureStart = clock.now
        for answer in answers {
            _ = MarkdownRenderer.measuredHeight(markdown: answer, width: Self.width)
        }
        let measureTime = Self.milliseconds(measureStart.duration(to: clock.now))

        // Back to this chat after another one filled the caches: with
        // `cacheLimit` entries it is warm, at 64 it started cold again.
        for index in 0..<60 {
            _ = MarkdownRenderer.measuredHeight(markdown: "Other chat \(index).\n\n" + Self.sampleAnswer(targetLength: 1_000), width: Self.width)
        }
        let returnStart = clock.now
        for answer in answers {
            _ = MarkdownRenderer.measuredHeight(markdown: answer, width: Self.width)
        }
        let returnTime = Self.milliseconds(returnStart.duration(to: clock.now))
        print(String(format: "PERF 60 answers measured again after another 60-answer chat: %.3f ms", returnTime))

        let stack = NSHostingView(rootView: ScrollView {
            VStack(alignment: .leading, spacing: House.Spacing.md) {
                ForEach(Array(answers.enumerated()), id: \.offset) { _, answer in
                    MarkdownTextView(markdown: answer, isStreaming: false, scrolls: false)
                }
            }
        }.frame(width: Self.width, height: size.height))
        stack.frame = NSRect(x: 0, y: 0, width: Self.width, height: size.height)
        let stackStart = clock.now
        stack.layoutSubtreeIfNeeded()
        let stackTime = Self.milliseconds(stackStart.duration(to: clock.now))
        print(String(
            format: "PERF 60 answers eager: measure all cold %.3f ms; host all in a stack and lay out %.3f ms",
            measureTime, stackTime
        ))
    }
}
