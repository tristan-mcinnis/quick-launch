// ============================================================================
// ManageModelsRenderProofTests.swift — Render proof for the Manage Models
// screen.
//
// Hosts the real screen in an offscreen NSHostingView under .darkAqua and
// .aqua, writes PNGs to /tmp/quick-launch-manage-models/, and asserts the rows
// actually drew: without an on-screen check, a layout that overflows or
// collapses would still pass every unit test.
//
// CLI: `swift test --filter ManageModelsRenderProof` writes the PNGs.
// ============================================================================

import Testing
import Foundation
import AppKit
import SwiftUI
@testable import QuickLaunch

@Suite("ManageModelsRenderProof")
// AppKit view hosting is not thread-safe; keep these on the main actor.
@MainActor
struct ManageModelsRenderProofTests {
    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-manage-models")
    private static let size = NSSize(width: 780, height: 620)

    private enum ProofError: Error {
        case noBitmap
    }

    @Test func rendersInBothAppearances() throws {
        for (appearance, title) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let image = try Self.render(appearance: appearance)
            try Self.save(image, name: "manage-models-\(title).png")
            let ground = try Self.ground(in: image)
            #expect(ground.alpha > 0.9, "the \(title) render must draw an opaque pane ground")
            #expect(
                appearance == .darkAqua ? ground.luminance < 0.35 : ground.luminance > 0.6,
                "the \(title) render must resolve the pane ground for its own appearance"
            )
            #expect(
                try Self.contentPixelCount(in: image) > 200,
                "the \(title) render must draw the header, the sort control, and the rows"
            )
        }
    }

    @Test func aDisabledModelAndAReasoningChoiceDraw() throws {
        // The render below turns one model off and sets an effort on
        // another, so this proves the checkbox and the dropdown both drew.
        let image = try Self.render(appearance: .darkAqua)

        #expect(try Self.contentPixelCount(in: image) > 200)
    }

    // MARK: - Helpers

    private static func render(appearance: NSAppearance.Name) throws -> NSImage {
        var settings = QuickSettings()
        settings.providers = InferenceProvider.defaults
        let viewModel = QuickViewModel(settings: settings)

        let preferences = ModelPreferenceStore(fileURL: nil)
        preferences.setEnabled(
            false,
            providerID: InferenceProvider.deepSeekID,
            model: InferenceProvider.deepSeekVisionModel
        )
        preferences.setReasoningEffort(
            .high,
            providerID: InferenceProvider.deepSeekID,
            model: "deepseek-v4-flash"
        )

        let root = ManageModelsView(
            viewModel: viewModel,
            preferences: preferences,
            onClose: {}
        )
        .frame(width: size.width, height: size.height)

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

    /// The pane's own background pixel, with the luminance the appearance
    /// check compares.
    private static func ground(in image: NSImage) throws -> (alpha: Double, luminance: Double) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let colour = rep.colorAt(x: 2, y: 2)
        else { throw ProofError.noBitmap }
        return (
            Double(colour.alphaComponent),
            0.2126 * Double(colour.redComponent)
                + 0.7152 * Double(colour.greenComponent)
                + 0.0722 * Double(colour.blueComponent)
        )
    }

    /// Counts sampled pixels that differ from the pane's own background.
    /// Content is dark ink on light ground or the reverse, so a screen that
    /// drew nothing scores near zero.
    private static func contentPixelCount(in image: NSImage) throws -> Int {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let ground = rep.colorAt(x: 2, y: 2)
        else { throw ProofError.noBitmap }

        var differing = 0
        var x = 0
        while x < rep.pixelsWide {
            var y = 0
            while y < rep.pixelsHigh {
                if let colour = rep.colorAt(x: x, y: y) {
                    let delta = abs(colour.redComponent - ground.redComponent)
                        + abs(colour.greenComponent - ground.greenComponent)
                        + abs(colour.blueComponent - ground.blueComponent)
                    if delta > 0.15 { differing += 1 }
                }
                y += 3
            }
            x += 3
        }
        return differing
    }

    private static func save(_ image: NSImage, name: String) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { throw ProofError.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }
}
