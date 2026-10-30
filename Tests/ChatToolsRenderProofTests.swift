// ChatToolsRenderProofTests — visual proof for tools inside the chat.
//
// Hosts the real OverlayView on the Quick AI surface offscreen, in both
// appearances, and writes PNGs to /tmp/quick-launch-render-proof/:
//   c-quick-ai-tools-thread-{dark,light}.png     memory and task lines, the
//                                                answer, its sources, and the
//                                                Capture to Memory checkmark
//   c-quick-ai-tools-streaming-{dark,light}.png  a finished call's line and
//                                                the next call's status
//   c-quick-ai-tools-palette-{dark,light}.png    ⌘K › Tools with one tool off
//   c-quick-ai-sources-palette-{dark,light}.png  ⌘K › Open Source

import AppKit
import Foundation
import HouseDesign
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Chat tools render proof", .mainActorRenderLane, .serialized)
@MainActor
struct ChatToolsRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    private static let memoryLine = ChatToolRecord(
        kind: .memory,
        summary: "Searched memory: 4 hits",
        sources: [
            ChatSource(title: "state/decisions/dec-20260903-02.md", day: "2026-09-03", path: "/Users/test/memory/state/decisions/dec-20260903-02.md"),
            ChatSource(title: "episodic/2026-09-06.md", day: "2026-09-06", path: "/Users/test/memory/episodic/2026-09-06.md"),
        ]
    )
    private static let tasksLine = ChatToolRecord(
        kind: .today,
        summary: "Read tasks: 6 results",
        sources: [
            ChatSource(title: "Acme Launch status", day: "2026-08-24", path: "/Users/test/memory/kb/databases/projects/acme-launch/00-status.md"),
            ChatSource(title: "Brief from the client", day: "2026-08-20", path: "/Users/test/memory/kb/databases/emails/brief.md"),
        ]
    )
    private static let answer = "You picked the **long deck** on 3 September, and the tasks still agree: the Acme Launch status (24 August) names it the current cross-functional reference. The client's brief asks for the consumer section to be rebuilt first."

    private static func makeViewModel(_ appearance: NSAppearance.Name) -> (QuickViewModel, MockQuickService) {
        var settings = QuickSettings()
        settings.appearance = appearance == .darkAqua ? .dark : .light
        settings.autoCopy = false
        settings.historyEnabled = true
        let mock = MockQuickService()
        let vm = QuickViewModel(
            settings: settings,
            service: mock,
            webSearchService: GatedWebSearchService(result: ""),
            pasteboard: FakePasteboard()
        )
        vm.fileOpener = FakeFileOpener()
        vm.memoryService = FakeMemory()
        vm.skillLibrary = SkillLibrary(root: FileManager.default.temporaryDirectory)
        return (vm, mock)
    }

    private static func appearances() -> [(NSAppearance.Name, String)] {
        [(.darkAqua, "dark"), (.aqua, "light")]
    }

    /// An answered thread: the question, the memory and task lines above
    /// the answer, the four sources under it, and the capture checkmark.
    private static func answered(_ appearance: NSAppearance.Name) async -> QuickViewModel {
        let (vm, mock) = makeViewModel(appearance)
        await mock.setResponses([
            StreamDelta(text: nil, finishReason: nil, toolRecord: memoryLine),
            StreamDelta(text: nil, finishReason: nil, toolRecord: tasksLine),
            StreamDelta(text: answer, finishReason: "stop"),
        ])
        let memory = FakeMemory()
        vm.memoryCapture = memory
        vm.openQuickAI()
        vm.input = "which deck did we pick for acme launch"
        await vm.submit()
        await vm.captureAnswerToMemory()
        return vm
    }

    @Test func rendersAThreadWithToolLinesAndSources() async throws {
        for (appearance, suffix) in Self.appearances() {
            let vm = await Self.answered(appearance)
            let message = try #require(vm.conversationMessages.last)
            #expect(message.tools.map(\.kind) == [.memory, .today, .capture])
            #expect(message.sources.count == 4)
            #expect(vm.isQuickAIPresented)
            let image = try Self.render(vm, appearance: appearance)
            #expect(image.size.width == PanelSizing.panelWidth)
            #expect(image.size.height == PanelSizing.quickAIHeight)
            try Self.save(image, name: "c-quick-ai-tools-thread-\(suffix).png")
        }
    }

    @Test func rendersTheLinesWhileTheAnswerIsStillComing() throws {
        for (appearance, suffix) in Self.appearances() {
            let (vm, _) = Self.makeViewModel(appearance)
            vm.openQuickAI()
            vm.currentConversation = QuickConversation(
                providerID: InferenceProvider.deepSeekID,
                model: InferenceProvider.deepSeekDefaultModel,
                messages: [QuickMessage(role: .user, content: "what is on my plate for acme launch this week")]
            )
            vm.isStreaming = true
            vm.noteLiveToolRecord(ChatToolRecord(kind: .today, summary: "Read today: 2 captures, 31 open tasks"))
            vm.noteLiveToolRecord(ChatToolRecord(kind: .skill, summary: "Read skill: float"))
            vm.streamingStatus = "Searching memory…"
            try Self.save(try Self.render(vm, appearance: appearance), name: "c-quick-ai-tools-streaming-\(suffix).png")
        }
    }

    /// The activity line open, with a failure drawn outside it. Appearance
    /// only; the folding rules are in `ToolActivitySummaryTests`.
    @Test func rendersTheActivityLineOpenWithAFailureOutsideIt() throws {
        for (appearance, suffix) in Self.appearances() {
            let records = [
                Self.memoryLine,
                Self.tasksLine,
                ChatToolRecord(kind: .skill, summary: "Read skill: float"),
                ChatToolRecord(kind: .today, summary: "Today's tasks failed", failed: true),
            ]
            let summary = ToolActivitySummary.summarize(records.map(\.activityLine))
            let headline = try #require(summary.headline)
            let view = VStack(alignment: .leading, spacing: House.Spacing.xs) {
                ToolActivityGroup(headline: headline, lines: summary.folded, startsExpanded: true) { line in
                    HStack(spacing: House.Spacing.xs) {
                        Image(systemName: line.symbol).frame(width: House.Control.keyCap)
                        Text(line.text)
                    }
                    .font(AQDesign.TypeToken.body)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                }
                ForEach(Array(summary.exposed.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: House.Spacing.xs) {
                        Image(systemName: line.symbol).frame(width: House.Control.keyCap)
                        Text(line.text)
                    }
                    .font(AQDesign.TypeToken.body)
                    .foregroundStyle(AQDesign.ColorToken.textTertiary)
                }
            }
            .padding(House.Spacing.md)
            .frame(width: 420, height: 170, alignment: .topLeading)
            .background(AQDesign.ColorToken.raisedSurface)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 170)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(rep)
            try Self.save(image, name: "c-quick-ai-tools-activity-open-\(suffix).png")
        }
    }

    @Test func rendersCommandKToolsWithOneToolOff() async throws {
        for (appearance, suffix) in Self.appearances() {
            let vm = await Self.answered(appearance)
            vm.toggleChatTool(.web)
            vm.openActionPaletteSubmenu(.tools)
            #expect(vm.isActionPalettePresented)
            #expect(vm.actionPaletteSubmenu == .tools)
            #expect(!vm.chatTools.contains(.web))
            try Self.save(try Self.render(vm, appearance: appearance), name: "c-quick-ai-tools-palette-\(suffix).png")
        }
    }

    @Test func rendersCommandKOpenSource() async throws {
        for (appearance, suffix) in Self.appearances() {
            let vm = await Self.answered(appearance)
            await vm.performResultAction(.openSource)
            #expect(vm.actionPaletteSubmenu == .sources)
            #expect(vm.paletteSourceRows.count == 4)
            try Self.save(try Self.render(vm, appearance: appearance), name: "c-quick-ai-sources-palette-\(suffix).png")
        }
    }

    // MARK: - Helpers

    /// The Quick AI surface at its one fixed size, as the window draws it.
    private static func render(_ vm: QuickViewModel, appearance: NSAppearance.Name) throws -> NSImage {
        let width = vm.currentPanelWidth
        let height = vm.estimatedWindowHeight
        let root = OverlayView(viewModel: vm)
            .frame(width: width, height: height, alignment: .top)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProofError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func save(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ProofError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    enum ProofError: Error { case noBitmap }
}
