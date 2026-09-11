import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("PanelSizing")
struct PanelSizingTests {

    // MARK: - Idle (collapsed)

    @Test func testIdleHeightIsInputOnly() {
        let h = PanelSizing.panelHeight(errorMessage: nil)
        #expect(h == PanelSizing.inputHeight)
    }

    // MARK: - Quick AI opens at the launcher width and its own height

    /// The standard size; the user can drag it larger (QuickAIResizeTests).
    @Test func testQuickAISurfaceIsTheLauncherWidthAndAFixedHeight() {
        #expect(PanelSizing.panelWidth == House.Layout.panelWidth)
        #expect(PanelSizing.panelWidth == 750)
        #expect(PanelSizing.quickAIHeight == House.Layout.quickAIHeight)
        #expect(PanelSizing.quickAIHeight == 475)
    }

    // MARK: - Error banner adds 40

    @Test func testErrorBannerAddsFourtyOnTopOfIdle() {
        let h = PanelSizing.panelHeight(errorMessage: "boom")
        #expect(h == PanelSizing.inputHeight + PanelSizing.errorBannerHeight)
    }

    // MARK: - Idempotence: same inputs -> same output

    @Test func testPureFunctionIsIdempotent() {
        let a = PanelSizing.panelHeight(errorMessage: nil, suggestionCount: 3)
        let b = PanelSizing.panelHeight(errorMessage: nil, suggestionCount: 3)
        #expect(a == b)
    }

    @Test func testItemActionPaneHugsItsRowsAndCapsAtSix() {
        // header + divider + list (3 rows + 2 gaps + 12 inset) + divider + search
        let threeRows = PanelSizing.paneHeaderHeight + 1
            + (3 * PanelSizing.actionRowHeight + 2 * PanelSizing.actionRowSpacing + 12)
            + 1 + PanelSizing.paneSearchRowHeight
        #expect(PanelSizing.itemActionPaneHeight(rows: 3) == threeRows)
        // 20 rows scroll behind a six-row viewport.
        let six = PanelSizing.itemActionPaneHeight(rows: 6)
        #expect(PanelSizing.itemActionPaneHeight(rows: 20) == six)
        // Zero rows keep one placeholder row; the pane never collapses to chrome.
        #expect(PanelSizing.itemActionPaneHeight(rows: 0) == PanelSizing.itemActionPaneHeight(rows: 1))
    }

    @Test func testPaletteHugsItsRows() {
        // search row + spacing + list (2 rows + 1 gap) + spacing + hint row
        let twoRows = House.Control.row + 8
            + (2 * PanelSizing.actionRowHeight + PanelSizing.actionRowSpacing)
            + 8 + House.Control.tile
        #expect(PanelSizing.actionPaletteHeight(rows: 2) == twoRows)
        #expect(PanelSizing.actionPaletteHeight(rows: 0) == PanelSizing.actionPaletteHeight(rows: 1))
    }

    @Test func testWindowKeepsBaseHeightWhileAPaneFloats() {
        // Tall list behind a small pane: no jump when the pane opens.
        #expect(PanelSizing.windowHeight(base: 600, paneHeight: 300) == 600)
        // Short window under a tall pane: grow to fit input + pane + margin.
        let grown = PanelSizing.windowHeight(base: 120, paneHeight: 300)
        #expect(grown == PanelSizing.inputHeight + 300 + PanelSizing.paneBottomMargin)
        // No pane: base passes through untouched.
        #expect(PanelSizing.windowHeight(base: 480, paneHeight: nil) == 480)
    }

    @Test func testLauncherSuggestionsAddBoundedHeight() {
        let three = PanelSizing.panelHeight(
            errorMessage: nil, suggestionCount: 3
        )
        let many = PanelSizing.panelHeight(
            errorMessage: nil, suggestionCount: 20
        )
        #expect(three == PanelSizing.inputHeight + 3 * PanelSizing.launcherRowHeight)
        let expectedMany = PanelSizing.inputHeight + 12 * PanelSizing.launcherRowHeight
        #expect(many == expectedMany)
    }

    @Test func testCompletedResultActionsAddCompactFooter() {
        let height = PanelSizing.panelHeight(
            errorMessage: nil,
            showsResultActions: true
        )
        #expect(height == PanelSizing.inputHeight + AQDesign.controlHeight + 1)
    }

    @Test func testScreenshotAttachmentAddsCompactPreviewRow() {
        let height = PanelSizing.panelHeight(
            errorMessage: nil,
            hasAttachment: true
        )
        #expect(height == PanelSizing.inputHeight + PanelSizing.attachmentHeight)
    }

    // MARK: - Footer and launcher rows

    @Test func testFooterAddsItsRowAndDivider() {
        let h = PanelSizing.panelHeight(
            errorMessage: nil, showsFooter: true
        )
        let expected = PanelSizing.inputHeight + AQDesign.footerHeight + 1
        #expect(h == expected)
    }

    @Test func testLauncherRowsIncludeHeaderChrome() {
        let plain = PanelSizing.panelHeight(
            errorMessage: nil, suggestionCount: 3
        )
        let launcher = PanelSizing.panelHeight(
            errorMessage: nil,
            suggestionCount: 3, launcherRowCount: 3
        )
        let expectedPlain = PanelSizing.inputHeight + 3 * PanelSizing.launcherRowHeight
        #expect(plain == expectedPlain)
        let expectedLauncher: CGFloat = plain + PanelSizing.launcherListChrome
        #expect(launcher == expectedLauncher)
        // A full list caps exactly where the rendered view caps.
        let full = PanelSizing.panelHeight(
            errorMessage: nil,
            suggestionCount: 20, launcherRowCount: 20
        )
        let expectedFull = PanelSizing.inputHeight + PanelSizing.launcherListMaximumHeight
        #expect(full == expectedFull)
    }

    /// The estimate must cover the rendered list: a too-short window clips
    /// the last row against the footer (the "one result" case).
    @MainActor @Test func estimateCoversTheRenderedSingleResultWindow() {
        var settings = QuickSettings()
        settings.appearance = .dark
        let vm = QuickViewModel(settings: settings)
        vm.input = "this is an ai chat"
        let host = NSHostingView(
            rootView: OverlayView(viewModel: vm).frame(width: vm.currentPanelWidth)
        )
        host.appearance = NSAppearance(named: .darkAqua)
        let fitting = host.fittingSize.height
        let estimate = PanelSizing.panelHeight(
            errorMessage: nil,
            suggestionCount: max(vm.launcherMatches.count, vm.savedPromptMatches.count),
            showsFooter: vm.showsLauncherFooter,
            launcherRowCount: vm.launcherMatches.count
        )
        #expect(estimate >= fitting, "a short estimate clips the last row")
        #expect(estimate <= fitting + 16, "a tall estimate leaves dead space")
    }

    @Test func screenHistorySaveHasAProductionVisibilityBudget() {
        #expect(ItemActionForm.screenHistorySave.minimumWindowHeight! >= 620)
        #expect(ItemActionForm.screenHistorySave.minimumWindowHeight! > PanelSizing.windowHeight(
            base: PanelSizing.inputHeight,
            paneHeight: PanelSizing.itemActionPaneHeight(rows: 2)
        ))
    }
}
