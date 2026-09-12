// SnippetEditorRenderProofTests — visual proof for the ⌘K create and edit
// form, the surface the Create Snippet and Create Quicklink commands open.
//
// Hosts the real OverlayView with the form up, renders it dark and light,
// and writes PNGs to /tmp/quick-launch-render-proof/snippet-editor-*.png so
// a reviewer can look at the fields, the hint line, and the key caps without
// launching the app.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuickLaunch

@Suite("SnippetEditorRenderProof", .serialized)
@MainActor
struct SnippetEditorRenderProofTests {
    private enum ProofFailure: Error { case noBitmap }

    private static let outputDir = URL(fileURLWithPath: "/tmp/quick-launch-render-proof")

    @Test func rendersTheNewSnippetForm() throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let vm = Self.makeViewModel(appearance: appearance == .darkAqua ? .dark : .light)
            vm.beginCreatingSnippet()
            #expect(vm.activeItemActionForm == .edit)
            #expect(vm.contextualCatalogItem.map(vm.isDraftItem) == true)
            try Self.save(
                try Self.render(vm, appearance: appearance),
                name: "snippet-editor-new-snippet-\(suffix).png"
            )
        }
    }

    @Test func rendersTheNewQuicklinkForm() throws {
        for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            let vm = Self.makeViewModel(appearance: appearance == .darkAqua ? .dark : .light)
            vm.beginCreatingQuicklink()
            #expect(vm.contextualCatalogItem?.kind == .quickLink)
            try Self.save(
                try Self.render(vm, appearance: appearance),
                name: "snippet-editor-new-quicklink-\(suffix).png"
            )
        }
    }

    /// A stored Quicklink now carries Edit and Delete, so its ⌘K list is
    /// worth a look beside the snippet's.
    @Test func rendersTheQuicklinkActionList() throws {
        let vm = Self.makeViewModel(appearance: .dark)
        vm.enterCatalog(.quickLinks)
        vm.handleCommandK()
        #expect(vm.isItemActionPanePresented)
        #expect(vm.focusedItemActions.contains { $0.kind == .delete })
        try Self.save(
            try Self.render(vm, appearance: .darkAqua),
            name: "snippet-editor-quicklink-actions-dark.png"
        )
    }

    // MARK: - Harness

    private static func makeViewModel(appearance: AppearancePreference) -> QuickViewModel {
        var settings = QuickSettings()
        settings.appearance = appearance
        settings.historyEnabled = false
        return QuickViewModel(
            settings: settings,
            launcherCatalog: EditorProofCatalog(),
            pasteboard: FakePasteboard()
        )
    }

    private static func render(
        _ vm: QuickViewModel,
        appearance: NSAppearance.Name
    ) throws -> NSImage {
        let width = vm.currentPanelWidth
        let host = NSHostingView(rootView: OverlayView(viewModel: vm).frame(width: width))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(
            origin: .zero,
            size: NSSize(width: width, height: max(size.height, vm.estimatedWindowHeight))
        )
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw ProofFailure.noBitmap
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
        else { throw ProofFailure.noBitmap }
        try png.write(to: outputDir.appendingPathComponent(name))
    }
}

/// A catalog with one of each kind, so the proof shows real rows and the
/// editor has something to sit over. It creates in memory only.
@MainActor
private final class EditorProofCatalog: LauncherCatalogServicing {
    var snippets = [LauncherCatalogItem(
        kind: .snippet, itemID: "tuna-custom-one", title: "Sign-off",
        detail: "Tuna snippet", value: "Kind regards,\n{cursor}"
    )]
    var quickLinks = [LauncherCatalogItem(
        kind: .quickLink, itemID: "tuna-url-two", title: "Handbook",
        detail: "example.com", value: "https://example.com/handbook"
    )]

    func reload() {}

    func updateSnippet(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteSnippet(_ item: LauncherCatalogItem) throws {}
    func updateQuickLink(_ item: LauncherCatalogItem, title: String, value: String) throws {}
    func deleteQuickLink(_ item: LauncherCatalogItem) throws {}

    func createSnippet(title: String, value: String) throws -> LauncherCatalogItem {
        let item = LauncherCatalogItem(
            kind: .snippet, itemID: "tuna-custom-new", title: title,
            detail: "Tuna snippet", value: value
        )
        snippets.append(item)
        return item
    }

    func createQuickLink(title: String, value: String) throws -> LauncherCatalogItem {
        let item = LauncherCatalogItem(
            kind: .quickLink, itemID: "tuna-url-new", title: title,
            detail: "example.com", value: value
        )
        quickLinks.append(item)
        return item
    }
}
