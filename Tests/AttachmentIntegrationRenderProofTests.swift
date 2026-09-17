// AttachmentIntegrationRenderProofTests: render proofs for WP-D, in both
// appearances. A thread whose question carries chips over its pill (ready
// ones, a picture from memory, and a "Not loaded" one with Re-attach); the
// thread's trim line naming the file the budget left out; and Add Context
// with all seven rows, on the 750 × 475 Quick AI surface and in the
// 860 × 620 AI Chat window. PNGs land in
// /tmp/quick-launch-render-proof/wpd-*.png.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Attachment integration render proof", .serialized)
@MainActor
struct AttachmentIntegrationRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")
    private static let appearances: [(NSAppearance.Name, String)] = [(.darkAqua, "dark"), (.aqua, "light")]
    private static let finder = SelectionTarget(processIdentifier: 7, applicationName: "Finder")

    private static func settings(_ appearance: NSAppearance.Name) -> QuickSettings {
        var settings = QuickSettings()
        settings.appearance = appearance == .darkAqua ? .dark : .light
        settings.autoCopy = false
        settings.historyEnabled = false
        // A model with no known window, so the budget has to cut.
        AttachmentFlowTests.smallWindow(&settings)
        return settings
    }

    private static func viewModel(
        _ appearance: NSAppearance.Name,
        extractor: FakeAttachmentExtractor = FakeAttachmentExtractor(),
        service: MockQuickService = MockQuickService()
    ) -> QuickViewModel {
        let vm = QuickViewModel(
            settings: settings(appearance),
            service: service,
            workspace: FakeWorkspace(),
            attachmentExtractor: extractor
        )
        vm.overlayPresenter = RecordingPresenter()
        return vm
    }

    // MARK: - A thread with chips over its pills

    /// A chat as it reads after a relaunch and one new question: the first
    /// question's report and link are loaded, its notes are not (Re-attach),
    /// and the newest question carries a screenshot held in memory.
    private static func threadWithChips(_ appearance: NSAppearance.Name) -> QuickViewModel {
        let vm = viewModel(appearance)
        let report = AttachmentFlowTests.document("Q3 report.pdf", text: "Revenue rose 12%.", pages: 42, bytes: 1_200_000)
        let link = AttachmentContent(
            ref: ChatAttachmentRef(
                kind: .link, name: "Pricing | Example", byteCount: 48_000, characterCount: 9_200,
                contentHash: "pricing", extractorVersion: 1, url: URL(string: "https://example.com/pricing")
            ),
            text: "Free, Pro, Team.",
            kindLabel: "Web page"
        )
        let notes = ChatAttachmentRef(
            kind: .word, name: "Board notes.docx", byteCount: 88_000, pageCount: 6,
            contentHash: "notes", extractorVersion: 1, path: "/tmp/Board notes.docx"
        )
        let shot = AttachmentExtractor.imageContent(
            AttachmentRenderProofTests.screenshot(width: 1_944, height: 1_464),
            name: "Screenshot",
            kind: .screenshot
        )
        vm.attachmentStore.store(report)
        vm.attachmentStore.store(link)
        vm.attachmentStore.store(shot)
        let conversation = QuickConversation(
            providerID: vm.settings.providers[0].id,
            model: "deepseek-flash",
            messages: [
                QuickMessage(role: .user, content: "Compare the report with the pricing page and the board notes",
                             attachments: [report.ref, link.ref, notes]),
                QuickMessage(role: .assistant, content: "The report puts growth at **12%**; the pricing page lists three plans. The board notes are not loaded in this session, so I left them out."),
                QuickMessage(role: .user, content: "What does this dashboard show?", attachments: [shot.ref]),
                QuickMessage(role: .assistant, content: "A settings window with six rows and a sidebar."),
            ],
            titleSource: "Compare the report with the pricing page"
        )
        vm.loadConversation(conversation)
        vm.openQuickAI()
        return vm
    }

    @Test func rendersAThreadWithChipsOverItsPills() async throws {
        for (appearance, suffix) in Self.appearances {
            let vm = Self.threadWithChips(appearance)
            let first = try #require(vm.conversationMessages.first)
            #expect(vm.attachmentChips(for: first).map(\.phase) == [.ready, .ready, .notLoaded("Not loaded")])
            #expect(vm.canReattach(first.attachmentRefs[2]))
            try Self.save(try Self.renderQuickAI(vm, appearance: appearance), name: "wpd-thread-chips-quick-ai-\(suffix).png")

            let window = AIChatWindowModel(chat: vm, defaults: Self.defaults())
            try Self.save(try Self.renderAIChat(window, appearance: appearance), name: "wpd-thread-chips-ai-chat-\(suffix).png")
        }
    }

    // MARK: - The trim line

    @Test func rendersTheTrimLineNamingTheFile() async throws {
        for (appearance, suffix) in Self.appearances {
            // A neutral follow-up is source-first: only the file this
            // question carries is in scope, so the trim line names the one
            // the budget cut, and the earlier file is not sent at all. The
            // comparison below is what asks for the earlier file back.
            let withheld = try await Self.trimmedThread(appearance, followUp: "Does the deck agree?")
            let withheldLine = try #require(withheld.line)
            #expect(withheldLine.contains("Deck.pptx"), "the carried file is named: \(withheldLine)")
            #expect(
                !withheldLine.contains("Budget.xlsx"),
                "the earlier file is withheld, not reported: \(withheldLine)"
            )
            #expect(
                withheld.request.contains(#"name="Deck.pptx""#),
                "the carried file's block rides the request"
            )
            #expect(
                !withheld.request.contains("Budget.xlsx"),
                "the withheld file is not restated on a neutral follow-up"
            )
            try Self.save(try Self.renderQuickAI(withheld.vm, appearance: appearance), name: "wpd-trim-line-quick-ai-\(suffix).png")
            let withheldWindow = AIChatWindowModel(chat: withheld.vm, defaults: Self.defaults())
            try Self.save(try Self.renderAIChat(withheldWindow, appearance: appearance), name: "wpd-trim-line-ai-chat-\(suffix).png")

            // Naming the earlier file brings the history back into scope: it
            // is in the request again, where the neutral follow-up dropped it
            // entirely. The budget then stubs it, least wanted source first,
            // and the trim line says so.
            let compared = try await Self.trimmedThread(
                appearance,
                followUp: "Compare the deck with Budget.xlsx"
            )
            let comparedLine = try #require(compared.line)
            #expect(comparedLine.contains("Budget.xlsx"), "the named history is named: \(comparedLine)")
            #expect(
                compared.request.contains("Budget.xlsx"),
                "the requested earlier file is in the request, not dropped"
            )
            #expect(
                compared.request.contains(#"name="Deck.pptx""#),
                "the current source still rides the request"
            )
            try Self.save(try Self.renderQuickAI(compared.vm, appearance: appearance), name: "wpd-trim-line-compared-quick-ai-\(suffix).png")
            let comparedWindow = AIChatWindowModel(chat: compared.vm, defaults: Self.defaults())
            try Self.save(try Self.renderAIChat(comparedWindow, appearance: appearance), name: "wpd-trim-line-compared-ai-chat-\(suffix).png")
        }
    }

    /// Two files read into one chat: Budget.xlsx on the first question, then
    /// Deck.pptx on `followUp`, whose window geometry cuts the shared budget.
    /// Returns the trim line the thread shows, and the last request the
    /// service saw (the composed user turn with its attachment blocks).
    private static func trimmedThread(
        _ appearance: NSAppearance.Name,
        followUp: String
    ) async throws -> (vm: QuickViewModel, line: String?, request: String) {
        let extractor = FakeAttachmentExtractor()
        let big = String(repeating: "Budget line. ", count: 3_000)
        await extractor.set(.content(AttachmentFlowTests.document("Budget.xlsx", text: big, pages: 3)), for: "Budget.xlsx")
        await extractor.set(.content(AttachmentFlowTests.document("Deck.pptx", text: big, pages: 12)), for: "Deck.pptx")
        let service = MockQuickService()
        let vm = Self.viewModel(appearance, extractor: extractor, service: service)
        vm.openQuickAI()
        vm.attachmentTray.add(.file(AttachmentFlowTests.file("Budget.xlsx")))
        await vm.attachmentTray.waitUntilRead()
        await service.setResponses([StreamDelta(text: "The budget holds **four** teams.", finishReason: "stop")])
        vm.input = "What does the budget cover?"
        await vm.submit()
        vm.attachmentTray.add(.file(AttachmentFlowTests.file("Deck.pptx")))
        await vm.attachmentTray.waitUntilRead()
        await service.setResponses([StreamDelta(text: "The deck rounds growth to 10%; the budget has the detail by team.", finishReason: "stop")])
        vm.input = followUp
        await vm.submit()
        return (
            vm,
            vm.conversationMessages.last?.tools.first { $0.kind == .context }?.summary,
            await service.lastPrompt ?? ""
        )
    }

    // MARK: - Add Context with every row

    @Test func rendersAddContextWithAllSevenRows() async throws {
        for (appearance, suffix) in Self.appearances {
            let vm = Self.viewModel(appearance)
            vm.rememberSelectionTarget(Self.finder)
            vm.openQuickAI()
            vm.openAddContextMenu()
            #expect(vm.addContextRows.count == 7)
            try Self.save(try Self.renderQuickAI(vm, appearance: appearance), name: "wpd-add-context-quick-ai-\(suffix).png")

            let chat = Self.viewModel(appearance)
            let window = AIChatWindowModel(chat: chat, defaults: Self.defaults())
            chat.rememberSelectionTarget(Self.finder)
            chat.openQuickAI()
            chat.openAddContextMenu()
            #expect(chat.addContextRows.count == 7)
            try Self.save(try Self.renderAIChat(window, appearance: appearance), name: "wpd-add-context-ai-chat-\(suffix).png")
        }
    }

    // MARK: - Rendering

    private static func defaults() -> UserDefaults {
        let suite = "AttachmentIntegrationRenderProofTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func renderQuickAI(_ vm: QuickViewModel, appearance: NSAppearance.Name) throws -> NSImage {
        try OverlayRenderProofTests.renderOnGround(
            OverlayView(viewModel: vm),
            appearance: appearance,
            width: PanelSizing.panelWidth,
            height: PanelSizing.quickAIHeight + House.Spacing.xxxxl * 1.5
        )
    }

    private static func renderAIChat(_ model: AIChatWindowModel, appearance: NSAppearance.Name) throws -> NSImage {
        let size = NSSize(width: House.Layout.chatWidth, height: House.Layout.chatHeight)
        let root = AIChatWindowView(model: model).frame(width: size.width, height: size.height)
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
