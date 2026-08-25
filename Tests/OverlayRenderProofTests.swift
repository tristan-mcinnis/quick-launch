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
        let sample = try Self.averageColor(of: image, region: CGRect(x: 40, y: 10, width: 200, height: 20))
        #expect(sample.brightness < 0.35, "dark overlay should read as dark, got \(sample)")
    }

    @Test func rendersDarkActionPane() throws {
        let vm = Self.makeViewModel(appearance: .dark)
        vm.handleCommandK()
        #expect(vm.isItemActionPanePresented)
        let image = try Self.render(viewModel: vm, appearance: .darkAqua)
        try Self.save(image, name: "overlay-actions-dark.png")
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

    @Test func rendersSettingsItemsTab() throws {
        let vm = Self.makeViewModel(appearance: .dark)
        vm.input = ""
        try Self.saveSettings(vm, tab: .general, name: "settings-dark.png")
        try Self.saveSettings(vm, tab: .items, name: "settings-items-dark.png")
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
        vm.screenHistoryStore = store
        vm.enterCatalog(.screenHistory)
        await vm.loadScreenHistory(query: "coral variance")
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
        if let item = vm.screenHistoryItems.first {
            vm.openActionPane(for: .item(item), form: .screenHistorySave)
            try Self.save(
                try Self.render(viewModel: vm, appearance: .darkAqua),
                name: "overlay-screen-history-save-dark.png"
            )
            let productionSave = try Self.renderFixedHeight(
                viewModel: vm,
                appearance: .darkAqua,
                height: PanelSizing.screenHistorySaveMinimumHeight
            )
            try Self.save(
                productionSave,
                name: "overlay-screen-history-save-production-dark.png"
            )
            let largeTextSave = try Self.renderFixedHeight(
                viewModel: vm,
                appearance: .darkAqua,
                height: PanelSizing.screenHistorySaveMinimumHeight,
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
        if let frame = vm.screenHistoryFrames.first {
            await vm.openScreenHistorySequence(for: frame)
            try Self.save(
                try Self.render(viewModel: vm, appearance: .darkAqua),
                name: "overlay-screen-history-timeline-dark.png"
            )
            vm.closeScreenHistoryTimeline()
        }

        vm.input = "synthetic phrase with no match"
        await vm.loadScreenHistory(query: vm.input)
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
        await unavailable.loadScreenHistory(query: "coral")
        try Self.save(
            try Self.render(viewModel: unavailable, appearance: .darkAqua),
            name: "overlay-screen-history-unavailable-dark.png"
        )
    }

    private static func saveSettings(_ vm: QuickViewModel, tab: SettingsView.SettingsTab, name: String) throws {
        let host = NSHostingView(rootView: SettingsView(viewModel: vm, initialTab: tab))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: SettingsView.windowSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ProofError.noBitmap }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        try Self.save(image, name: name)
    }

    @Test func rendersLightLauncher() throws {
        let image = try Self.render(appearance: .aqua)
        try Self.save(image, name: "overlay-light.png")
        let sample = try Self.averageColor(of: image, region: CGRect(x: 40, y: 10, width: 200, height: 20))
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
        kind: .snippet, itemID: "sig", title: "Signature", detail: "Snippet", value: "Best regards"
    )]
    var quickLinks: [LauncherCatalogItem] = []
    func reload() {}
    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteSnippet(_ item: LauncherCatalogItem) throws {}
}
