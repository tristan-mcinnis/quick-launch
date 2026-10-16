// QuickAIInputRenderProofTests: offscreen dark/light proofs for the new
// input-flow surfaces: the Clipboard History submenu inside Add Context, the
// Transform chooser filling a named argument, and the Review Changes card.
// PNGs land in /tmp/quick-launch-render-proof/k*.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Quick AI input render proof", .serialized)
@MainActor
struct QuickAIInputRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
    private static let appearances: [(NSAppearance.Name, String)] = [(.darkAqua, "dark"), (.aqua, "light")]

    private enum ProofError: Error { case noBitmap }

    private static func settings(_ appearance: NSAppearance.Name) -> QuickSettings {
        var settings = QuickSettings()
        settings.appearance = appearance == .darkAqua ? .dark : .light
        settings.autoCopy = false
        settings.historyEnabled = false
        return settings
    }

    private static func viewModel(_ appearance: NSAppearance.Name) -> QuickViewModel {
        let vm = QuickViewModel(
            settings: settings(appearance),
            service: MockQuickService(),
            clipboardHistory: RenderFakeClipboard(entries: [
                LauncherCatalogItem(
                    kind: .clipboard, itemID: "1", title: "Invoice total 4,200",
                    detail: "Text · Pinned", value: "Invoice total 4,200",
                    keywords: "pinned", isPinned: true
                ),
                LauncherCatalogItem(
                    kind: .clipboard, itemID: "2", title: "Screenshot 2026-10-15 at 21.04",
                    detail: "Image", value: "", keywords: "image picture"
                ),
                LauncherCatalogItem(
                    kind: .clipboard, itemID: "3", title: "Q3 report.pdf",
                    detail: "File", value: "file:///tmp/Q3%20report.pdf", keywords: "file"
                ),
            ]),
            attachmentExtractor: FakeAttachmentExtractor()
        )
        vm.overlayPresenter = RecordingPresenter()
        vm.openQuickAI()
        return vm
    }

    private static func render(_ vm: QuickViewModel, _ appearance: NSAppearance.Name) throws -> NSImage {
        try OverlayRenderProofTests.renderOnGround(
            OverlayView(viewModel: vm),
            appearance: appearance,
            width: PanelSizing.panelWidth,
            height: PanelSizing.quickAIHeight + House.Spacing.xxxxl * 2
        )
    }

    private static func save(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ProofError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    private static func averageBrightness(_ image: NSImage) -> Double {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        var total = 0.0
        var count = 0
        let step = 8
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                total += (color.redComponent + color.greenComponent + color.blueComponent) / 3
                count += 1
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    @Test func rendersClipboardHistorySubmenu() throws {
        for (appearance, suffix) in Self.appearances {
            let vm = Self.viewModel(appearance)
            vm.openAddContextMenu()
            vm.openClipboardHistory()
            #expect(vm.clipboardHistoryRows.count == 3)
            let image = try Self.render(vm, appearance)
            #expect(image.size.width > 0 && image.size.height > 0)
            try Self.save(image, name: "k1-clipboard-history-\(suffix).png")
        }
    }

    @Test func rendersTransformArgumentChooser() throws {
        for (appearance, suffix) in Self.appearances {
            let vm = Self.viewModel(appearance)
            vm.pendingTransformArguments = QuickViewModel.PendingTransformArguments(
                actionID: UUID(),
                alias: "pick",
                source: "Hello world",
                sourceLabel: "Clipboard",
                slots: [
                    SnippetArgument(
                        name: "audience", index: 0, defaultValue: "",
                        options: ["Editorial", "Casual", "Technical"]
                    ),
                ],
                values: [""],
                choosing: 0
            )
            vm.isTransformChooserPresented = true
            #expect(vm.transformChooserOptions.count == 3)
            #expect(vm.transformChooserTitle == "Choose audience")
            let image = try Self.render(vm, appearance)
            #expect(image.size.width > 0 && image.size.height > 0)
            try Self.save(image, name: "k2-transform-argument-\(suffix).png")
        }
    }

    @Test func rendersReviewChangesCard() throws {
        for (appearance, suffix) in Self.appearances {
            let vm = Self.viewModel(appearance)
            vm.pendingTransformReview = QuickViewModel.PendingTransformReview(
                original: "The quarterly figures show a modest rise in revenue across the region.",
                proposed: "Revenue rose modestly across the region this quarter.",
                sourceApp: "TextEdit",
                target: SelectedTextContext(
                    target: SelectionTarget(processIdentifier: 1, applicationName: "TextEdit"),
                    text: "The quarterly figures show a modest rise in revenue across the region."
                )
            )
            let image = try Self.render(vm, appearance)
            #expect(image.size.width > 0 && image.size.height > 0)
            try Self.save(image, name: "k3-review-changes-\(suffix).png")
        }
    }

    @Test func rendersFreeTextArgumentPrompt() throws {
        for (appearance, suffix) in Self.appearances {
            let vm = Self.viewModel(appearance)
            vm.pendingTransformArguments = QuickViewModel.PendingTransformArguments(
                actionID: UUID(),
                alias: "draft",
                source: "Some attached text",
                sourceLabel: "Clipboard",
                slots: [
                    SnippetArgument(name: "audience", index: 0, defaultValue: "", options: []),
                ],
                values: [""],
                choosing: nil,
                filling: 0
            )
            #expect(vm.isTransformArgumentFieldPresented)
            #expect(vm.transformArgumentPrompt == "audience")
            let image = try Self.render(vm, appearance)
            try Self.save(image, name: "k4-transform-argument-field-\(suffix).png")
        }
    }

    @Test func rendersClipboardTransformAffordance() async throws {
        for (appearance, suffix) in Self.appearances {
            let vm = Self.viewModel(appearance)
            vm.launchSelection = nil
            vm.attachmentTray.add(.selection("copied text", appName: "Clipboard"))
            await vm.attachmentTray.waitUntilRead()
            #expect(vm.hasTransformSource)
            #expect(vm.launchSelection == nil)
            let image = try Self.render(vm, appearance)
            try Self.save(image, name: "k5-clipboard-transform-affordance-\(suffix).png")
        }
    }

    @Test func reviewAndChooserReadDifferentlyInEachAppearance() throws {
        let dark = try Self.render(Self.viewModel(.darkAqua), .darkAqua)
        let light = try Self.render(Self.viewModel(.aqua), .aqua)
        #expect(Self.averageBrightness(dark) < Self.averageBrightness(light))
    }
}

@MainActor
private final class RenderFakeClipboard: ClipboardHistoryServicing {
    var entries: [LauncherCatalogItem]

    init(entries: [LauncherCatalogItem]) { self.entries = entries }

    func startMonitoring(limit: Int) {}
    func stopMonitoring() {}
    func record(_ text: String, limit: Int) {}
    func remove(_ item: LauncherCatalogItem) { entries.removeAll { $0.id == item.id } }
    func clear() { entries = [] }
    func payload(for item: LauncherCatalogItem) async -> ClipboardPayload? { nil }
}
