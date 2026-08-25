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

    /// Mirrors AppDelegate.resizePanelForContent.
    private static func estimatedWindowHeight(_ vm: QuickViewModel) -> CGFloat {
        let visibleBody = vm.conversationMessages.count > 2
            ? vm.conversationTranscriptText
            : vm.output
        let base = PanelSizing.panelHeight(
            output: visibleBody,
            isStreaming: vm.isStreaming,
            errorMessage: vm.errorMessage,
            suggestionCount: max(vm.launcherMatches.count, vm.savedPromptMatches.count),
            showsResultActions: false,
            hasAttachment: vm.hasPendingAttachment,
            showsFooter: vm.showsLauncherFooter,
            launcherRowCount: vm.launcherMatches.count,
            showsQuestion: (vm.lastQuestion?.isEmpty == false) && !vm.isConversationHistoryPresented,
            gridRows: vm.isGridCatalog
                ? Int((Double(vm.launcherMatches.count) / Double(QuickViewModel.gridColumns)).rounded(.up))
                    + max(0, vm.gridSections.count - 1)
                : 0,
            gridSections: vm.isGridCatalog ? vm.gridSections.count : 0,
            showsDetailPane: vm.showsDetailPane
        )
        var pane: CGFloat?
        if vm.isItemActionPanePresented {
            pane = vm.activeItemActionForm.map(PanelSizing.itemActionFormPaneHeight)
                ?? PanelSizing.itemActionPaneHeight(rows: vm.filteredFocusedItemActions.count)
        } else if vm.isActionPalettePresented {
            pane = PanelSizing.actionPaletteHeight(rows: vm.actionPaletteEntryCount)
        }
        var total = PanelSizing.windowHeight(base: base, paneHeight: pane)
        if vm.activeItemActionForm == .screenHistorySave {
            total = max(total, PanelSizing.screenHistorySaveMinimumHeight)
        }
        return total
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

    @Test func shortWindowGrowsExactlyToFitThePalette() async throws {
        let vm = Self.makeViewModel()
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "Argentina won.", finishReason: "stop")])
        vm.service = mock
        vm.settings.autoCopy = false
        vm.input = "who won"
        await vm.submit()

        let before = Self.estimatedWindowHeight(vm)
        vm.handleCommandK()
        #expect(vm.isActionPalettePresented)
        let during = Self.estimatedWindowHeight(vm)
        let required = PanelSizing.inputHeight
            + PanelSizing.actionPaletteHeight(rows: vm.actionPaletteEntryCount)
            + PanelSizing.paneBottomMargin
        #expect(during == max(before, required))
        try Self.renderAtWindowSize(vm, name: "pane-answer-palette.png")
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
