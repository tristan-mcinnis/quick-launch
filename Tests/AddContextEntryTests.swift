import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// The Add Context menu once files and links attach (spec 3.2): the four
/// captures, then File…, Link…, and Finder Selection only behind Finder.
@Suite("Add Context rows")
@MainActor
struct AddContextEntryTests {
    @Test func theMenuListsTheCapturesThenFileAndLink() {
        let rows = AddContextRow.menu(finderIsBehind: false)
        #expect(rows.map(\.title) == [
            "Focused Window", "Selected Text", "Selected Area", "Entire Screen", "File…", "Link…",
        ])
        #expect(rows.prefix(4).compactMap(\.capture) == AddContextEntry.allCases, "the captures keep their order")
        #expect(rows.dropFirst(4).allSatisfy { $0.capture == nil })
    }

    @Test func finderSelectionIsListedOnlyBehindFinder() {
        let behindFinder = AddContextRow.menu(finderIsBehind: true)
        #expect(behindFinder.count == 7)
        #expect(behindFinder.last == .finderSelection)
        #expect(behindFinder.last?.title == "Finder Selection")

        #expect(AddContextRow.menu(appBehind: "com.apple.finder").last == .finderSelection)
        #expect(!AddContextRow.menu(appBehind: "com.apple.Safari").contains(.finderSelection))
        #expect(!AddContextRow.menu(appBehind: nil).contains(.finderSelection))
    }

    @Test func theNewRowsCarryTheSpecGlyphs() {
        #expect(AddContextRow.file.systemImage == "doc.badge.plus")
        #expect(AddContextRow.link.systemImage == "link")
        #expect(AddContextRow.finderSelection.systemImage == "folder")
        for row in AddContextRow.menu(finderIsBehind: true) {
            #expect(NSImage(systemSymbolName: row.systemImage, accessibilityDescription: nil) != nil)
            #expect(!row.detail.isEmpty)
        }
        let ids = AddContextRow.menu(finderIsBehind: true).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func thePaneListsTheViewModelsCapturesWithoutATray() {
        #expect(
            AddContextPane.rows(captures: AddContextEntry.allCases, tray: nil)
                == AddContextEntry.allCases.map(AddContextRow.capture)
        )
        let tray = AttachmentTray(extractor: FakeAttachmentExtractor())
        #expect(AddContextPane.rows(captures: AddContextEntry.allCases, tray: tray).count == 6)
        tray.finderIsBehind = true
        #expect(AddContextPane.rows(captures: AddContextEntry.allCases, tray: tray).count == 7)
    }

    @Test func theFilePanelOffersTheReadableTypes() {
        let offered = Set(AttachmentTray.openPanelFileExtensions)
        for ext in ["pdf", "docx", "pptx", "xlsx", "html", "md", "txt", "csv", "swift", "png", "heic", "webp"] {
            #expect(offered.contains(ext), "\(ext)")
        }
        for ext in ["key", "pages", "numbers", "zip", "dmg", "mp4"] {
            #expect(!offered.contains(ext), "\(ext) cannot be read in v1")
        }
    }

    @Test func aFileGuessesItsKindFromItsExtension() {
        func kind(_ name: String) -> ChatAttachmentKind {
            ChatAttachmentKind.guess(forFileAt: URL(fileURLWithPath: "/tmp/\(name)"))
        }
        #expect(kind("a.PDF") == .pdf)
        #expect(kind("a.docx") == .word)
        #expect(kind("a.rtf") == .word)
        #expect(kind("a.pptx") == .powerpoint)
        #expect(kind("a.xlsx") == .excel)
        #expect(kind("a.htm") == .html)
        #expect(kind("a.md") == .markdown)
        #expect(kind("a.swift") == .code)
        #expect(kind("a.jpeg") == .image)
        #expect(kind("a.log") == .text)
        #expect(kind("README") == .text)
    }
}
