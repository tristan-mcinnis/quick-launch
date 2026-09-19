// ChatContextRenderProofTests — visual proof for the chat context surfaces
// added by the approved harmonisation plan, in both appearances, written to
// /tmp/quick-launch-render-proof/ with stable file names:
//   chat-context-composer-min-{dark,light}.png   the pre-Send controls on the
//                                                composer at the minimum chat
//                                                size: "Attached sources",
//                                                the source summary and the
//                                                destination
//   chat-context-broader-search-{dark,light}.png the same composer after
//                                                Broader search is chosen
//   chat-context-send-as-text-{dark,light}.png   a refused slash command and
//                                                the explicit Send as Text
//                                                action
//   chat-context-receipt-{dark,light}.png        the compact answer detail
//   chat-context-receipt-expanded-{dark,light}.png  the opened receipt:
//                                                route, reasoning, reading,
//                                                timings and usage
//   chat-context-materials-min-{dark,light}.png  retained, partial and
//                                                missing materials at the
//                                                minimum chat size
//   chat-context-destination-{dark,light}.png    the resolved route as a
//                                                statement
//   chat-context-destination-warning-{dark,light}.png  a route that cannot
//                                                run: the warning owns the
//                                                line, the destination is
//                                                the explanation
//
// The whole run is offscreen: no window is shown, no preference or archive
// file is touched, and the fixture record is built in memory.

import AppKit
import Foundation
import HouseChatCore
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("Chat context render proof", .serialized)
@MainActor
struct ChatContextRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    private static let conversationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private static let questionID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let answerID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private static func appearances() -> [(NSAppearance.Name, String)] {
        [(.darkAqua, "dark"), (.aqua, "light")]
    }

    private static func makeViewModel(_ appearance: NSAppearance.Name) -> QuickViewModel {
        var settings = QuickSettings()
        settings.appearance = appearance == .darkAqua ? .dark : .light
        settings.autoCopy = false
        settings.historyEnabled = true
        settings.launcherLearningEnabled = false
        return QuickViewModel(settings: settings, service: MockQuickService(), pasteboard: FakePasteboard())
    }

    // MARK: - Pre-Send controls

    @Test func rendersThePreSendControlsAtTheMinimumChatSize() throws {
        for (appearance, suffix) in Self.appearances() {
            let viewModel = Self.makeViewModel(appearance)
            viewModel.input = ""
            // A question whose answer must come from the material already on
            // the chat: the broad tools are withheld, so the control says so.
            viewModel.currentConversation = Self.groundedConversation()
            #expect(viewModel.contextScopeLabel == "Attached sources")
            #expect(viewModel.contextScopeOffersWidening)
            #expect(viewModel.contextScopeDetail.contains("withheld"))
            #expect(viewModel.attachedSourceSummary == "brief.pdf")

            try Self.save(
                try Self.renderComposer(viewModel, appearance: appearance),
                name: "chat-context-composer-min-\(suffix).png"
            )
        }
    }

    @Test func rendersTheBroaderSearchChoice() throws {
        for (appearance, suffix) in Self.appearances() {
            let viewModel = Self.makeViewModel(appearance)
            viewModel.currentConversation = Self.groundedConversation()
            viewModel.toggleContextScope()
            #expect(viewModel.contextOverride == .broader)
            #expect(viewModel.contextScopeLabel == "Broader search")
            #expect(viewModel.contextScopeDetail.contains("allowed"))

            try Self.save(
                try Self.renderComposer(viewModel, appearance: appearance),
                name: "chat-context-broader-search-\(suffix).png"
            )
        }
    }

    @Test func rendersTheSendAsTextActionForARefusedCommand() async throws {
        for (appearance, suffix) in Self.appearances() {
            let viewModel = Self.makeViewModel(appearance)
            viewModel.input = "/summarise the plan"
            _ = await viewModel.prepareRequest()
            #expect(viewModel.refusedCommandText == "/summarise the plan")
            #expect(viewModel.input == "/summarise the plan")
            #expect(viewModel.errorMessage != nil)

            try Self.save(
                try Self.renderComposer(viewModel, appearance: appearance),
                name: "chat-context-send-as-text-\(suffix).png"
            )
        }
    }

    // MARK: - Answer detail

    @Test func rendersTheAnswerReceipt() throws {
        for (appearance, suffix) in Self.appearances() {
            let summary = Self.fixtureSummary()
            #expect(summary.hasReceipt)
            #expect(summary.reasoning == "Reasoning high")
            #expect(summary.route.contains("deepseek-chat"))
            #expect(summary.route.contains("fell back from deepseek-reasoner"))
            #expect(summary.context.contains("Attached sources"))
            #expect(summary.context.contains("3 chunks"))
            #expect(summary.timings?.contains("12.4 s") == true)
            #expect(summary.usage == "1,204 in · 388 out")
            #expect(summary.materials.count == 3)

            try Self.save(
                try Self.renderRecord(summary, expanded: false, appearance: appearance),
                name: "chat-context-receipt-\(suffix).png"
            )
            try Self.save(
                try Self.renderRecord(summary, expanded: true, appearance: appearance),
                name: "chat-context-receipt-expanded-\(suffix).png"
            )
        }
    }

    @Test func rendersRetainedPartialAndMissingMaterialsAtTheMinimumChatSize() throws {
        for (appearance, suffix) in Self.appearances() {
            let summary = Self.fixtureSummary()
            let statuses = summary.materials.map(\.status)
            #expect(statuses == [.retained, .partial, .missing])
            #expect(summary.materials[0].detail.contains("no image as sent"))
            #expect(summary.materials[1].detail.contains("no original file"))
            #expect(summary.materials[2].detail.contains("no original file, image as sent, extracted text"))
            #expect(summary.materials[2].hasBytes == false)

            try Self.save(
                try Self.renderRecord(summary, expanded: true, appearance: appearance),
                name: "chat-context-materials-min-\(suffix).png"
            )
        }
    }

    // MARK: - Pure summaries

    @Test func aDamagedExtractionIsNamedRatherThanCalledPresent() {
        let textRef = ArtifactRef(
            kind: .extractedText,
            sha256: String(repeating: "b", count: 64),
            byteCount: 9_000,
            fileExtension: "json"
        )
        let material = ChatRetainedMaterial(source: RetainedSource(
            attachment: AttachmentRecord(
                id: "77777777-7777-7777-7777-777777777777",
                kind: .pdf,
                name: "brief.pdf",
                artifacts: AttachmentArtifacts(extractedText: textRef)
            ),
            original: nil,
            normalizedImage: nil,
            extractedText: textRef,
            missingRoles: ["original", "normalizedImage"],
            damagedRoles: ["extractedText"]
        ))
        #expect(material.hasBytes, "the bytes are archived")
        #expect(material.status == .partial, "the extraction cannot be used, so it is not fully retained")
        #expect(material.detail.contains("extracted text unreadable"))
    }

    @Test func formatsDurationsForTheReceipt() {
        #expect(ChatAnswerReceiptSummary.duration(0.8) == "0.80 s")
        #expect(ChatAnswerReceiptSummary.duration(12.4) == "12.4 s")
        #expect(ChatAnswerReceiptSummary.duration(64) == "1 m 04 s")
    }

    @Test func saysSoWhenThereIsNoReceipt() {
        let answer = TurnRecord(id: Self.answerID.uuidString, role: .assistant, text: "Answer.")
        let summary = ChatAnswerReceiptSummary(
            answer: answer,
            question: nil,
            projection: .unavailable
        )
        #expect(summary.hasReceipt == false)
        #expect(summary.route == "No route recorded")
        #expect(summary.context == "No reading recorded")
        #expect(summary.timings == nil)
        #expect(summary.materials.isEmpty)
    }

    // MARK: - Destination presentation (view only)

    // The view derives its line from the resolved route alone. These prove
    // the presentation contract; parity between the resolved route and what
    // the send path actually uses is the pipeline worker's test.

    @Test func presentsAResolvedCloudRouteAsAStatement() {
        let destination = ChatDestination(label: "Sent to DeepSeek", isCloud: true, warning: nil)
        let presentation = destination.presentation
        #expect(presentation.primary == "Sent to DeepSeek")
        #expect(presentation.secondary == nil)
        #expect(presentation.symbol == "cloud")
        #expect(presentation.isWarning == false)
        #expect(presentation.accessibilityLabel == "Destination: Sent to DeepSeek")
    }

    @Test func presentsAResolvedLocalRouteOnTheMac() {
        let destination = ChatDestination(label: "Only on this Mac", isCloud: false, warning: nil)
        #expect(destination.presentation.primary == "Only on this Mac")
        #expect(destination.presentation.symbol == "desktopcomputer")
        #expect(destination.presentation.isWarning == false)
    }

    /// A tray image and an image kept from an earlier turn arrive as the
    /// same resolved route, so the line is identical. The view carries no
    /// scan of its own for pending, reasked or thread images.
    @Test func readsATrayImageAndARetainedImageTheSameWay() {
        let trayImage = ChatDestination(label: "Sent to DeepSeek", isCloud: true, warning: nil)
        let retainedImage = ChatDestination(label: "Sent to DeepSeek", isCloud: true, warning: nil)
        #expect(trayImage.presentation == retainedImage.presentation)
    }

    /// The route cannot run: the warning owns the line and the destination is
    /// demoted to the explanation, in warning ink, with the warning carried in
    /// the accessibility label too.
    @Test func presentsAnUnusableRouteHonestly() throws {
        for (appearance, suffix) in Self.appearances() {
            let warning = "Screenshots will be read on this Mac; the chat model answers the text"
            let destination = ChatDestination(
                label: "Sent to DeepSeek",
                isCloud: true,
                warning: warning
            )
            let presentation = destination.presentation
            #expect(presentation.isWarning)
            #expect(presentation.primary == warning)
            #expect(presentation.secondary == "Sent to DeepSeek")
            #expect(presentation.symbol == "exclamationmark.triangle")
            #expect(presentation.accessibilityLabel.hasPrefix("Route warning:"))
            #expect(presentation.accessibilityLabel.contains("Sent to DeepSeek"))

            try Self.save(
                try Self.renderDestination(
                    ChatDestination(label: "Sent to DeepSeek", isCloud: true, warning: nil),
                    appearance: appearance
                ),
                name: "chat-context-destination-\(suffix).png"
            )
            try Self.save(
                try Self.renderDestination(destination, appearance: appearance),
                name: "chat-context-destination-warning-\(suffix).png"
            )
        }
    }

    // MARK: - Fixture

    private static func groundedConversation() -> QuickConversation {
        QuickConversation(
            id: Self.conversationID,
            providerID: InferenceProvider.deepSeekID,
            model: InferenceProvider.deepSeekDefaultModel,
            messages: [
                QuickMessage(
                    id: Self.questionID,
                    role: .user,
                    content: "Walk me through the brief",
                    attachments: [
                        ChatAttachmentRef(
                            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                            kind: .pdf,
                            name: "brief.pdf",
                            byteCount: 42_000,
                            characterCount: 12_400
                        )
                    ]
                ),
                QuickMessage(id: Self.answerID, role: .assistant, content: "Three parts."),
            ]
        )
    }

    /// One chat with a completed answer, its frozen route and receipt, and
    /// three sources: retained, partial, and missing.
    private static func projection() -> ChatArchiveProjection {
        let fileRef = ArtifactRef(
            kind: .original,
            sha256: String(repeating: "a", count: 64),
            byteCount: 42_000,
            fileExtension: "pdf"
        )
        let textRef = ArtifactRef(
            kind: .extractedText,
            sha256: String(repeating: "b", count: 64),
            byteCount: 9_000,
            fileExtension: "txt"
        )

        var retained = AttachmentRecord(
            id: "44444444-4444-4444-4444-444444444444",
            kind: .pdf,
            name: "brief.pdf",
            byteCount: 42_000,
            characterCount: 12_400,
            artifacts: AttachmentArtifacts(original: fileRef, extractedText: textRef)
        )
        retained.contentHash = String(repeating: "a", count: 64)

        let partial = AttachmentRecord(
            id: "55555555-5555-5555-5555-555555555555",
            kind: .pdf,
            name: "annex.pdf",
            byteCount: 88_000,
            characterCount: 3_000,
            truncation: TextTruncation(
                keptCharacters: 3_000,
                totalCharacters: 40_000,
                unit: .page,
                keptUnits: 4,
                totalUnits: 52
            ),
            artifacts: AttachmentArtifacts(extractedText: textRef)
        )

        let missing = AttachmentRecord(
            id: "66666666-6666-6666-6666-666666666666",
            kind: .excel,
            name: "grid.xlsx",
            byteCount: 21_000,
            characterCount: 7_000,
            artifacts: nil
        )

        let question = TurnRecord(
            id: Self.questionID.uuidString,
            role: .user,
            text: "Walk me through the brief",
            attachments: [retained, partial, missing]
        )
        let answer = TurnRecord(
            id: Self.answerID.uuidString,
            role: .assistant,
            text: "Three parts.",
            model: ModelSelection(
                chosen: ModelChoice(provider: "DeepSeek", model: "deepseek-reasoner", thinking: "high"),
                effective: ModelChoice(provider: "DeepSeek", model: "deepseek-chat", thinking: "high")
            ),
            request: RequestReceipt(
                selection: ModelSelection(
                    chosen: ModelChoice(provider: "DeepSeek", model: "deepseek-reasoner", thinking: "high"),
                    effective: ModelChoice(provider: "DeepSeek", model: "deepseek-chat", thinking: "high")
                ),
                status: .completed,
                context: ContextReceipt(
                    scope: .currentSource,
                    sourceFirst: true,
                    historyIncluded: false,
                    budgetCharacters: 200_000,
                    sourceCharacters: 12_400,
                    coverageLabels: ["page 1", "page 2", "page 3"],
                    matched: true,
                    complete: false,
                    rationale: "source-first"
                ),
                timings: RequestTimings(
                    totalSeconds: 12.4,
                    firstTokenSeconds: 1.2,
                    toolSeconds: 0.4,
                    retrievalSeconds: 0.9,
                    extractionSeconds: 2.1
                ),
                usage: TokenUsage(inputTokens: 1_204, outputTokens: 388)
            )
        )

        return ChatArchiveProjection(
            record: ConversationRecord(
                id: Self.conversationID.uuidString,
                surface: .quickLaunch,
                title: "Brief",
                turns: [question, answer]
            ),
            sources: [
                RetainedSource(
                    attachment: retained,
                    original: fileRef,
                    normalizedImage: nil,
                    extractedText: textRef,
                    missingRoles: ["normalizedImage"]
                ),
                RetainedSource(
                    attachment: partial,
                    original: nil,
                    normalizedImage: nil,
                    extractedText: textRef,
                    missingRoles: ["original", "normalizedImage"]
                ),
                RetainedSource(
                    attachment: missing,
                    original: nil,
                    normalizedImage: nil,
                    extractedText: nil,
                    missingRoles: ["original", "normalizedImage", "extractedText"]
                ),
            ],
            usage: ChatArchiveUsage(conversationCount: 3, damagedConversationCount: 0, artifactBytes: 120_000),
            loadFailure: nil
        )
    }

    private static func fixtureSummary() -> ChatAnswerReceiptSummary {
        let projection = Self.projection()
        return ChatAnswerReceiptSummary(
            answer: projection.turn(Self.answerID)!,
            question: projection.turn(Self.questionID),
            projection: projection
        )
    }

    // MARK: - Rendering

    /// The composer at the minimum chat size: the narrowest the AI Chat
    /// window may be. Its own height is measured, so nothing is clipped.
    private static func renderComposer(_ viewModel: QuickViewModel, appearance: NSAppearance.Name) throws -> NSImage {
        let width = House.Layout.chatMinWidth
        let root = VStack(spacing: 0) {
            QuickAIComposer(viewModel: viewModel, multiline: true)
            Spacer(minLength: 0)
        }
        .frame(width: width)
        .background(House.ColorToken.surface)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        let fitting = host.fittingSize
        #expect(fitting.width <= width + 1)
        #expect(fitting.height > House.Control.pill)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(120, fitting.height)))
        host.layoutSubtreeIfNeeded()
        return try snapshot(host)
    }

    /// The answer detail at the minimum chat size, on the window's ground.
    private static func renderRecord(
        _ summary: ChatAnswerReceiptSummary,
        expanded: Bool,
        appearance: NSAppearance.Name
    ) throws -> NSImage {
        let width = House.Layout.chatMinWidth
        let root = VStack(alignment: .leading, spacing: 0) {
            ChatAnswerContextRecord(summary: summary, initiallyExpanded: expanded)
            Spacer(minLength: 0)
        }
        .padding(House.Spacing.lg)
        .frame(width: width, alignment: .leading)
        .background(House.ColorToken.surface)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(120, host.fittingSize.height)))
        host.layoutSubtreeIfNeeded()
        return try snapshot(host)
    }

    /// The destination line alone at the minimum chat size.
    private static func renderDestination(
        _ destination: ChatDestination,
        appearance: NSAppearance.Name
    ) throws -> NSImage {
        let width = House.Layout.chatMinWidth
        let root = HStack(spacing: House.Spacing.xs) {
            ChatDestinationLabel(destination: destination)
            Spacer(minLength: 0)
        }
        .padding(House.Spacing.lg)
        .frame(width: width)
        .background(House.ColorToken.surface)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: House.Control.pill))
        host.layoutSubtreeIfNeeded()
        return try snapshot(host)
    }

    private static func snapshot(_ host: NSView) throws -> NSImage {
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
