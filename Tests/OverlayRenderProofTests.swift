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
        vm.enterInputMode(.translate)
        vm.input = "Where is the nearest station?"
        try Self.save(try Self.render(viewModel: vm, appearance: .darkAqua), name: "overlay-translate-dark.png")
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
        let host = NSHostingView(rootView: OverlayView(viewModel: vm).frame(width: 620))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: 620, height: max(size.height, 200)))
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
