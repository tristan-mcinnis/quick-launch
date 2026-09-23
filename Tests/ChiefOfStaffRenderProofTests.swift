// ChiefOfStaffRenderProofTests — render proofs of the pinned Chief of Staff
// conversation in the AI Chat window, dark and light, at the standard size,
// NARROW (0.75 × the window's minimum width), and wide; plus the focused card
// with its keys, a card in Edit, and the rail with the pinned row. PNGs land
// in /tmp/quick-launch-render-proof/cos-*.png for a reviewer to look at.
//
// The standalone ChiefOfStaff.app shipped a thread window that clipped when
// the window was narrow. The narrow check here asks the root view what width
// it takes when offered less than the window's minimum: a view that forced a
// minimum would answer wider than the offer, and overflow.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Chief of Staff render proof", .serialized)
@MainActor
struct ChiefOfStaffRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    static let normal = CGSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
    static let narrow = CGSize(width: (House.Layout.chatMinWidth * 0.75).rounded(), height: House.Layout.chatHeight)
    static let wide = CGSize(width: 1_400, height: 900)

    private func makeWindow(appearance: AppearancePreference) async throws -> (AIChatWindowModel, ChiefOfStaffModel) {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.autoCopy = false
        settings.historyEnabled = true
        let service = MockQuickService()
        let chat = QuickViewModel(settings: settings, service: service)
        let suite = "ChiefOfStaffRenderProofTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        window.window = FakeAIChatWindow()
        let chiefOfStaff = ChiefOfStaffModel(paths: try CosFixture.home(), runner: RecordingCosRunner())
        await chiefOfStaff.reload(force: true)
        chat.chiefOfStaff = chiefOfStaff
        chat.chiefOfStaffOpener = { window.openChiefOfStaff(proposalID: $0) }
        window.openChiefOfStaff()
        await service.setResponses([StreamDelta(
            text: "Two cards wait. The **budget** one is the client's: do it before Tuesday so the quote goes out on time.",
            finishReason: "stop"
        )])
        chat.input = "What should I do first?"
        await chat.submit()
        chat.input = "Draft the quote note too."
        return (window, chiefOfStaff)
    }

    @Test func rendersThePinnedConversationSet() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let preference: AppearancePreference = appearance == .darkAqua ? .dark : .light

            // The chat holds the Chief of Staff weakly, as the app's does:
            // the proof keeps each one alive, as the app delegate does.
            let (plain, plainCos) = try await makeWindow(appearance: preference)
            #expect(plain.isChiefOfStaffOpen)
            try Self.save(try Self.render(plain, size: Self.normal, appearance: appearance), name: "cos-normal-\(suffix).png")
            try Self.save(try Self.render(plain, size: Self.narrow, appearance: appearance), name: "cos-narrow-\(suffix).png")
            try Self.save(try Self.render(plain, size: Self.wide, appearance: appearance), name: "cos-wide-\(suffix).png")
            withExtendedLifetime(plainCos) {}

            // ↑ from the empty composer: the newest card has the keyboard
            // and shows its keys.
            let (focused, cos) = try await makeWindow(appearance: preference)
            focused.chat.input = ""
            _ = focused.handleChiefOfStaffKey(key: .upArrow, characters: nil, modifiers: [])
            #expect(cos.focusedCardID == "ee55ff66")
            try Self.save(try Self.render(focused, size: Self.normal, appearance: appearance), name: "cos-focused-\(suffix).png")
            try Self.save(try Self.render(focused, size: Self.narrow, appearance: appearance), name: "cos-focused-narrow-\(suffix).png")

            // ⌘E: the card's task as its title and due fields.
            _ = focused.handleChiefOfStaffKey(key: nil, characters: "e", modifiers: [.command])
            #expect(cos.isEditingFocusedCard)
            try Self.save(try Self.render(focused, size: Self.wide, appearance: appearance), name: "cos-edit-\(suffix).png")

            // The rail: the pinned row first, with its waiting count.
            let (rail, railCos) = try await makeWindow(appearance: preference)
            rail.showRail()
            try Self.save(try Self.render(rail, size: Self.normal, appearance: appearance), name: "cos-rail-\(suffix).png")
            withExtendedLifetime(railCos) {}
        }
    }

    /// Offered less than the window's minimum width, the root view takes
    /// exactly the offer: nothing forces a width, so nothing overflows.
    @Test func theRootReflowsAtNarrowWidths() async throws {
        let (window, cos) = try await makeWindow(appearance: .dark)
        _ = window.handleChiefOfStaffKey(key: .upArrow, characters: nil, modifiers: [.option])
        #expect(cos.focusedCardID != nil)
        for width in [Self.narrow.width, House.Layout.chatMinWidth / 2] {
            let controller = NSHostingController(rootView: AIChatWindowView(model: window))
            let fitted = controller.sizeThatFits(in: CGSize(width: width, height: Self.normal.height))
            #expect(fitted.width <= width + 0.5, "the root asked for \(fitted.width) of \(width)")
        }
    }

    // MARK: - Rendering

    private static func render(_ model: AIChatWindowModel, size: CGSize, appearance: NSAppearance.Name) throws -> NSImage {
        let root = AIChatWindowView(model: model)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw RenderError.noBitmap }
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
        else { throw RenderError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    private enum RenderError: Error { case noBitmap }
}
