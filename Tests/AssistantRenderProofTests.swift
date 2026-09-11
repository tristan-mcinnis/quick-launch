// AssistantRenderProofTests — offscreen proofs of the assistant surfaces, in
// both appearances, written to /tmp/quick-launch-render-proof/d-*.png:
// the Quick AI header of an assistant chat (just picked, and after an
// answer), Change Assistant open over the composer, and the Saved Prompts
// editor's Assistant card for an assistant, a plain transform, and a command.

import AppKit
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Assistant render proofs", .serialized)
@MainActor
struct AssistantRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
    private static let appearances: [(NSAppearance.Name, AppearancePreference, String)] = [
        (.darkAqua, .dark, "dark"),
        (.aqua, .light, "light"),
    ]

    private static func makeViewModel(_ appearance: AppearancePreference, service: MockQuickService) -> QuickViewModel {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.historyEnabled = false
        settings.autoCopy = false
        return QuickViewModel(settings: settings, service: service, pasteboard: FakePasteboard())
    }

    @Test func rendersTheQuickAIHeaderOfAnAssistantChat() async throws {
        for (appearance, preference, suffix) in Self.appearances {
            // Just picked: the empty surface, the assistant on the model line.
            let pickedMock = MockQuickService()
            let picked = Self.makeViewModel(preference, service: pickedMock)
            picked.input = "/vault"
            await picked.submitResolvingFuzzyAlias()
            #expect(picked.activeAssistant?.name == "Vault researcher")
            #expect(picked.quickAITitle == "Quick AI")
            try Self.save(try Self.renderQuickAI(picked, appearance: appearance), name: "d-quick-ai-assistant-picked-\(suffix).png")

            // After an answer: the chat title over "Vault researcher · model".
            let answeredMock = MockQuickService()
            let answered = Self.makeViewModel(preference, service: answeredMock)
            answered.input = "/vault"
            await answered.submit()
            await answeredMock.setResponses([StreamDelta(
                text: "The pricing decision is in **projects/acme/decisions.md** (2026-08-14): hold the day rate at the 2025 level for Q3.",
                finishReason: "stop"
            )])
            answered.input = "What did we decide about Acme pricing?"
            await answered.submit()
            #expect(answered.activeAssistant != nil)
            try Self.save(try Self.renderQuickAI(answered, appearance: appearance), name: "d-quick-ai-assistant-answer-\(suffix).png")

            // Change Assistant open over the composer, on the chat's assistant.
            answered.openAssistantChooser()
            #expect(answered.isAssistantChooserPresented)
            #expect(answered.assistantChooserIndex == 1)
            try Self.save(try Self.renderQuickAI(answered, appearance: appearance), name: "d-quick-ai-assistant-chooser-\(suffix).png")
        }
    }

    @Test func rendersTheSavedPromptsEditorAssistantCard() async throws {
        for (appearance, preference, suffix) in Self.appearances {
            let vm = Self.makeViewModel(preference, service: MockQuickService())
            let index = try #require(vm.settings.savedPrompts.firstIndex { $0.alias == "vault" })
            // Chosen tools and one skill that is gone, so every row shows.
            vm.settings.savedPrompts[index].enabledTools = [.vault, .memory]
            vm.settings.savedPrompts[index].contextRefs = ["costing", "old-notes"]
            let id = vm.settings.savedPrompts[index].id
            let editor = SavedPromptsEditor(
                viewModel: vm,
                initialSelection: id,
                knownSkills: ["costing", "email-ops"]
            )
            .frame(width: Self.paneWidth, height: Self.editorHeight, alignment: .top)
            .background(AQDesign.ColorToken.windowSurface)
            .preferredColorScheme(preference == .dark ? .dark : .light)
            try Self.save(try Self.render(editor, appearance: appearance, size: NSSize(width: Self.paneWidth, height: Self.editorHeight)), name: "d-settings-assistant-editor-\(suffix).png")
        }
    }

    /// A plain transform shows only Instructions in the Assistant card; a
    /// command action shows it turned off. Neither shows Tools or skills.
    @Test func rendersTheAssistantCardForATransformAndACommand() async throws {
        for (appearance, preference, suffix) in Self.appearances {
            let vm = Self.makeViewModel(preference, service: MockQuickService())
            let command = SavedPrompt(
                name: "Remember",
                alias: "remember",
                prompt: "",
                commandExecutable: "recall",
                commandArguments: ["remember", "{input}"]
            )
            vm.settings.savedPrompts.append(command)
            let grammar = try #require(vm.settings.savedPrompts.first { $0.alias == "grammar" })
            #expect(!grammar.isAssistant)
            for (id, name) in [(grammar.id, "transform"), (command.id, "command")] {
                let editor = SavedPromptsEditor(viewModel: vm, initialSelection: id, knownSkills: ["costing"])
                    .frame(width: Self.paneWidth, height: Self.editorHeight, alignment: .top)
                    .background(AQDesign.ColorToken.windowSurface)
                    .preferredColorScheme(preference == .dark ? .dark : .light)
                try Self.save(
                    try Self.render(editor, appearance: appearance, size: NSSize(width: Self.paneWidth, height: Self.editorHeight)),
                    name: "d-settings-assistant-editor-\(name)-\(suffix).png"
                )
            }
        }
    }

    /// The Settings pane beside the rail and its hairline.
    private static let paneWidth = SettingsView.windowSize.width - House.Layout.settingsRail - House.hairline
    /// Tall enough for the list, the command card, and the Assistant card.
    private static let editorHeight: CGFloat = 1_340

    private static func renderQuickAI(_ vm: QuickViewModel, appearance: NSAppearance.Name) throws -> NSImage {
        #expect(vm.estimatedWindowHeight == PanelSizing.quickAIHeight)
        let size = NSSize(width: vm.currentPanelWidth, height: vm.estimatedWindowHeight)
        let root = OverlayView(viewModel: vm)
            .frame(width: size.width, height: size.height, alignment: .top)
        return try render(root, appearance: appearance, size: size)
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, size: NSSize) throws -> NSImage {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
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
