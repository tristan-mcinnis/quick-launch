import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Attachment usability render proof", .serialized)
@MainActor
struct AttachmentUsabilityRenderProofTests {
    private static let text = (1...18).map {
        "Paragraph \($0). The selected passage stays available when the conversation moves from Quick AI to AI Chat. It is included when you send your question."
    }.joined(separator: "\n\n")

    @Test func rendersCompleteSelectionPreviewAndDraftControls() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let preview = SelectedTextPreview(text: Self.text, title: "Selected text from Notes")
            try save(OverlayRenderProofTests.renderOnGround(
                preview,
                appearance: appearance,
                width: House.Layout.chatRail * 2
            ), name: "att-selection-preview-\(suffix).png")

            var settings = QuickSettings()
            settings.appearance = appearance == .darkAqua ? .dark : .light
            settings.autoCopy = false
            settings.historyEnabled = false
            let extractor = FakeAttachmentExtractor()
            await extractor.set(.failure("This file could not be read"), for: "Unavailable.pdf")
            let vm = QuickViewModel(settings: settings, service: MockQuickService(), attachmentExtractor: extractor)
            vm.openQuickAI()
            vm.launchSelection = QuickViewModel.LaunchSelection(text: Self.text, appName: "Notes")
            try save(OverlayRenderProofTests.renderOnGround(
                OverlayView(viewModel: vm), appearance: appearance,
                width: PanelSizing.panelWidth,
                height: PanelSizing.quickAIHeight
            ), name: "att-selection-draft-\(suffix).png")

            vm.clearLaunchSelection()
            vm.attachmentTray.add(.file(URL(fileURLWithPath: "/tmp/Unavailable.pdf")))
            vm.attachmentTray.add(.file(URL(fileURLWithPath: "/tmp/Notes.txt")))
            await vm.attachmentTray.waitUntilRead()
            vm.input = "Compare the files"
            try save(OverlayRenderProofTests.renderOnGround(
                OverlayView(viewModel: vm), appearance: appearance,
                width: PanelSizing.panelWidth,
                height: PanelSizing.quickAIHeight
            ), name: "att-usability-states-\(suffix).png")

            vm.attachmentTray.removeAll()
            vm.openAddContextMenu()
            try save(OverlayRenderProofTests.renderOnGround(
                OverlayView(viewModel: vm), appearance: appearance,
                width: PanelSizing.panelWidth,
                height: PanelSizing.quickAIHeight
            ), name: "att-usability-menu-\(suffix).png")

            vm.closeAddContextMenu()
            vm.input = ""
            var context = CaptureContext(appName: "Notes")
            context.selectedText = Self.text
            vm.pendingContext = context
            vm.attachmentTray.add(.file(URL(fileURLWithPath: "/tmp/Supporting notes.txt")))
            await vm.attachmentTray.waitUntilRead()
            let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
            let chatWindow = AIChatWindowModel(chat: vm, defaults: defaults)
            chatWindow.showRail()
            try save(OverlayRenderProofTests.renderOnGround(
                AIChatWindowView(model: chatWindow), appearance: appearance,
                width: House.Layout.chatMinWidth,
                height: House.Layout.chatMinHeight
            ), name: "att-selection-context-ai-chat-min-\(suffix).png")
        }
    }

    private func save(_ image: NSImage, name: String) throws {
        let directory = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name))
    }
}
