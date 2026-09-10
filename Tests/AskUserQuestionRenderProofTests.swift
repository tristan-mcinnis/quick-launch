// AskUserQuestionRenderProofTests — visual proof for the inline
// multiple-choice card.
//
// The card is inline content in the answer block: the window grows for it or
// the last option is clipped. This hosts the real OverlayView in an offscreen
// NSHostingView at the computed window height, renders it in dark mode, and
// writes /tmp/quick-launch-render-proof/ask-user-question-dark.png so a
// reviewer can see the question, the selected option, and the key hint
// without launching the app.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Ask user question render proof", .serialized)
@MainActor
struct AskUserQuestionRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    private static func card() -> AskUserQuestion {
        AskUserQuestion(
            question: "Which folder should the new project live in?",
            options: [
                AskUserQuestionOption(label: "~/Documents/code", detail: "Matches your existing projects"),
                AskUserQuestionOption(label: "~/vault", detail: "For a vault-backed project"),
                AskUserQuestionOption(label: "Somewhere else…"),
            ]
        )
    }

    @Test func rendersLiveQuestionCardInDarkMode() throws {
        var settings = QuickSettings()
        settings.appearance = .dark
        let vm = QuickViewModel(settings: settings)
        vm.lastQuestion = "Set up a new project folder for me and ask me to choose from the available options"
        vm.isStreaming = true
        vm.presentAskQuestion(Self.card())
        vm.moveAskQuestionSelection(1)

        let image = try Self.render(viewModel: vm, appearance: .darkAqua)
        try Self.save(image, name: "ask-user-question-dark.png")

        // The window has to be tall enough to hold the whole card: the
        // estimate is what the AppDelegate resizes the panel to.
        #expect(image.size.height >= vm.estimatedWindowHeight - 1)
        #expect(vm.estimatedWindowHeight > 0)
    }

    @Test func rendersAnsweredQuestionAsTheThreadRecord() throws {
        var settings = QuickSettings()
        settings.appearance = .dark
        let vm = QuickViewModel(settings: settings)
        vm.currentConversation = QuickConversation(providerID: UUID(), model: "dark-proof")
        vm.lastQuestion = "Set up a new project folder for me"
        vm.output = "Created the project folder at ~/vault."
        vm.currentConversation?.messages = [
            QuickMessage(role: .user, content: "Set up a new project folder for me"),
            QuickMessage(role: .assistant, content: "Which folder?", askUserQuestion: Self.answered()),
            QuickMessage(role: .user, content: "~/vault"),
            QuickMessage(role: .assistant, content: "Created the project folder at ~/vault."),
        ]
        let image = try Self.render(viewModel: vm, appearance: .darkAqua)
        try Self.save(image, name: "ask-user-question-record-dark.png")
    }

    private static func answered() -> AskUserQuestion {
        var card = AskUserQuestion(
            question: "Which folder should the new project live in?",
            options: [
                AskUserQuestionOption(label: "~/Documents/code", detail: "Matches your existing projects"),
                AskUserQuestionOption(label: "~/vault", detail: "For a vault-backed project"),
                AskUserQuestionOption(label: "Somewhere else…"),
            ]
        )
        card.selectedIndex = 1
        return card
    }

    private static func render(viewModel vm: QuickViewModel, appearance: NSAppearance.Name) throws -> NSImage {
        let width = vm.currentPanelWidth
        let height = max(vm.estimatedWindowHeight, 300)
        let root = OverlayView(viewModel: vm)
            .dynamicTypeSize(.large)
            .frame(width: width, height: height, alignment: .top)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ProofError.noBitmap
        }
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
