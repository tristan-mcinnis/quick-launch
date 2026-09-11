// PiHandoffRenderProofTests: Continue in pi on the Quick AI surface, drawn
// offscreen in both appearances: the ⌘K palette with its "Continue in pi"
// row and ⌥⌘P caps, the thread ending in the session line, and the line when
// Ghostty did not open. The hand-off runs through the real service with a
// fake runner, so nothing is started. Output:
// /tmp/quick-launch-render-proof/e-quick-ai-{state}-{dark,light}.png.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Continue in pi render proof", .serialized)
@MainActor
struct PiHandoffRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    @Test func rendersContinueInPiSet() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-handoff-proof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let preference: AppearancePreference = appearance == .darkAqua ? .dark : .light

            let vm = try await Self.answeredViewModel(appearance: preference)
            vm.piHandoff = Self.service(root: root, openStatus: 0)
            vm.webSearchNote = "Search web: Raycast founder and 2 more terms"

            // ⌘K: the row sits under Copy Chat with its own caps.
            vm.handleCommandK()
            #expect(vm.isActionPalettePresented)
            #expect(Array(vm.paletteResultActions.prefix(4)) == [.pasteBack, .copy, .copyChat, .continueInPi])
            try Self.save(
                try Self.renderQuickAI(vm, appearance: appearance),
                name: "e-quick-ai-continue-in-pi-actions-\(suffix).png"
            )

            // The thread ends with the line naming the session.
            await vm.performResultAction(.continueInPi)
            #expect(!vm.isActionPalettePresented)
            #expect(vm.threadNotice == "Opened in pi · tmux session ql-3fa9c1")
            try Self.save(
                try Self.renderQuickAI(vm, appearance: appearance),
                name: "e-quick-ai-opened-in-pi-\(suffix).png"
            )

            // Ghostty did not open: the session runs, the command is copied.
            let fallback = try await Self.answeredViewModel(appearance: preference)
            fallback.piHandoff = Self.service(root: root, openStatus: 1)
            await fallback.performResultAction(.continueInPi)
            #expect((fallback.pasteboard as? FakePasteboard)?.string == "tmux attach -t ql-3fa9c1")
            try Self.save(
                try Self.renderQuickAI(fallback, appearance: appearance),
                name: "e-quick-ai-pi-fallback-\(suffix).png"
            )
        }
    }

    // MARK: - Helpers

    private static func answeredViewModel(appearance: AppearancePreference) async throws -> QuickViewModel {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.historyEnabled = false
        settings.autoCopy = false
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(
            text: "Raycast was co-founded by **Thomas Paul Mann** (CEO) and **Petr Nikolaev** (CTO) in 2020. Both worked on developer tools at Facebook before, and the company is based in London.",
            finishReason: "stop"
        )])
        let vm = QuickViewModel(settings: settings, service: mock, pasteboard: FakePasteboard())
        vm.input = "raycast founder"
        #expect(vm.handleTab())
        await vm.tabSubmitTask?.value
        #expect(vm.isQuickAIPresented)
        return vm
    }

    private static func service(root: URL, openStatus: Int32) -> PiHandoffService {
        let runner = FakePiHandoffRunner.standard(openStatus: openStatus)
        return PiHandoffService(
            directory: root.appendingPathComponent("pi-handoff", isDirectory: true),
            home: root,
            run: { try await runner.run($0, $1, $2) },
            resolve: { URL(fileURLWithPath: "/opt/homebrew/bin").appendingPathComponent($0) },
            launchPath: "/usr/bin:/bin",
            makeShortID: { "3fa9c1" }
        )
    }

    /// The Quick AI surface at its fixed size, as the window draws it.
    private static func renderQuickAI(_ vm: QuickViewModel, appearance: NSAppearance.Name) throws -> NSImage {
        #expect(vm.currentPanelWidth == PanelSizing.panelWidth)
        #expect(vm.estimatedWindowHeight == PanelSizing.quickAIHeight)
        let width = vm.currentPanelWidth
        let height = vm.estimatedWindowHeight
        let host = NSHostingView(
            rootView: OverlayView(viewModel: vm)
                .dynamicTypeSize(.large)
                .frame(width: width, height: height, alignment: .top)
        )
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func save(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: outputDir.appendingPathComponent(name))
    }
}
