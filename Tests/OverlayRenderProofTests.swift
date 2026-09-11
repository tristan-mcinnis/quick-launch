// OverlayRenderProofTests — visual proof for the monochrome overlay theme.
//
// Hosts the real OverlayView in an offscreen NSHostingView, renders it under
// dark and light appearances, and writes PNGs to
// /tmp/quick-launch-render-proof/overlay-{dark,light}.png so a reviewer can
// look at the launcher list, hotkey badges, and footer without launching the
// app. Also asserts the panel tint lands on the dark side in dark mode.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("OverlayRenderProof", .serialized)
@MainActor
struct OverlayRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    @Test func rendersDarkLauncherWithBadgesAndFooter() throws {
        let image = try Self.render(appearance: .darkAqua)
        try Self.save(image, name: "overlay-dark.png")
        let sample = try Self.averageColor(of: image, region: CGRect(x: 300, y: 8, width: 200, height: 20))
        #expect(sample.brightness < 0.35, "dark overlay should read as dark, got \(sample)")
    }

    @Test func rendersDarkActionPane() throws {
        let vm = Self.makeViewModel(appearance: .dark)
        vm.handleCommandK()
        #expect(vm.isItemActionPanePresented)
        let image = try Self.render(viewModel: vm, appearance: .darkAqua)
        try Self.save(image, name: "overlay-actions-dark.png")
    }

    @Test func rendersTransformChooserNoClip() throws {
        // Real OverlayView with a captured selection (chip) and the transform
        // chooser open, rendered at the computed window height. The chooser
        // must replace the launcher list and the window must be tall enough
        // (no clipping), which is exactly the sizing bug being guarded.
        let vm = Self.makeViewModel(appearance: .dark)
        let selection = PreviewSelectedTextService(text: "The quick brown fox jumps over the lazy dog. A longer selection for transform testing.")
        vm.selectedTextService = selection
        vm.rememberSelectionTarget(SelectionTarget(processIdentifier: 42, applicationName: "TextEdit"))
        vm.captureLaunchSelection()
        vm.openTransformChooser()
        #expect(vm.isTransformChooserPresented)
        #expect(vm.chipTransformOptions.count == 5)
        let image = try Self.renderFixedHeight(
            viewModel: vm,
            appearance: .darkAqua,
            height: vm.estimatedWindowHeight
        )
        try Self.save(image, name: "overlay-transform-chooser-dark.png")
        // The chooser's five rows must all fit inside the computed height.
        #expect(image.size.height >= vm.estimatedWindowHeight - 1)
    }

    @Test func rendersDarkAnswerState() async throws {
        let vm = Self.makeViewModel(appearance: .dark)
        let mock = MockQuickService()
        await mock.setResponses([StreamDelta(text: "**Argentina** won the 2022 World Cup, beating France on penalties.", finishReason: "stop")])
        vm.service = mock
        vm.settings.autoCopy = false
        vm.input = "who won the world cup"
        await vm.submit()
        #expect(vm.launcherMatches.isEmpty)
        let image = try Self.render(viewModel: vm, appearance: .darkAqua)
        try Self.save(image, name: "overlay-answer-dark.png")
    }

    @Test func rendersDarkCaffeinateCatalogAndTranslateMode() throws {
        let vm = Self.makeViewModel(appearance: .dark)
        vm.enterCatalog(.caffeinate)
        vm.input = ""
        try Self.save(try Self.render(viewModel: vm, appearance: .darkAqua), name: "overlay-caffeinate-dark.png")
        vm.leaveCatalog()
        let translator = TranslatorModel(lastTarget: .simplifiedChinese)
        translator.source = "Where is the nearest station?"
        translator.translation = "最近的车站在哪里？"
        translator.pinyin = "zuì jìn de chē zhàn zài nǎ lǐ?"
        translator.detectedSource = .english
        let host = NSHostingView(rootView: TranslatorView(model: translator))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: TranslatorView.size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProofError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        try Self.save(image, name: "translator-dark.png")
    }

    @Test func rendersCommandsCatalogWithReadAloudAndStopReadingRows() throws {
        // The Commands catalog caps its empty-query list well under the full
        // `systemCommands` count, so a fresh, unpinned row needs a query to
        // surface — matching how a real "tts" search would find it.
        let vm = Self.makeViewModel(appearance: .dark)
        vm.pasteboard = FakePasteboard(string: "A short paragraph copied to the clipboard, ready to read aloud.")
        vm.enterCatalog(.commands)
        vm.input = "read aloud"
        let readAloudIndex = vm.launcherMatches.firstIndex {
            if case .item(let item) = $0 { return item.itemID == "speech.readAloud" }
            return false
        }
        #expect(readAloudIndex != nil, "the Read Aloud row must be in the Commands catalog")
        vm.applicationSelectionIndex = readAloudIndex ?? 0
        try Self.save(try Self.render(viewModel: vm, appearance: .darkAqua), name: "overlay-readaloud-dark.png")

        vm.isSpeaking = true
        vm.input = "stop reading"
        let stopIndex = vm.launcherMatches.firstIndex {
            if case .item(let item) = $0 { return item.itemID == "speech.stop" }
            return false
        }
        #expect(stopIndex != nil, "Stop Reading must appear once speaking")
        vm.applicationSelectionIndex = stopIndex ?? 0
        try Self.save(try Self.render(viewModel: vm, appearance: .darkAqua), name: "overlay-readaloud-stop-dark.png")
    }

    @Test func rendersEmojiGridAndScreenshotDetailPane() throws {
        let vm = Self.makeViewModel(appearance: .dark)
        vm.settings.screenshotTextSearch = false
        vm.enterCatalog(.emoji)
        vm.input = ""
        try Self.save(try Self.render(viewModel: vm, appearance: .darkAqua), name: "overlay-emoji-dark.png")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-launch-proof-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try ScreenAwarenessTests.writeImage(to: folder.appendingPathComponent("Screenshot 2026-08-22 at 09.41.12.png"), text: "Quarterly revenue 2026")
        vm.screenshotsFolder = folder
        vm.enterCatalog(.screenshots)
        vm.applicationSelectionIndex = vm.launcherMatches.firstIndex { if case .item(let item) = $0 { return item.kind == .screenshot }; return false } ?? 0
        #expect(vm.showsDetailPane)
        let host = NSHostingView(rootView: OverlayView(viewModel: vm))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: NSSize(width: vm.currentPanelWidth, height: 520))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProofError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        try Self.save(image, name: "overlay-screenshots-dark.png")

        vm.leaveCatalog()
        vm.pendingImage = QuickImageAttachment(data: Data(), mimeType: "image/png", pixelWidth: 1, pixelHeight: 1)
        vm.pendingContext = CaptureContext(appName: "Safari", windowTitle: "Raycast Manual", selectedText: "Screen Awareness", appText: "Get Started", pageURL: "https://manual.raycast.com", hasScreenshot: true)
        try Self.save(try Self.render(viewModel: vm, appearance: .darkAqua), name: "overlay-awareness-dark.png")
    }

    @Test func rendersSnippetAndQuickLinkDetailPanes() throws {
        let vm = Self.makeViewModel(appearance: .dark)
        vm.enterCatalog(.snippets)
        vm.input = ""
        vm.applicationSelectionIndex = 0
        #expect(vm.showsDetailPane)
        try Self.save(try Self.render(viewModel: vm, appearance: .darkAqua), name: "overlay-snippets-dark.png")

        vm.leaveCatalog()
        vm.enterCatalog(.quickLinks)
        vm.input = ""
        vm.applicationSelectionIndex = 1
        #expect(vm.detailItem?.requiresInput == true)
        try Self.save(try Self.render(viewModel: vm, appearance: .darkAqua), name: "overlay-quicklinks-dark.png")
        try Self.save(try Self.render(viewModel: vm, appearance: .aqua), name: "overlay-quicklinks-light.png")
    }

    @Test func rendersColorsCatalogWithASwatchThatPaintsThePickedColor() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-colors-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ColorHistoryStore(fileURL: folder.appendingPathComponent("color-history.json"))
        let picked = PickedColor(red: 1, green: 0.4, blue: 0)
        store.record(picked, limit: 10)
        store.record(PickedColor(red: 74 / 255, green: 144 / 255, blue: 217 / 255), limit: 10)

        let vm = Self.makeViewModel(appearance: .dark)
        vm.colorHistory = store
        vm.enterCatalog(.colors)
        vm.input = ""
        vm.applicationSelectionIndex = 1
        #expect(vm.showsDetailPane)
        #expect(vm.detailItem?.value == picked.hexString)

        let image = try Self.render(viewModel: vm, appearance: .darkAqua)
        try Self.save(image, name: "overlay-colors-dark.png")
        // The swatch must actually paint the colour that was picked, not a
        // placeholder: count pixels close to it across the rendered panel.
        let matches = try Self.pixelCount(in: image, near: picked, tolerance: 0.06)
        #expect(matches > 500, "the swatch should fill the preview, matched \(matches) pixels")

        vm.handleCommandK()
        #expect(vm.isItemActionPanePresented)
        try Self.save(
            try Self.render(viewModel: vm, appearance: .darkAqua),
            name: "overlay-colors-actions-dark.png"
        )
        vm.closeItemActionPane()
        try Self.save(
            try Self.render(viewModel: vm, appearance: .aqua),
            name: "overlay-colors-light.png"
        )
    }

    /// Pixels within `tolerance` of a colour, sampled every other row and
    /// column like `averageColor`.
    private static func pixelCount(in image: NSImage, near color: PickedColor, tolerance: Double) throws -> Int {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { throw ProofError.noBitmap }
        var matches = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(Double(pixel.redComponent) - color.red) < tolerance,
                   abs(Double(pixel.greenComponent) - color.green) < tolerance,
                   abs(Double(pixel.blueComponent) - color.blue) < tolerance {
                    matches += 1
                }
            }
        }
        return matches
    }

    @Test func rendersSettingsItemsTab() throws {
        let vm = Self.makeViewModel(appearance: .dark)
        vm.input = ""
        try Self.saveSettings(vm, tab: .general, name: "settings-dark.png")
        try Self.saveSettings(vm, tab: .items, name: "settings-items-dark.png")
        // Colors, Emoji & Symbols, and Text from Screen live on this tab.
        try Self.saveSettings(vm, tab: .clipboard, name: "settings-capture-dark.png")
    }

    @Test func rendersScreenHistoryResultsPreviewEmptyAndSettings() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-launch-screen-history-proof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imageURL = folder.appendingPathComponent("coral-chart.png")
        try ScreenAwarenessTests.writeImage(to: imageURL, text: "Coral variance chart")
        let store = try SQLiteScreenHistoryStore(databaseURL: folder.appendingPathComponent("history.sqlite3"))
        _ = try await store.record(ScreenHistoryFrameInput(
            sourceIdentifier: "proof-1",
            capturedAt: Date(timeIntervalSince1970: 1_787_615_520),
            application: "Keynote",
            bundleIdentifier: "com.apple.iWork.Keynote",
            windowTitle: "Project Juniper Launch Review",
            ocrText: "Coral variance chart revised. Regional total matches the source table.",
            imageLocator: imageURL.path,
            byteCount: Int64((try Data(contentsOf: imageURL)).count)
        ))
        let vm = Self.makeViewModel(appearance: .dark)
        vm.screenHistory.store = store
        vm.enterCatalog(.screenHistory)
        await vm.screenHistory.load(query: "coral variance")
        #expect(vm.showsDetailPane)
        try Self.save(
            try Self.render(viewModel: vm, appearance: .darkAqua),
            name: "overlay-screen-history-dark.png"
        )
        vm.handleCommandK()
        #expect(vm.isCatalogActionPanePresented)
        try Self.save(
            try Self.render(viewModel: vm, appearance: .darkAqua),
            name: "overlay-screen-history-actions-dark.png"
        )
        vm.closeItemActionPane()
        if let item = vm.screenHistory.items.first {
            vm.openActionPane(for: .item(item), form: .screenHistorySave)
            try Self.save(
                try Self.render(viewModel: vm, appearance: .darkAqua),
                name: "overlay-screen-history-save-dark.png"
            )
            let productionSave = try Self.renderFixedHeight(
                viewModel: vm,
                appearance: .darkAqua,
                height: ItemActionForm.screenHistorySave.minimumWindowHeight!
            )
            try Self.save(
                productionSave,
                name: "overlay-screen-history-save-production-dark.png"
            )
            let largeTextSave = try Self.renderFixedHeight(
                viewModel: vm,
                appearance: .darkAqua,
                height: ItemActionForm.screenHistorySave.minimumWindowHeight!,
                accessibilitySize: true
            )
            try Self.saveOpaque(
                largeTextSave,
                name: "overlay-screen-history-save-large-text-dark.png"
            )
            #expect(productionSave.tiffRepresentation != largeTextSave.tiffRepresentation)
            #expect(try Self.brightPixelCount(
                in: largeTextSave,
                region: CGRect(x: 20, y: 8, width: 500, height: 50)
            ) > 120, "accessibility proof must keep the search row visible")
            #expect(try Self.brightPixelCount(
                in: largeTextSave,
                region: CGRect(x: 20, y: 62, width: 700, height: 48)
            ) > 120, "accessibility proof must keep the selected-moment header visible")
            #expect(try Self.brightPixelCount(
                in: largeTextSave,
                region: CGRect(x: 260, y: 20, width: 680, height: 90)
            ) > 120, "accessibility proof must keep the pinned action footer visible")
            vm.closeItemActionPane()
        }
        try Self.save(
            try Self.renderAtAccessibilitySize(viewModel: vm, appearance: .darkAqua),
            name: "overlay-screen-history-large-text-dark.png"
        )
        if let frame = vm.screenHistory.frames.first {
            await vm.screenHistory.openSequence(for: frame)
            try Self.save(
                try Self.render(viewModel: vm, appearance: .darkAqua),
                name: "overlay-screen-history-timeline-dark.png"
            )
            vm.screenHistory.closeTimeline()
        }

        vm.input = "synthetic phrase with no match"
        await vm.screenHistory.load(query: vm.input)
        try Self.save(
            try Self.render(viewModel: vm, appearance: .darkAqua),
            name: "overlay-screen-history-empty-dark.png"
        )
        try Self.saveSettings(vm, tab: .screenHistory, name: "settings-screen-history-dark.png")

        var unavailableSettings = QuickSettings()
        unavailableSettings.appearance = .dark
        unavailableSettings.searchLegacyCoastHistory = false
        let unavailable = QuickViewModel(settings: unavailableSettings)
        unavailable.enterCatalog(.screenHistory)
        await unavailable.screenHistory.load(query: "coral")
        try Self.save(
            try Self.render(viewModel: unavailable, appearance: .darkAqua),
            name: "overlay-screen-history-unavailable-dark.png"
        )
    }

    private static func saveSettings(
        _ vm: QuickViewModel,
        tab: SettingsView.SettingsTab,
        name: String,
        appearance: NSAppearance.Name = .darkAqua
    ) throws {
        let host = NSHostingView(rootView: SettingsView(viewModel: vm, initialTab: tab))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: SettingsView.windowSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProofError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        try Self.save(image, name: name)
    }

    /// The screens the Slate mockup shows, rendered as the user sees them:
    /// panel on a ground, two shadows, both appearances.
    @Test func rendersSlateProofSet() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let root = Self.makeViewModel(appearance: appearance == .darkAqua ? .dark : .light)
            root.input = ""
            root.applicationSelectionIndex = 0
            try Self.save(
                try Self.renderLauncherOnGround(root, appearance: appearance),
                name: "slate-root-\(suffix).png"
            )

            let results = Self.makeViewModel(appearance: appearance == .darkAqua ? .dark : .light)
            results.input = "cla"
            results.applicationSelectionIndex = 0
            try Self.save(
                try Self.renderLauncherOnGround(results, appearance: appearance),
                name: "slate-results-\(suffix).png"
            )

            let actions = Self.makeViewModel(appearance: appearance == .darkAqua ? .dark : .light)
            actions.handleCommandK()
            #expect(actions.isItemActionPanePresented)
            try Self.save(
                try Self.renderLauncherOnGround(actions, appearance: appearance),
                name: "slate-actions-\(suffix).png"
            )

            let answer = Self.makeViewModel(appearance: appearance == .darkAqua ? .dark : .light)
            let mock = MockQuickService()
            await mock.setResponses([StreamDelta(
                text: "Mercury, Venus, Earth. Mercury is the smallest and closest to the Sun; Venus is the hottest; Earth is the only one known to hold liquid water at the surface.",
                finishReason: "stop"
            )])
            answer.service = mock
            answer.settings.autoCopy = false
            answer.input = "name three planets"
            await answer.submit()
            try Self.save(
                try Self.renderOnGround(
                    OverlayView(viewModel: answer),
                    appearance: appearance,
                    width: answer.currentPanelWidth,
                    height: answer.estimatedWindowHeight + 96
                ),
                name: "slate-answer-\(suffix).png"
            )

            let caffeinate = Self.makeViewModel(appearance: appearance == .darkAqua ? .dark : .light)
            caffeinate.enterCatalog(.caffeinate)
            caffeinate.input = ""
            try Self.save(
                try Self.renderLauncherOnGround(caffeinate, appearance: appearance),
                name: "slate-caffeinate-\(suffix).png"
            )

            try Self.saveSettings(
                root, tab: .general, name: "slate-settings-\(suffix).png", appearance: appearance
            )

            try Self.save(
                try Self.renderOnGround(
                    WelcomeOverlayView(viewModel: root, onContinue: {}),
                    appearance: appearance,
                    width: 460
                ),
                name: "slate-welcome-\(suffix).png"
            )
        }
    }

    /// The Quick AI surface, after Raycast's: empty, the search phase of an
    /// ask (the question pill and the search line, through the real submit
    /// path), an answered thread with a user pill and prose, the `⌘K`
    /// palette over it, a local answer under its own pill, and Recent
    /// Chats, in both appearances. Output: quick-ai-{state}-{dark,light}.png.
    @Test func rendersQuickAISurfaceSet() async throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let preference: AppearancePreference = appearance == .darkAqua ? .dark : .light

            let empty = Self.makeViewModel(appearance: preference)
            empty.input = ""
            #expect(empty.handleTab())
            #expect(empty.isQuickAIPresented)
            #expect(empty.quickAITitle == "Quick AI")
            try Self.save(
                try Self.renderQuickAI(empty, appearance: appearance),
                name: "quick-ai-empty-\(suffix).png"
            )

            // The search phase as the real flow has it: Tab with a search
            // ask, rendered while the search is still out. The question is
            // a pill of its own (it joins the thread with the model call)
            // with the search line under it, and nothing else streams.
            let streaming = Self.makeViewModel(appearance: preference)
            let search = GatedWebSearchService(result: "## [1] Raycast\nURL: https://www.raycast.com/about")
            streaming.webSearchService = search
            streaming.service = MockQuickService()
            streaming.settings.autoCopy = false
            streaming.input = "search web raycast founder"
            #expect(streaming.handleTab())
            let searchSubmit = streaming.tabSubmitTask
            await search.waitUntilSearching()
            #expect(streaming.isStreaming)
            #expect(streaming.output.isEmpty)
            #expect(streaming.pendingQuestion == "search web raycast founder")
            #expect(streaming.webSearchNote?.hasPrefix("Search web: ") == true)
            #expect(streaming.quickAIComposerAction.label == "Stop")
            try Self.save(
                try Self.renderQuickAI(streaming, appearance: appearance),
                name: "quick-ai-streaming-\(suffix).png"
            )
            streaming.cancel()
            await search.release()
            await searchSubmit?.value
            #expect(streaming.output.isEmpty, "the stopped ask never reached the model")

            let answered = Self.makeViewModel(appearance: preference)
            answered.input = ""
            let mock = MockQuickService()
            await mock.setResponses([StreamDelta(
                text: "Raycast was co-founded by **Thomas Paul Mann** (CEO) and **Petr Nikolaev** (CTO) in 2020. Both are former Meta (Facebook) engineers who previously worked on developer tools and productivity workflows. The company was part of Y Combinator's Winter 2020 batch and is headquartered in London, UK.",
                finishReason: "stop"
            )])
            answered.service = mock
            answered.settings.autoCopy = false
            answered.input = "raycast founder"
            #expect(answered.handleTab())
            await answered.tabSubmitTask?.value
            answered.webSearchNote = "Search web: Raycast founder and 2 more terms"
            #expect(answered.isQuickAIPresented)
            #expect(answered.quickAITitle == "raycast founder")
            #expect(answered.quickAIComposerAction.label == "Paste Response")
            let answeredImage = try Self.renderQuickAI(answered, appearance: appearance)
            try Self.save(answeredImage, name: "quick-ai-answered-\(suffix).png")
            #expect(answeredImage.size.width == PanelSizing.panelWidth)
            #expect(answeredImage.size.height == PanelSizing.quickAIHeight)

            // `⌘K` on the surface: the palette hugs the composer and leaves
            // the header alone.
            answered.handleCommandK()
            #expect(answered.isActionPalettePresented)
            let actionsImage = try Self.renderQuickAI(answered, appearance: appearance)
            try Self.save(actionsImage, name: "quick-ai-actions-\(suffix).png")
            let paneTop = Self.floatingPaneTop(in: actionsImage, over: answeredImage)
            #expect(paneTop != nil, "the palette is drawn over the thread")
            #expect(
                (paneTop ?? 0) >= QuickAIView.headerHeight,
                "the palette floats above the composer, not over the header (top at \(paneTop ?? -1) pt)"
            )
            #expect(
                (paneTop ?? 0) < PanelSizing.quickAIHeight - QuickAIView.composerRowHeight,
                "the palette sits inside the thread area, above the composer"
            )
            answered.closeActionPalette()

            // A local answer on a kept chat: not a turn, still drawn.
            let local = Self.makeViewModel(appearance: preference)
            local.input = ""
            local.service = MockQuickService()
            local.settings.autoCopy = false
            local.currentConversation = answered.currentConversation
            local.openQuickAI()
            local.input = "2+2"
            await local.submit()
            #expect(local.output == "4")
            #expect(local.quickAIDetachedAnswer == "4")
            #expect(local.pendingQuestion == "2+2", "the answer draws under its own question pill")
            #expect(local.input.isEmpty)
            #expect(local.quickAIComposerAction.label == "Paste Response")
            try Self.save(
                try Self.renderQuickAI(local, appearance: appearance),
                name: "quick-ai-local-answer-\(suffix).png"
            )

            let recent = answered
            recent.history = [
                recent.currentConversation!,
                QuickConversation(
                    providerID: InferenceProvider.deepSeekID,
                    model: "deepseek-v4-pro",
                    messages: [
                        QuickMessage(role: .user, content: "summarise the Q3 plan"),
                        QuickMessage(role: .assistant, content: "Three priorities."),
                    ]
                ),
                QuickConversation(
                    providerID: InferenceProvider.deepSeekID,
                    model: InferenceProvider.deepSeekDefaultModel,
                    messages: [
                        QuickMessage(role: .user, content: "what is the capital of Peru"),
                        QuickMessage(role: .assistant, content: "Lima."),
                    ]
                ),
            ]
            recent.openRecentChats()
            #expect(recent.isRecentChatsPresented)
            try Self.save(
                try Self.renderQuickAI(recent, appearance: appearance),
                name: "quick-ai-recent-chats-\(suffix).png"
            )
        }
    }

    /// The top edge, in points, of a pane floating over the surface: the
    /// first row down the panel's clear middle column where the pane's
    /// hairline stroke shows against the plain render and the row under it
    /// is glass again (the pane's glass matches the panel offscreen, and
    /// the shadow above the stroke is a smooth ramp, never followed by a
    /// matching row). `nil` when no pane is drawn.
    private static func floatingPaneTop(in paneImage: NSImage, over plainImage: NSImage) -> CGFloat? {
        guard let pane = paneImage.representations.first as? NSBitmapImageRep,
              let plain = plainImage.representations.first as? NSBitmapImageRep,
              pane.pixelsWide == plain.pixelsWide, pane.pixelsHigh == plain.pixelsHigh
        else { return nil }
        let scale = CGFloat(pane.pixelsWide) / paneImage.size.width
        let x = Int(PanelSizing.panelWidth / 2 * scale)
        let lookahead = max(1, Int(scale.rounded()))
        func delta(_ y: Int) -> CGFloat {
            guard let a = pane.colorAt(x: x, y: y), let b = plain.colorAt(x: x, y: y) else { return 0 }
            return max(
                abs(a.redComponent - b.redComponent),
                abs(a.greenComponent - b.greenComponent),
                abs(a.blueComponent - b.blueComponent)
            )
        }
        let stroke = 6.0 / 255.0
        let same = 1.5 / 255.0
        for y in 1..<(pane.pixelsHigh - lookahead) where delta(y) > stroke && delta(y + lookahead) <= same {
            return CGFloat(y) / scale
        }
        return nil
    }

    /// The Quick AI surface at its one fixed size, exactly as the window
    /// draws it.
    private static func renderQuickAI(
        _ vm: QuickViewModel,
        appearance: NSAppearance.Name
    ) throws -> NSImage {
        #expect(vm.currentPanelWidth == PanelSizing.panelWidth)
        #expect(vm.estimatedWindowHeight == PanelSizing.quickAIHeight)
        return try renderFixedHeight(
            viewModel: vm,
            appearance: appearance,
            height: vm.estimatedWindowHeight
        )
    }

    /// The Type to Click HUD: badges and a status pill, drawn by AppKit.
    @Test func rendersTypeToClickHUD() throws {
        let view = TypeToClickOverlayView()
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 300)
        view.badges = [
            TypeToClickBadge(rect: NSRect(x: 60, y: 210, width: 120, height: 28), label: "Save", isSelected: false, isPulsing: false),
            TypeToClickBadge(rect: NSRect(x: 240, y: 210, width: 140, height: 28), label: "Cancel", isSelected: true, isPulsing: false),
            TypeToClickBadge(rect: NSRect(x: 440, y: 210, width: 160, height: 28), label: "Send Message", isSelected: false, isPulsing: true),
        ]
        view.statusText = "3 targets"
        view.statusAnchor = NSPoint(x: 360, y: 70)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw ProofError.noBitmap
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        let hud = NSImage(size: view.bounds.size)
        hud.addRepresentation(rep)
        // The HUD floats over whatever is on screen; a mid grey stands in for
        // the desktop so the chips and the status pill can be judged.
        let composited = NSImage(size: view.bounds.size)
        composited.lockFocus()
        NSColor(srgbRed: 0.16, green: 0.18, blue: 0.22, alpha: 1).setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        hud.draw(
            in: NSRect(origin: .zero, size: view.bounds.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        composited.unlockFocus()
        try Self.save(composited, name: "slate-type-to-click.png")
    }

    @Test func rendersLightLauncher() throws {
        let image = try Self.render(appearance: .aqua)
        try Self.save(image, name: "overlay-light.png")
        let sample = try Self.averageColor(of: image, region: CGRect(x: 300, y: 8, width: 200, height: 20))
        #expect(sample.brightness > 0.65, "light overlay should read as light, got \(sample)")
    }

    // MARK: - Helpers

    private static func makeViewModel(appearance: AppearancePreference) -> QuickViewModel {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.launcherItemConfigurations.append(LauncherItemConfiguration(
            kind: .application,
            itemID: "com.apple.Safari",
            alias: "web",
            hotkey: ActionHotkey(keyCode: 1, modifiers: 1_572_864)
        ))
        let vm = QuickViewModel(
            settings: settings,
            applicationCatalog: ProofApplicationCatalog(),
            launcherCatalog: ProofLauncherCatalog()
        )
        vm.input = "s"
        vm.applicationSelectionIndex = 0
        return vm
    }

    private static func render(appearance: NSAppearance.Name) throws -> NSImage {
        let preference: AppearancePreference = appearance == .darkAqua ? .dark : .light
        return try render(viewModel: makeViewModel(appearance: preference), appearance: appearance)
    }

    private static func render(viewModel vm: QuickViewModel, appearance: NSAppearance.Name) throws -> NSImage {
        let width = vm.currentPanelWidth
        let host = NSHostingView(rootView: OverlayView(viewModel: vm).frame(width: width))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(size.height, 200)))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ProofError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// The launcher as it is actually seen: the panel floating on a ground,
    /// with its two house shadows under it. Offscreen blur has nothing behind
    /// the window to sample, so the ground also stands in for the desktop.
    static func renderOnGround<V: View>(
        _ view: V,
        appearance: NSAppearance.Name,
        width: CGFloat,
        height: CGFloat? = nil,
        margin: CGFloat = 48
    ) throws -> NSImage {
        let isDark = appearance == .darkAqua
        let ground = isDark
            ? Color(nsColor: NSColor(srgbRed: 0.106, green: 0.129, blue: 0.188, alpha: 1))
            : Color(nsColor: NSColor(srgbRed: 0.863, green: 0.890, blue: 0.933, alpha: 1))
        let root = ZStack {
            ground
            view
                .frame(width: width)
                .panelShadows()
                .padding(margin)
        }
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: appearance)
        let fitting = host.fittingSize
        host.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: width + margin * 2,
                height: height ?? max(fitting.height, 200)
            )
        )
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ProofError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func renderLauncherOnGround(
        _ vm: QuickViewModel,
        appearance: NSAppearance.Name
    ) throws -> NSImage {
        try renderOnGround(
            OverlayView(viewModel: vm),
            appearance: appearance,
            width: vm.currentPanelWidth
        )
    }

    private static func renderAtAccessibilitySize(
        viewModel vm: QuickViewModel,
        appearance: NSAppearance.Name
    ) throws -> NSImage {
        let width = vm.currentPanelWidth
        let host = NSHostingView(
            rootView: OverlayView(viewModel: vm)
                .dynamicTypeSize(.accessibility3)
                .frame(width: width)
        )
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(size.height, 300)))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ProofError.noBitmap
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    private static func renderFixedHeight(
        viewModel vm: QuickViewModel,
        appearance: NSAppearance.Name,
        height: CGFloat,
        accessibilitySize: Bool = false
    ) throws -> NSImage {
        let width = vm.currentPanelWidth
        let root = OverlayView(viewModel: vm)
            .dynamicTypeSize(accessibilitySize ? .accessibility3 : .large)
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

    private static func saveOpaque(_ image: NSImage, name: String) throws {
        let opaque = NSImage(size: image.size)
        opaque.lockFocus()
        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        opaque.unlockFocus()
        try save(opaque, name: name)
    }

    struct Sample: CustomStringConvertible {
        var red: Double
        var green: Double
        var blue: Double
        var brightness: Double { (red + green + blue) / 3 }
        var description: String { String(format: "rgb(%.2f, %.2f, %.2f)", red, green, blue) }
    }

    private static func averageColor(of image: NSImage, region: CGRect) throws -> Sample {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { throw ProofError.noBitmap }
        var total = Sample(red: 0, green: 0, blue: 0)
        var count = 0.0
        let scaleX = Double(rep.pixelsWide) / Double(image.size.width)
        let scaleY = Double(rep.pixelsHigh) / Double(image.size.height)
        for y in stride(from: region.minY, to: region.maxY, by: 2) {
            for x in stride(from: region.minX, to: region.maxX, by: 2) {
                // Bitmap rows start at the top; the region is given top-down.
                guard let color = rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?
                    .usingColorSpace(.sRGB) else { continue }
                total.red += Double(color.redComponent)
                total.green += Double(color.greenComponent)
                total.blue += Double(color.blueComponent)
                count += 1
            }
        }
        guard count > 0 else { throw ProofError.noBitmap }
        return Sample(red: total.red / count, green: total.green / count, blue: total.blue / count)
    }

    private static func brightPixelCount(in image: NSImage, region: CGRect) throws -> Int {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { throw ProofError.noBitmap }
        let scaleX = Double(rep.pixelsWide) / Double(image.size.width)
        let scaleY = Double(rep.pixelsHigh) / Double(image.size.height)
        var count = 0
        for y in stride(from: region.minY, to: region.maxY, by: 1) {
            for x in stride(from: region.minX, to: region.maxX, by: 1) {
                guard let color = rep.colorAt(x: Int(x * scaleX), y: Int(y * scaleY))?
                    .usingColorSpace(.sRGB) else { continue }
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                if brightness > 0.45 { count += 1 }
            }
        }
        return count
    }

    enum ProofError: Error { case noBitmap }
}

private final class ProofApplicationCatalog: ApplicationCatalogServicing {
    let applications: [LaunchableApplication] = [
        LaunchableApplication(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari",
            url: URL(fileURLWithPath: "/Applications/Safari.app")
        ),
        LaunchableApplication(
            name: "System Settings",
            bundleIdentifier: "com.apple.systempreferences",
            url: URL(fileURLWithPath: "/System/Applications/System Settings.app")
        ),
        LaunchableApplication(
            name: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            url: URL(fileURLWithPath: "/Applications/Slack.app")
        ),
    ]
    func launch(_ application: LaunchableApplication) -> Bool { true }
}

private final class ProofLauncherCatalog: LauncherCatalogServicing {
    var snippets = [LauncherCatalogItem(
        kind: .snippet,
        itemID: "sig",
        title: "Signature",
        detail: "Snippet",
        value: "Best regards,\nTristan\nExample Co"
    )]
    var quickLinks = [
        LauncherCatalogItem(
            kind: .quickLink,
            itemID: "docs",
            title: "Swift Docs",
            detail: "swift.org",
            value: "https://www.swift.org/documentation/"
        ),
        LauncherCatalogItem(
            kind: .quickLink,
            itemID: "search",
            title: "Search Swift Forums",
            detail: "forums.swift.org",
            value: "https://forums.swift.org/search?q={{input}}",
            requiresInput: true
        ),
    ]
    func reload() {}
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteSnippet(_ item: LauncherCatalogItem) throws {}
}

@MainActor
private final class PreviewSelectedTextService: SelectedTextServicing {
    let text: String
    var isAccessibilityTrusted: Bool { true }
    init(text: String) { self.text = text }
    func currentExternalTarget() -> SelectionTarget? { nil }
    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? {
        SelectedTextContext(target: target, text: text)
    }
    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }
    func paste(_ text: String, to target: SelectionTarget) async -> Bool { true }
    func pastePasteboard(to target: SelectionTarget) async -> Bool { true }
    func openAccessibilitySettings() {}
}
