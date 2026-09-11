// AskAIRowLocalAnswerTests: when the typed text has a local answer (math, a
// conversion, a date, a fact), Tab and the Ask AI row show it in root search
// and never reach the model, so the row says so and draws no ⇥ hint. The
// g2- render proofs draw the row for a math input in both appearances.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Ask AI row on a local answer", .serialized)
@MainActor
struct AskAIRowLocalAnswerTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    private func make(
        appearance: AppearancePreference = .dark,
        configure: (inout QuickSettings) -> Void = { _ in }
    ) -> (QuickViewModel, MockQuickService) {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.autoCopy = false
        settings.historyEnabled = false
        settings.tabShortcutHintVisible = true
        configure(&settings)
        let mock = MockQuickService()
        let vm = QuickViewModel(settings: settings, service: mock, pasteboard: FakePasteboard())
        return (vm, mock)
    }

    private func askRow(_ vm: QuickViewModel) -> LauncherCatalogItem? {
        for result in vm.launcherMatches {
            if case .item(let item) = result, item.kind == .askAI { return item }
        }
        return nil
    }

    @Test func mathSaysItIsAnsweredHereWithNoTabHint() throws {
        let (vm, _) = make()
        vm.input = "2+2"

        let row = try #require(askRow(vm))
        #expect(row.detail == "Answered here, not sent to \(vm.activeModelDisplay)")
        #expect(!row.detail.contains("⇥"), "Tab does not open Quick AI for math")
        #expect(!row.detail.contains("opens Quick AI"))
        #expect(vm.typedTextHasLocalAnswer("2+2"))
    }

    @Test func conversionsAndFactsSayTheSame() {
        let (vm, _) = make()
        for text in ["12 km in miles", "80 kg to lb", "(3+4)*2"] {
            #expect(vm.localAnswer(for: text) != nil, "\(text) has a local answer")
            #expect(vm.askAIItem(query: text).detail.hasPrefix("Answered here"), "\(text)")
        }
    }

    @Test func ordinaryTextStillPromisesTheModelAndTheTabHint() {
        let (vm, _) = make()
        let detail = vm.askAIItem(query: "write a haiku").detail
        #expect(detail.contains("to \(vm.activeModelDisplay)"))
        #expect(detail.hasSuffix("⇥ opens Quick AI"))
        #expect(!vm.typedTextHasLocalAnswer("write a haiku"))
    }

    @Test func aSavedPromptAliasIsNotALocalAnswer() {
        let (vm, _) = make { settings in
            settings.savedPrompts.append(SavedPrompt(name: "Fix", alias: "fix", prompt: "Fix: {input}"))
        }
        let text = "\(vm.settings.savedPromptPrefix)fix 2+2"
        #expect(!vm.typedTextHasLocalAnswer(text), "the alias runs, it is not math")
        #expect(!vm.askAIItem(query: text).detail.hasPrefix("Answered here"))
    }

    @Test func theRowAndTabAgree() async {
        let (vm, mock) = make()
        vm.input = "2+2"
        #expect(vm.askAIItem(query: "2+2").detail.hasPrefix("Answered here"))

        #expect(vm.handleTab())

        #expect(!vm.isQuickAIPresented, "the row said the answer stays here")
        #expect(vm.rootAnswer?.answer == "4")
        #expect(await mock.sendCallCount == 0, "nothing reached the model")
    }

    // MARK: - Render proof (g2-)

    @Test func rendersTheAskAIRowForMath() throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let (vm, _) = make(appearance: appearance == .darkAqua ? .dark : .light)
            vm.input = "(12+30)*2"
            let row = askRow(vm)
            #expect(row?.detail.hasPrefix("Answered here") == true)
            let image = try OverlayRenderProofTests.renderOnGround(
                OverlayView(viewModel: vm),
                appearance: appearance,
                width: vm.currentPanelWidth
            )
            try Self.save(image, name: "g2-ask-ai-row-math-\(suffix).png")

            // The same row on text for the model, for comparison.
            let (prompt, _) = make(appearance: appearance == .darkAqua ? .dark : .light)
            prompt.input = "what is a context budget"
            let promptImage = try OverlayRenderProofTests.renderOnGround(
                OverlayView(viewModel: prompt),
                appearance: appearance,
                width: prompt.currentPanelWidth
            )
            try Self.save(promptImage, name: "g2-ask-ai-row-prompt-\(suffix).png")
        }
    }

    private static func save(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ProofError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    private enum ProofError: Error { case noBitmap }
}
