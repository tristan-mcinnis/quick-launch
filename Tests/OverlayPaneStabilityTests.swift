// The window-stability contract for the floating ⌘K pane.
//
// The AppDelegate sizes the panel from PanelSizing; the pane views render
// with the same constants. These tests hold the two sides together: opening
// or closing a pane must not move the window unless the pane genuinely needs
// more room, and the pane must fit inside the window that math produces.
// Render proofs land in /tmp/quick-launch-render-proof/pane-*.png.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("OverlayPaneStability", .serialized)
@MainActor
struct OverlayPaneStabilityTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    /// The same math AppDelegate.resizePanelForContent applies — it now
    /// lives on the view model, so the test and the app cannot drift.
    private static func estimatedWindowHeight(_ vm: QuickViewModel) -> CGFloat {
        vm.estimatedWindowHeight
    }

    private static func renderAtWindowSize(_ vm: QuickViewModel, name: String) throws {
        let width = vm.currentPanelWidth
        let height = estimatedWindowHeight(vm)
        let host = NSHostingView(
            rootView: OverlayView(viewModel: vm).frame(width: width, height: height, alignment: .top)
        )
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    private static func makeViewModel() -> QuickViewModel {
        var settings = QuickSettings()
        settings.appearance = .dark
        return QuickViewModel(
            settings: settings,
            applicationCatalog: StabilityApplicationCatalog(),
            launcherCatalog: StabilityLauncherCatalog()
        )
    }

    @Test func commandKDoesNotMoveTheRootWindow() throws {
        let vm = Self.makeViewModel()
        vm.input = ""
        vm.applicationSelectionIndex = 0
        let before = Self.estimatedWindowHeight(vm)
        try Self.renderAtWindowSize(vm, name: "pane-root-before.png")

        vm.handleCommandK()
        #expect(vm.isItemActionPanePresented)
        let during = Self.estimatedWindowHeight(vm)
        #expect(during == before, "opening ⌘K over a tall list must not resize the window")
        // The pane fits inside that window: input row + pane + margin.
        let paneBottom = PanelSizing.inputHeight
            + PanelSizing.itemActionPaneHeight(rows: vm.filteredFocusedItemActions.count)
            + PanelSizing.paneBottomMargin
        #expect(paneBottom <= during)
        try Self.renderAtWindowSize(vm, name: "pane-root-during.png")

        vm.closeItemActionPane()
        #expect(Self.estimatedWindowHeight(vm) == before, "closing ⌘K restores nothing because nothing moved")
    }

    @Test func thePaletteFloatsInsideTheFixedQuickAIWindow() async throws {
        let vm = Self.makeViewModel()
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Argentina won.", finishReason: "stop")])
        vm.service = mock
        vm.settings.autoCopy = false
        vm.input = "who won"
        await vm.submit()

        let before = Self.estimatedWindowHeight(vm)
        #expect(before == PanelSizing.quickAIHeight, "an answer lives on the fixed Quick AI surface")
        vm.handleCommandK()
        #expect(vm.isActionPalettePresented)
        let during = Self.estimatedWindowHeight(vm)
        #expect(during == before, "the palette floats over the fixed surface; the window never moves")
        // The pane fits above the composer row with room to spare.
        let required = QuickAIView.composerRowHeight
            + PanelSizing.actionPaletteHeight(rows: vm.actionPaletteEntryCount)
            + PanelSizing.paneBottomMargin
        #expect(required <= during)
        try Self.renderAtWindowSize(vm, name: "pane-answer-palette.png")
    }

    @Test func longMarkdownAnswerFillsTheCappedWindowAndScrolls() async throws {
        let vm = Self.makeViewModel()
        let mock = MockQuickService()
        let answer = (1...12).map { section in
            """
            ## Section \(section)

            An explanation line that wraps at the panel width and keeps \
            going for a while so the measured height matters.

            ```swift
            let code = \(section)
            ```
            """
        }.joined(separator: "\n\n")
        await mock.setResponses([StreamDelta(text: answer, finishReason: "stop")])
        vm.service = mock
        vm.settings.autoCopy = false
        vm.input = "long answer"
        await vm.submit()
        // However long the answer, the surface keeps its one height and the
        // thread scrolls inside it instead of clipping below the window.
        #expect(Self.estimatedWindowHeight(vm) == PanelSizing.quickAIHeight)
        #expect(vm.currentPanelWidth == PanelSizing.panelWidth)
        try Self.renderAtWindowSize(vm, name: "pane-answer-long.png")
    }

    @Test func newsStyleBulletsRenderTightAndAligned() async throws {
        let vm = Self.makeViewModel()
        let mock = MockQuickService()
        let answer = """
        Here's a quick snapshot of top headlines:

        - **World:** A massive mudslide engulfed a crossing on the \
        Nepal-China border, with CCTV capturing people fleeing moments \
        before impact.
        - **Entertainment:** "Beauty in Black" Season 3 premieres this \
        week on Netflix.
        - **US:** Dolly Parton made a visit to a coal-mining town, and the \
        top dog breeds for 2026 were announced.

        For more detail, the full live coverage is on CNN, Al Jazeera, \
        USA Today, and Mint.

        Sources: [Al Jazeera](https://aljazeera.com), [CNN](https://cnn.com)
        """
        await mock.setResponses([StreamDelta(text: answer, finishReason: "stop")])
        vm.service = mock
        vm.settings.autoCopy = false
        vm.input = "ok whats new?"
        await vm.submit()
        try Self.renderAtWindowSize(vm, name: "pane-answer-news.png")
    }

    @Test func detailPaneAndWidthSurviveCommandK() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-pane-stability-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "Screenshot 2026-08-22 at 09.41.12.png"
        try ScreenAwarenessTests.writeImage(to: folder.appendingPathComponent(name), text: "Stability")

        let vm = Self.makeViewModel()
        vm.settings.screenshotTextSearch = false
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)
        #expect(vm.showsDetailPane)
        let widthBefore = vm.currentPanelWidth

        vm.handleCommandK()
        #expect(vm.isItemActionPanePresented)
        #expect(vm.showsDetailPane, "the preview stays behind the floating pane")
        #expect(vm.currentPanelWidth == widthBefore, "⌘K must not change the window width")
    }
}

private final class StabilityApplicationCatalog: ApplicationCatalogServicing {
    let applications: [LaunchableApplication] = [
        LaunchableApplication(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            url: URL(fileURLWithPath: "/Applications/Safari.app")
        ),
    ]
    func launch(_ application: LaunchableApplication) -> Bool { true }
}

private final class StabilityLauncherCatalog: LauncherCatalogServicing {
    var snippets = [LauncherCatalogItem(
        kind: .snippet, itemID: "sig", title: "Signature", detail: "Snippet", value: "Best regards"
    )]
    var quickLinks: [LauncherCatalogItem] = []
    func reload() {}
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteSnippet(_ item: LauncherCatalogItem) throws {}
}
