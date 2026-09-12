// AttachmentRenderProofTests — render proofs for the attachment chips and
// tray (spec 3.10, package WP-C) in both appearances: the strip with ready
// chips of each kind, the strip's reading, cut, failed, and selected
// states, Add Context with its seven rows, the Link field, and the drop
// overlay, on the 750 × 475 Quick AI surface and in the 860 × 620 AI Chat
// window. PNGs land in /tmp/quick-launch-render-proof/att-*.png.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Attachment render proof", .serialized)
@MainActor
struct AttachmentRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
    private static let appearances: [(NSAppearance.Name, String)] = [(.darkAqua, "dark"), (.aqua, "light")]

    // MARK: - Fixtures

    private static func settings(_ appearance: NSAppearance.Name) -> QuickSettings {
        var settings = QuickSettings()
        settings.appearance = appearance == .darkAqua ? .dark : .light
        settings.autoCopy = false
        settings.historyEnabled = false
        return settings
    }

    /// Quick AI with one answered question, as a chat looks before a
    /// follow-up with files.
    private static func quickAI(_ appearance: NSAppearance.Name) async -> QuickViewModel {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(
            text: "The quarter closed **12% up** on revenue. The report and the deck agree on the numbers; the budget sheet has the detail by team.",
            finishReason: "stop"
        )])
        let vm = QuickViewModel(settings: settings(appearance), service: service)
        vm.openQuickAI()
        vm.input = "how did the quarter go"
        await vm.submit()
        vm.input = "Compare the report with the deck"
        return vm
    }

    private static func aiChat(_ appearance: NSAppearance.Name) async -> AIChatWindowModel {
        let service = MockQuickService()
        await service.setResponses([StreamDelta(
            text: "The quarter closed **12% up** on revenue. The deck rounds it to 10%.",
            finishReason: "stop"
        )])
        let chat = QuickViewModel(settings: settings(appearance), service: service)
        let suite = "AttachmentRenderProofTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let window = AIChatWindowModel(chat: chat, defaults: defaults)
        chat.input = "how did the quarter go"
        await chat.submit()
        chat.input = "Which numbers differ between the two?"
        return window
    }

    private static let addedAt = Date(timeIntervalSinceReferenceDate: 779_000_000)

    private static func ref(
        _ kind: ChatAttachmentKind,
        _ name: String,
        bytes: Int? = nil,
        pages: Int? = nil,
        truncation: AttachmentTruncation? = nil,
        url: String? = nil,
        pixels: (Int, Int)? = nil
    ) -> ChatAttachmentRef {
        ChatAttachmentRef(
            kind: kind,
            name: name,
            byteCount: bytes,
            pageCount: pages,
            truncation: truncation,
            url: url.flatMap(URL.init(string:)),
            pixelWidth: pixels?.0,
            pixelHeight: pixels?.1,
            addedAt: addedAt
        )
    }

    /// A grey stand-in for a screenshot: a title bar, a sidebar, and lines.
    static func screenshot(width: Int = 1_944, height: Int = 1_464) -> QuickImageAttachment {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let w = CGFloat(width), h = CGFloat(height)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        NSColor(white: 0.78, alpha: 1).setFill()
        NSRect(x: 0, y: h * 0.9, width: w, height: h * 0.1).fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: w * 0.25, height: h * 0.9).fill()
        NSColor(white: 0.55, alpha: 1).setFill()
        for line in 0..<6 {
            NSRect(x: w * 0.32, y: h * (0.75 - CGFloat(line) * 0.1), width: w * 0.55, height: h * 0.035).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])!
        return QuickImageAttachment(data: png, mimeType: "image/png", pixelWidth: width, pixelHeight: height)
    }

    private static func file(_ name: String) -> AttachmentSource {
        .file(URL(fileURLWithPath: "/tmp/quick-launch-render-proof-files/\(name)"))
    }

    /// Ready chips of each kind. The strip scrolls, so the documents (a
    /// PDF, a deck, a workbook) and the rest (a link, a screenshot, a
    /// selection) are two proofs.
    private static func readyTray(documents: Bool) async -> AttachmentTray {
        let extractor = FakeAttachmentExtractor()
        await extractor.set(.content(AttachmentContent(
            ref: ref(.pdf, "Q3 report.pdf", bytes: 1_200_000, pages: 42), text: "report"
        )), for: "Q3 report.pdf")
        await extractor.set(.content(AttachmentContent(
            ref: ref(.powerpoint, "Launch deck.pptx", bytes: 3_400_000, pages: 12), text: "deck"
        )), for: "Launch deck.pptx")
        await extractor.set(.content(AttachmentContent(
            ref: ref(.excel, "Budget.xlsx", bytes: 88_000, pages: 3), text: "budget"
        )), for: "Budget.xlsx")
        await extractor.set(.content(AttachmentContent(
            ref: ref(.link, "Pricing | Example", url: "https://example.com/pricing"), text: "pricing"
        )), for: "https://example.com/pricing")
        let tray = AttachmentTray(extractor: extractor)
        if documents {
            tray.add(file("Q3 report.pdf"))
            tray.add(file("Launch deck.pptx"))
            tray.add(file("Budget.xlsx"))
            tray.routingLine = "Sent to DeepSeek"
        } else {
            tray.add(.link(URL(string: "https://example.com/pricing")!))
            tray.add(.image(screenshot(), name: "Screenshot", kind: .screenshot))
            tray.add(.selection("The quarter closed twelve percent up.", appName: "Safari"))
            tray.routingLine = "Only on this Mac"
        }
        await tray.waitUntilRead()
        return tray
    }

    /// The other states: reading, cut, failed, and a chip selected from
    /// the keyboard, with the notice of a refused eleventh file.
    private static func statesTray() async -> AttachmentTray {
        let extractor = FakeAttachmentExtractor()
        await extractor.hold("Board pack.pdf")
        await extractor.set(.content(AttachmentContent(
            ref: ref(
                .pdf, "Annual report 2025.pdf", bytes: 9_800_000, pages: 300,
                truncation: AttachmentTruncation(
                    keptCharacters: 200_000, totalCharacters: 612_000,
                    unit: .page, keptUnits: 120, totalUnits: 300
                )
            ),
            text: "annual"
        )), for: "Annual report 2025.pdf")
        await extractor.set(.failure("Password-protected; not read"), for: "Payroll.pdf")
        await extractor.set(.content(AttachmentContent(
            ref: ref(.markdown, "notes.md", bytes: 18_000), text: "notes"
        )), for: "notes.md")
        let tray = AttachmentTray(extractor: extractor)
        tray.add(file("Payroll.pdf"))
        tray.add(file("Annual report 2025.pdf"))
        tray.add(file("Board pack.pdf"))
        tray.add(file("notes.md"))
        tray.routingLine = "Will be cut to fit Local Models"
        // Bounded, and loud when it expires: an unbounded loop hangs the
        // suite instead of naming what never finished.
        let deadline = ContinuousClock.now + .seconds(15)
        while tray.items.filter(\.isReading).count > 1, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if tray.items.filter(\.isReading).count > 1 {
            Issue.record("the tray never settled to one reading chip")
        }
        // The keyboard on the cut chip, and a refused second copy's notice.
        tray.enterStrip()
        tray.moveFocus(-2)
        tray.add(file("Board pack.pdf"))
        return tray
    }

    // MARK: - Proofs

    @Test func rendersTheStripOnTheQuickAISurface() async throws {
        for (appearance, suffix) in Self.appearances {
            let vm = await Self.quickAI(appearance)
            let documents = await Self.readyTray(documents: true)
            #expect(documents.readyContents.count == 3)
            try Self.save(try Self.renderQuickAI(vm, tray: documents, appearance: appearance),
                          name: "att-strip-ready-quick-ai-\(suffix).png")
            let media = await Self.readyTray(documents: false)
            #expect(media.readyContents.map(\.ref.kind) == [.link, .screenshot, .selection])
            try Self.save(try Self.renderQuickAI(vm, tray: media, appearance: appearance),
                          name: "att-strip-ready-media-quick-ai-\(suffix).png")

            let states = await Self.statesTray()
            #expect(states.isReading)
            #expect(states.items[0].isFailed)
            #expect(states.notice == "Board pack.pdf is already attached.")
            try Self.save(try Self.renderQuickAI(vm, tray: states, appearance: appearance),
                          name: "att-strip-states-quick-ai-\(suffix).png")
            states.removeAll()
        }
    }

    @Test func rendersTheStripInAIChat() async throws {
        for (appearance, suffix) in Self.appearances {
            let window = await Self.aiChat(appearance)
            let documents = await Self.readyTray(documents: true)
            try Self.save(try Self.renderAIChat(window, tray: documents, appearance: appearance),
                          name: "att-strip-ready-ai-chat-\(suffix).png")
            let media = await Self.readyTray(documents: false)
            try Self.save(try Self.renderAIChat(window, tray: media, appearance: appearance),
                          name: "att-strip-ready-media-ai-chat-\(suffix).png")

            let states = await Self.statesTray()
            try Self.save(try Self.renderAIChat(window, tray: states, appearance: appearance),
                          name: "att-strip-states-ai-chat-\(suffix).png")
            states.removeAll()
        }
    }

    @Test func rendersAddContextWithSevenRowsAndTheLinkField() async throws {
        for (appearance, suffix) in Self.appearances {
            let vm = await Self.quickAI(appearance)
            vm.input = ""
            let tray = AttachmentTray(extractor: FakeAttachmentExtractor())
            tray.finderIsBehind = true
            vm.openAddContextMenu()
            #expect(AddContextPane.rows(captures: vm.addContextOptions, tray: tray).count == 7)
            try Self.save(try Self.renderQuickAI(vm, tray: tray, appearance: appearance),
                          name: "att-add-context-quick-ai-\(suffix).png")

            let window = await Self.aiChat(appearance)
            window.chat.input = ""
            window.chat.openAddContextMenu()
            try Self.save(try Self.renderAIChat(window, tray: tray, appearance: appearance),
                          name: "att-add-context-ai-chat-\(suffix).png")

            tray.beginLinkEntry(clipboard: "https://example.com/pricing")
            #expect(tray.isEnteringLink)
            try Self.save(try Self.renderQuickAI(vm, tray: tray, appearance: appearance),
                          name: "att-link-field-quick-ai-\(suffix).png")
            try Self.save(try Self.renderAIChat(window, tray: tray, appearance: appearance),
                          name: "att-link-field-ai-chat-\(suffix).png")

            tray.linkDraft = "example dot com"
            #expect(!tray.submitLinkEntry())
            try Self.save(try Self.renderQuickAI(vm, tray: tray, appearance: appearance),
                          name: "att-link-field-error-quick-ai-\(suffix).png")
        }
    }

    @Test func rendersTheDropOverlay() async throws {
        for (appearance, suffix) in Self.appearances {
            let vm = await Self.quickAI(appearance)
            let tray = AttachmentTray(extractor: FakeAttachmentExtractor())
            tray.isDropTargeted = true
            try Self.save(try Self.renderQuickAI(vm, tray: tray, appearance: appearance),
                          name: "att-drop-quick-ai-\(suffix).png")

            let window = await Self.aiChat(appearance)
            try Self.save(try Self.renderAIChat(window, tray: tray, appearance: appearance),
                          name: "att-drop-ai-chat-\(suffix).png")
        }
    }

    /// Read-only chips over a sent question, right aligned, wrapping in a
    /// narrow column.
    @Test func rendersChipsOverAQuestionPill() throws {
        for (appearance, suffix) in Self.appearances {
            let chips = [
                AttachmentChipModel(ref: Self.ref(.pdf, "Q3 report.pdf", bytes: 1_200_000, pages: 42)),
                AttachmentChipModel(ref: Self.ref(.link, "Pricing | Example", url: "https://example.com/pricing")),
                AttachmentChipModel(
                    ref: Self.ref(.screenshot, "Screenshot", pixels: (1_944, 1_464)),
                    imageData: Self.screenshot(width: 194, height: 146).data
                ),
                AttachmentChipModel(ref: Self.ref(.excel, "Budget.xlsx", bytes: 88_000, pages: 3)),
            ]
            let view = VStack(alignment: .trailing, spacing: House.Spacing.xs) {
                AttachmentPillChips(chips: chips, onOpen: { _ in })
                HouseChip(text: "Compare these")
            }
            .padding(House.Spacing.md)
            .background(House.ColorToken.surface)
            let image = try OverlayRenderProofTests.renderOnGround(
                view,
                appearance: appearance,
                width: House.Layout.answerMaxWidth
            )
            try Self.save(image, name: "att-pill-chips-\(suffix).png")
        }
    }

    // MARK: - Rendering

    private static func renderQuickAI(
        _ vm: QuickViewModel,
        tray: AttachmentTray,
        appearance: NSAppearance.Name
    ) throws -> NSImage {
        try OverlayRenderProofTests.renderOnGround(
            OverlayView(viewModel: vm, tray: tray),
            appearance: appearance,
            width: PanelSizing.panelWidth,
            height: PanelSizing.quickAIHeight + House.Spacing.xxxxl * 1.5
        )
    }

    private static func renderAIChat(
        _ model: AIChatWindowModel,
        tray: AttachmentTray,
        appearance: NSAppearance.Name
    ) throws -> NSImage {
        let size = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
        let root = AIChatWindowView(model: model)
            .environment(\.attachmentTray, tray)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw RenderError.noBitmap
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
        else { throw RenderError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }

    private enum RenderError: Error { case noBitmap }
}
