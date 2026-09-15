// QuickAIResizeRenderProofTests: visual proof for Phase B1: the Quick AI
// surface at its standard 750 × 475 and dragged to 1100 × 760, in both
// appearances. The header and composer span the window; the thread stays one
// centred column (answers capped at `quickAIAnswerMaxWidth`, user pills at
// the column's right edge), so a wide window never stretches the lines.
//
// Renders the real OverlayView offscreen at the size the window would have
// and writes /tmp/quick-launch-render-proof/b1-quick-ai-*.png.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Quick AI resize render proof", .serialized)
@MainActor
struct QuickAIResizeRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
    private static let large = CGSize(width: 1100, height: 760)

    private static let question = "raycast founder, and what did the two of them build before it? Keep it short, I only need the names, the year, and the city the company is based in."
    private static let answer = """
    Raycast was co-founded by **Thomas Paul Mann** (CEO) and **Petr Nikolaev** (CTO) in 2020. Both are former Meta (Facebook) engineers who previously worked on developer tools and productivity workflows. The company was part of Y Combinator's Winter 2020 batch and is headquartered in London, UK.

    - Thomas Paul Mann led developer tooling teams at Facebook.
    - Petr Nikolaev worked on the iOS infrastructure behind Facebook's apps.
    """

    /// One case per appearance, so the main actor is free between them:
    /// other suites' main-actor waits (the translator's debounce) never
    /// starve behind one long render.
    enum ProofAppearance: String, CaseIterable, Sendable {
        case dark, light

        var name: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
    }

    @Test(arguments: ProofAppearance.allCases)
    func rendersTheStandardAndTheLargeSurface(_ proofAppearance: ProofAppearance) async throws {
        let appearance = proofAppearance.name
        let suffix = proofAppearance.rawValue
        let vm = try await Self.answeredViewModel(appearance: appearance)

        // 750 × 475: nothing moved from v1.4.0.
        #expect(vm.currentPanelWidth == 750)
        #expect(vm.estimatedWindowHeight == 475)
        let standard = try Self.render(vm, appearance: appearance)
        try Self.save(standard, name: "b1-quick-ai-750x475-\(suffix).png")
        await Task.yield()
        #expect(standard.size == CGSize(width: 750, height: 475))
        let standardInk = try #require(Self.threadInkRange(in: standard))
        // The column is the standard surface's: 20 pt gutters, answer
        // text from the left gutter, the pill ending at the right one.
        #expect(abs(standardInk.lowerBound - House.Spacing.lg) <= 3, "left ink at \(standardInk.lowerBound)")
        #expect(abs(standardInk.upperBound - (750 - House.Spacing.lg)) <= 2, "right ink at \(standardInk.upperBound)")

        // The user drags the window to 1100 × 760; the drag's end is
        // what the AppDelegate hands the view model.
        #expect(vm.rememberQuickAISize(Self.large))
        #expect(vm.currentPanelWidth == 1100)
        #expect(vm.estimatedWindowHeight == 760)
        let wide = try Self.render(vm, appearance: appearance)
        try Self.save(wide, name: "b1-quick-ai-1100x760-\(suffix).png")
        await Task.yield()
        #expect(wide.size == Self.large)
        let wideInk = try #require(Self.threadInkRange(in: wide))
        // The same column, centred: the gutters grow, the lines do not.
        let gutter = (Self.large.width - QuickAIView.threadColumnWidth) / 2
        #expect(abs(wideInk.lowerBound - gutter) <= 3, "left ink at \(wideInk.lowerBound), gutter \(gutter)")
        #expect(abs(wideInk.upperBound - (Self.large.width - gutter)) <= 2, "right ink at \(wideInk.upperBound)")
        #expect(
            abs((wideInk.upperBound - wideInk.lowerBound) - (standardInk.upperBound - standardInk.lowerBound)) <= 2,
            "the column is as wide at 1100 as at 750"
        )

        // ⌘K on the sized surface offers the reset, after the answer
        // actions (then Copy Message, for any message); typing finds it.
        vm.handleCommandK()
        #expect(vm.paletteSurfaceActions == [.attach, .resetSize, .copyMessage])
        vm.actionQuery = "reset size"
        #expect(vm.paletteSurfaceActions == [.resetSize])
        try Self.save(
            try Self.render(vm, appearance: appearance),
            name: "b1-quick-ai-1100x760-actions-\(suffix).png"
        )
        vm.closeActionPalette()
        await Task.yield()

        // Recent Chats keeps the window's size.
        vm.history = [vm.currentConversation!]
        vm.openRecentChats()
        #expect(vm.isRecentChatsPresented)
        #expect(vm.currentPanelWidth == 1100)
        try Self.save(
            try Self.render(vm, appearance: appearance),
            name: "b1-quick-ai-1100x760-recent-chats-\(suffix).png"
        )
    }

    // MARK: - Helpers

    private static func answeredViewModel(appearance: NSAppearance.Name) async throws -> QuickViewModel {
        var settings = QuickSettings()
        settings.appearance = appearance == .darkAqua ? .dark : .light
        settings.historyEnabled = false
        settings.autoCopy = false
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: answer, finishReason: "stop")])
        let vm = QuickViewModel(settings: settings, service: mock)
        vm.input = question
        #expect(vm.handleTab())
        await vm.tabSubmitTask?.value
        vm.webSearchNote = "Search web: Raycast founder and 2 more terms"
        #expect(vm.isQuickAIPresented)
        #expect(vm.conversationMessages.count == 2)
        return vm
    }

    /// The window as it draws at the view model's size.
    private static func render(_ vm: QuickViewModel, appearance: NSAppearance.Name) throws -> NSImage {
        let size = CGSize(width: vm.currentPanelWidth, height: vm.estimatedWindowHeight)
        let root = OverlayView(viewModel: vm)
            .dynamicTypeSize(.large)
            .frame(width: size.width, height: size.height, alignment: .top)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ProofError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// The leftmost and rightmost points, in points, where the thread draws
    /// anything (text, the pill's fill) in the band between the header and
    /// the composer. Each row is compared with its own ground at the far
    /// left of the panel, so the glass's vertical shading never counts.
    ///
    /// Reads the bitmap's bytes directly: `colorAt` made an `NSColor` per
    /// pixel and held the main actor for seconds on the wide surface.
    private static func threadInkRange(in image: NSImage) -> ClosedRange<CGFloat>? {
        guard let rep = image.representations.first as? NSBitmapImageRep,
              rep.bitsPerSample == 8, !rep.isPlanar, rep.samplesPerPixel >= 3,
              let data = rep.bitmapData
        else { return nil }
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        let top = Int((QuickAIView.headerHeight + House.Spacing.xs) * scale)
        let bottom = Int((image.size.height - QuickAIView.composerRowHeight - House.Spacing.xs) * scale)
        let groundX = Int(House.Spacing.xs * scale)
        let edge = Int(House.Spacing.xxs * scale)
        let stride = rep.samplesPerPixel
        let rgb = rep.bitmapFormat.contains(.alphaFirst) && rep.hasAlpha ? 1 : 0
        let threshold = 6
        var minX = Int.max
        var maxX = Int.min
        for y in Swift.stride(from: top, to: bottom, by: 2) {
            let row = data + y * rep.bytesPerRow
            let ground = row + groundX * stride + rgb
            for x in edge..<(rep.pixelsWide - edge) {
                let pixel = row + x * stride + rgb
                let delta = max(
                    abs(Int(pixel[0]) - Int(ground[0])),
                    abs(Int(pixel[1]) - Int(ground[1])),
                    abs(Int(pixel[2]) - Int(ground[2]))
                )
                if delta > threshold {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        guard minX <= maxX else { return nil }
        return (CGFloat(minX) / scale)...(CGFloat(maxX + 1) / scale)
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
