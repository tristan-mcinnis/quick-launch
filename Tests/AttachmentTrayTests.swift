import AppKit
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import QuickLaunch

/// The attachment tray (spec 3.2, 3.10): chips that read, fail, and ride;
/// the limits of 10 a message and 6 images; Backspace, Escape, and the
/// strip keys; what `⌘V` attaches; Link…; drops.
@Suite("Attachment tray")
@MainActor
struct AttachmentTrayTests {
    private func make(timeout: Duration = .seconds(5)) -> (AttachmentTray, FakeAttachmentExtractor) {
        let extractor = FakeAttachmentExtractor()
        return (AttachmentTray(extractor: extractor, readTimeout: timeout), extractor)
    }

    private func file(_ name: String) -> AttachmentSource {
        .file(URL(fileURLWithPath: "/tmp/quick-launch-tray-tests/\(name)"))
    }

    private func link(_ string: String) -> AttachmentSource {
        .link(URL(string: string)!)
    }

    static func image(width: Int = 64, height: Int = 48) -> QuickImageAttachment {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let png = rep.representation(using: .png, properties: [:])!
        return QuickImageAttachment(data: png, mimeType: "image/png", pixelWidth: width, pixelHeight: height)
    }

    private func imageSource(_ name: String) -> AttachmentSource {
        .image(Self.image(), name: name, kind: .image)
    }

    /// Lets the reads the tray started finish.
    private func settle(_ tray: AttachmentTray) async {
        await tray.waitUntilRead()
    }

    // MARK: - States

    @Test func aChipShowsReadingAtOnceThenItsReference() async {
        let (tray, extractor) = make()
        await extractor.hold("report.pdf")
        let id = tray.add(file("report.pdf"))
        #expect(id != nil)
        #expect(tray.items.count == 1)
        #expect(tray.items[0].isReading)
        #expect(tray.items[0].kind == .pdf, "the extension picks the first glyph")
        #expect(tray.isReading)
        #expect(tray.readingStatusLine == "Reading report.pdf…")
        #expect(AttachmentChipModel(item: tray.items[0]).detailLine == "Reading…")

        await extractor.release("report.pdf")
        await settle(tray)
        #expect(!tray.isReading)
        #expect(tray.readingStatusLine == nil)
        #expect(tray.items[0].content?.text == "Text of report.pdf.")
        #expect(tray.readyContents.count == 1)
    }

    @Test func twoReadingChipsReadAsACount() async {
        let (tray, extractor) = make()
        await extractor.hold("a.pdf")
        await extractor.hold("b.docx")
        tray.add(file("a.pdf"))
        tray.add(file("b.docx"))
        #expect(tray.readingStatusLine == "Reading 2 attachments…")
        await extractor.release("a.pdf")
        await extractor.release("b.docx")
        await settle(tray)
    }

    @Test func aFailedChipStaysSaysWhyAndNeverRides() async {
        let (tray, extractor) = make()
        await extractor.set(.failure("The file is damaged"), for: "broken.docx")
        tray.add(file("broken.docx"))
        tray.add(file("notes.md"))
        await settle(tray)

        #expect(tray.items.count == 2, "the failed chip stays so the user sees it")
        #expect(tray.items[0].failureLine == "The file is damaged")
        let chip = AttachmentChipModel(item: tray.items[0])
        #expect(chip.systemImage == "exclamationmark.triangle")
        #expect(chip.detailLine == "The file is damaged")
        #expect(chip.accessibilityLabel == "Attachment: broken.docx, Word document, The file is damaged")

        let sent = tray.takeForSend()
        #expect(sent.map(\.ref.name) == ["notes.md"], "a failed chip never rides the request")
        #expect(tray.isEmpty)
    }

    @Test func aReadThatTakesTooLongFails() async {
        let (tray, extractor) = make(timeout: .milliseconds(50))
        await extractor.set(.hang, for: "huge.pdf")
        tray.add(file("huge.pdf"))
        await settle(tray)
        #expect(tray.items[0].failureLine == "Reading took too long")
    }

    @Test func aNonReadErrorShowsItsDescription() async {
        struct Odd: LocalizedError { var errorDescription: String? { "Something odd happened" } }
        struct OddReader: AttachmentExtracting {
            func content(for source: AttachmentSource) async throws -> AttachmentContent { throw Odd() }
        }
        let tray = AttachmentTray(extractor: OddReader())
        tray.add(file("a.pdf"))
        await tray.waitUntilRead()
        #expect(tray.items[0].failureLine == "Something odd happened")
    }

    // MARK: - Limits

    @Test func tenAttachmentsIsTheMostForOneMessage() async {
        let (tray, _) = make()
        let added = tray.add(contentsOf: (1...11).map { file("file \($0).txt") })
        #expect(added.count == 10)
        #expect(tray.items.count == 10)
        #expect(tray.notice == "10 attachments is the most for one message.")
        #expect(tray.add(link("https://example.com")) == nil)
        await settle(tray)
    }

    @Test func sixImagesIsTheMostForOneMessage() async {
        let (tray, _) = make()
        for index in 1...6 { #expect(tray.add(imageSource("Image \(index)")) != nil) }
        #expect(tray.add(imageSource("Image 7")) == nil)
        #expect(tray.notice == "6 images is the most for one message.")
        #expect(tray.add(file("photo.png")) == nil, "an image file counts as an image")
        #expect(tray.add(file("report.pdf")) != nil, "a document still fits")
        #expect(tray.notice == nil)
        await settle(tray)
    }

    @Test func anImageFoundOnlyByReadingStillCountsAgainstTheSix() async {
        let (tray, extractor) = make()
        for index in 1...6 { tray.add(imageSource("Image \(index)")) }
        await extractor.set(
            .content(AttachmentContent(ref: ChatAttachmentRef(kind: .image, name: "scan"), image: Self.image())),
            for: "scan"
        )
        #expect(tray.add(file("scan")) != nil, "no extension: not known as an image yet")
        await settle(tray)
        #expect(tray.items.last?.failureLine == "6 images is the most for one message.")
        #expect(tray.readyContents.count == 6)
    }

    @Test func failedChipsDoNotCountAgainstTheTen() async {
        let (tray, extractor) = make()
        await extractor.set(.failure("No readable text"), for: "empty.txt")
        tray.add(file("empty.txt"))
        await settle(tray)
        for index in 1...10 { #expect(tray.add(file("file \(index).txt")) != nil) }
        #expect(tray.add(file("file 11.txt")) == nil)
        await settle(tray)
    }

    @Test func aSecondCopyOfTheSameFileOrLinkIsRefused() async {
        let (tray, _) = make()
        tray.add(file("report.pdf"))
        #expect(tray.add(file("report.pdf")) == nil)
        #expect(tray.notice == "report.pdf is already attached.")
        tray.add(link("https://example.com/pricing"))
        #expect(tray.add(link("https://example.com/pricing")) == nil)
        #expect(tray.items.count == 2)
        await settle(tray)
    }

    @Test func foldersAreRefusedButPackagesGoToTheReader() async throws {
        let (tray, _) = make()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "quick-launch-tray-\(UUID().uuidString)", directoryHint: .isDirectory)
        let folder = root.appending(path: "Reports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(tray.add(.file(folder)) == nil)
        #expect(tray.notice == "Folders cannot be attached; drop the files.")
        let noSlash = URL(fileURLWithPath: folder.path)
        #expect(tray.add(.file(noSlash)) == nil, "a folder is a folder without its slash too")

        let package = root.appending(path: "Notes.rtfd", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(tray.add(.file(package)) != nil, "an rtfd is a document, read or refused by the reader")
        await settle(tray)
    }

    @Test func onlyWebLinksAttach() {
        let (tray, _) = make()
        #expect(tray.add(.link(URL(fileURLWithPath: "/etc/hosts"))) == nil)
        #expect(tray.notice == "Paste a link that starts with http:// or https://.")
        #expect(tray.add(link("ftp://example.com/file")) == nil)
        #expect(tray.add(.file(URL(string: "https://example.com/a.pdf")!)) == nil)
        #expect(tray.isEmpty)
    }

    // MARK: - Removing

    @Test func backspaceInAnEmptyComposerRemovesTheNewest() async {
        let (tray, _) = make()
        tray.add(file("a.pdf"))
        tray.add(file("b.pdf"))
        #expect(!tray.handleBackspace(composerIsEmpty: false), "with text the key is the field's")
        #expect(tray.items.count == 2)
        #expect(tray.handleBackspace(composerIsEmpty: true))
        #expect(tray.items.map(\.name) == ["a.pdf"])
        #expect(tray.handleBackspace(composerIsEmpty: true))
        #expect(!tray.handleBackspace(composerIsEmpty: true), "nothing left to remove")
    }

    @Test func escapeCancelsTheReadKeepsReadChips() async {
        let (tray, extractor) = make()
        tray.add(file("done.md"))
        await settle(tray)
        await extractor.hold("slow.pdf")
        tray.add(file("slow.pdf"))
        #expect(tray.isReading)
        // Wait until the reader has actually been asked, rather than napping
        // and hoping it started.
        await eventuallyAsync("the held read to start") {
            await extractor.requested.contains("slow.pdf")
        }

        #expect(tray.cancelReading())
        #expect(tray.items.map(\.name) == ["done.md"])
        #expect(!tray.isReading)
        #expect(!tray.cancelReading(), "nothing is reading now")
        await eventuallyAsync("the read to be cancelled") {
            await extractor.cancelled.contains("slow.pdf")
        }
        #expect(await extractor.cancelled.contains("slow.pdf"), "the reader was told to stop")
        await extractor.release("slow.pdf")
        #expect(tray.items.map(\.name) == ["done.md"], "a late result does not bring it back")
    }

    @Test func aSendWaitsForAReadingChip() async {
        let (tray, extractor) = make()
        await extractor.hold("report.pdf")
        tray.add(file("report.pdf"))
        let send = Task { @MainActor in
            await tray.waitUntilRead()
            return tray.takeForSend()
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(tray.isReading, "the send is still waiting")
        await extractor.release("report.pdf")
        let sent = await send.value
        #expect(sent.map(\.ref.name) == ["report.pdf"])
        #expect(tray.isEmpty)
    }

    @Test func removingAChipStopsItsRead() async {
        let (tray, extractor) = make()
        await extractor.hold("slow.pdf")
        let id = tray.add(file("slow.pdf"))!
        tray.remove(id)
        #expect(tray.isEmpty)
        await tray.waitUntilRead()
        await extractor.release("slow.pdf")
        #expect(tray.isEmpty)
    }

    // MARK: - Strip keys

    @Test func shiftTabMovesIntoTheStripAndTheArrowsMove() async {
        let (tray, _) = make()
        #expect(!tray.enterStrip(), "no chips, nothing to move into")
        let a = tray.add(file("a.pdf"))!
        let b = tray.add(file("b.pdf"))!
        let c = tray.add(link("https://example.com"))!

        #expect(tray.enterStrip())
        #expect(tray.focusedItemID == c, "the newest chip takes the keys")
        #expect(tray.moveFocus(1))
        #expect(tray.focusedItemID == c, "stops at the end")
        tray.moveFocus(-1)
        tray.moveFocus(-1)
        tray.moveFocus(-1)
        #expect(tray.focusedItemID == a, "stops at the start")
        #expect(tray.focusedFileURL?.lastPathComponent == "a.pdf")

        tray.moveFocus(1)
        #expect(tray.handleBackspace(composerIsEmpty: false), "in the strip Backspace removes the chip")
        #expect(tray.items.map(\.id) == [a, c])
        #expect(tray.focusedItemID == a, "the keys move to the chip before it")
        tray.moveFocus(1)
        #expect(tray.focusedFileURL == nil, "a link has no file to preview")

        #expect(tray.leaveStrip())
        #expect(!tray.isStripFocused)
        #expect(!tray.leaveStrip())
        #expect(!tray.moveFocus(1), "outside the strip the arrows are the composer's")
        _ = b
        await settle(tray)
    }

    @Test func typingLeavesTheStrip() async {
        let (tray, _) = make()
        tray.add(file("a.pdf"))
        tray.enterStrip()
        tray.composerTextDidChange("h")
        #expect(!tray.isStripFocused)
        await settle(tray)
    }

    // MARK: - Paste

    @Test func pasteClassification() {
        let files = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.png")]
        let image = Self.image()
        func action(_ contents: AttachmentPasteboardContents, typed: String = "") -> AttachmentTray.PasteAction {
            AttachmentTray.pasteAction(for: contents, composerText: typed)
        }

        // Files win: Finder also puts the files' icons and names on the pasteboard.
        #expect(action(.init(fileURLs: files, image: image, string: "a.pdf")) == .attachFiles(files))
        // An image on its own attaches, even with text typed.
        #expect(action(.init(image: image), typed: "what is this") == .attachImage(image))
        // Text next to a picture of it (Word, Excel) is text.
        #expect(action(.init(image: image, string: "Q3 revenue rose 12%")) == .pasteText)
        // A copied web image carries its link: the image wins.
        #expect(action(.init(image: image, string: "https://example.com/cat.png")) == .attachImage(image))
        // A lone link into an empty composer becomes a Link chip.
        let pricing = URL(string: "https://example.com/pricing")!
        #expect(
            action(.init(string: "https://example.com/pricing")) == .attachLink(pricing, text: "https://example.com/pricing")
        )
        #expect(
            action(.init(string: "  https://example.com/pricing\n"), typed: "  ")
                == .attachLink(pricing, text: "  https://example.com/pricing\n")
        )
        // A link into a composer with text, or inside other text, stays text.
        #expect(action(.init(string: "https://example.com/pricing"), typed: "compare") == .pasteText)
        #expect(action(.init(string: "see https://example.com/pricing")) == .pasteText)
        // Not a web link.
        #expect(action(.init(string: "file:///etc/hosts")) == .pasteText)
        #expect(action(.init(string: "mailto:me@example.com")) == .pasteText)
        #expect(action(.init(string: "hello")) == .pasteText)
        #expect(action(.init()) == .pasteText)
    }

    @Test func pastingAttachesAndALinkPasteUndoesIntoText() async {
        let (tray, _) = make()
        #expect(!tray.paste(.init(string: "plain words"), composerText: ""))
        #expect(tray.isEmpty)

        #expect(tray.paste(.init(fileURLs: [URL(fileURLWithPath: "/tmp/a.pdf")]), composerText: "typed"))
        #expect(tray.paste(.init(image: Self.image()), composerText: ""))
        #expect(tray.items.map(\.name) == ["a.pdf", "Pasted image"])
        #expect(!tray.canUndoPastedLink)

        #expect(tray.paste(.init(string: "https://example.com/pricing"), composerText: ""))
        #expect(tray.items.last?.kind == .link)
        #expect(tray.canUndoPastedLink)
        #expect(tray.undoPastedLink() == "https://example.com/pricing")
        #expect(tray.items.count == 2, "the link chip went back to text")
        #expect(!tray.canUndoPastedLink)
        #expect(tray.undoPastedLink() == nil)

        tray.paste(.init(string: "https://example.com/other"), composerText: "")
        tray.composerTextDidChange("a")
        #expect(!tray.canUndoPastedLink, "typing makes ⌘Z the field's again")
        await settle(tray)
    }

    @Test func thePasteboardReaderReadsWithoutWriting() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("quick-launch-tray-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        let file = URL(fileURLWithPath: "/tmp/quick-launch-tray/report.pdf")
        pasteboard.writeObjects([file as NSURL])
        var count = pasteboard.changeCount
        let files = AttachmentPasteboardReader.read(pasteboard)
        #expect(files.fileURLs == [file])
        #expect(files.string == nil, "files stop the read")
        #expect(pasteboard.changeCount == count, "reading never writes")

        pasteboard.clearContents()
        pasteboard.setString("https://example.com/pricing", forType: .string)
        count = pasteboard.changeCount
        let text = AttachmentPasteboardReader.read(pasteboard)
        #expect(text.fileURLs.isEmpty)
        #expect(text.string == "https://example.com/pricing")
        #expect(text.image == nil)

        let (tray, _) = make()
        #expect(tray.paste(text, composerText: ""))
        #expect(pasteboard.changeCount == count, "attaching never writes the pasteboard")
        tray.removeAll()

        pasteboard.clearContents()
        pasteboard.setData(Self.image().data, forType: .png)
        let picture = AttachmentPasteboardReader.read(pasteboard)
        #expect(picture.image?.pixelWidth == 64)
    }

    // MARK: - Link…

    @Test func linkEntryPrefillsFromTheClipboardAndAttaches() async {
        let (tray, _) = make()
        tray.beginLinkEntry(clipboard: "https://example.com/pricing\n")
        #expect(tray.linkDraft == "https://example.com/pricing")
        tray.cancelLinkEntry()
        #expect(!tray.isEnteringLink)

        tray.beginLinkEntry(clipboard: "not a link")
        #expect(tray.linkDraft == "", "only a lone web link prefills")
        tray.linkDraft = "example dot com"
        #expect(!tray.submitLinkEntry())
        #expect(tray.notice == "Paste a link that starts with http:// or https://.")
        #expect(tray.isEnteringLink, "the field stays for a fix")

        tray.linkDraft = " https://example.com/docs "
        #expect(tray.submitLinkEntry())
        #expect(!tray.isEnteringLink)
        #expect(tray.items.map(\.kind) == [.link])
        #expect(tray.items[0].name == "example.com", "the host until the page is read")
        await settle(tray)
        #expect(!tray.cancelLinkEntry(), "no field open")
    }

    @Test func rowsThatAttachGoToTheTrayOrItsOwner() {
        let (tray, _) = make()
        var chose = 0
        var readFinder = 0
        tray.onChooseFiles = { chose += 1 }
        tray.onReadFinderSelection = { readFinder += 1 }

        #expect(!tray.run(.capture(.entireScreen), clipboard: nil), "captures are the view model's")
        #expect(tray.run(.file, clipboard: nil))
        #expect(chose == 1)
        #expect(tray.run(.finderSelection, clipboard: nil))
        #expect(readFinder == 1)
        #expect(tray.run(.link, clipboard: "https://example.com"))
        #expect(tray.linkDraft == "https://example.com")
    }

    // MARK: - Drop

    @Test func aDropOfFilesLinksAndImagesBecomesChips() async throws {
        let (tray, _) = make()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "quick-launch-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appending(path: "report.pdf")
        try Data("%PDF-1.4".utf8).write(to: report)

        let fileProvider = NSItemProvider(contentsOf: report)!
        let linkProvider = NSItemProvider(object: URL(string: "https://example.com/pricing")! as NSURL)
        let imageProvider = NSItemProvider(item: Self.image().data as NSData, typeIdentifier: UTType.png.identifier)

        tray.acceptDrop([fileProvider, linkProvider, imageProvider])
        await tray.waitForDrop()
        #expect(tray.items.map(\.kind) == [.pdf, .link, .image])
        #expect(tray.items.map(\.name) == ["report.pdf", "example.com", "Dropped image"])
        await settle(tray)
    }

    @Test func aDropOfAFolderSaysDropTheFiles() async throws {
        let (tray, _) = make()
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "quick-launch-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        tray.acceptDrop([NSItemProvider(object: folder as NSURL)])
        await tray.waitForDrop()
        #expect(tray.readyContents.isEmpty)
        #expect(tray.items.first?.failureLine == "Folders cannot be attached; drop the files.",
                "a refused pending drop stays visible so a waiting Send cannot omit it silently")

        tray.acceptDrop([NSItemProvider(object: "just words" as NSString)])
        await tray.waitForDrop()
        #expect(tray.notice == "Nothing here can be attached.")
    }

    // MARK: - Chips

    @Test func chipDetailsReadAsTheSpecDraws() {
        let pdf = ChatAttachmentRef(
            kind: .pdf,
            name: "Q3 report.pdf",
            byteCount: 1_200_000,
            pageCount: 42,
            truncation: AttachmentTruncation(keptCharacters: 200_000, totalCharacters: 612_000)
        )
        let chip = AttachmentChipModel(ref: pdf)
        #expect(chip.detail == "42 pp · 1.2 MB")
        #expect(chip.detailLine == "42 pp · 1.2 MB · cut")
        #expect(chip.help == "Q3 report.pdf: First 200,000 of 612,000 characters")
        #expect(
            chip.accessibilityLabel
                == "Attachment: Q3 report.pdf, PDF, 42 pages, cut to the first 200,000 of 612,000 characters"
        )
        #expect(chip.systemImage == "doc.richtext")

        #expect(AttachmentChipModel(ref: ChatAttachmentRef(kind: .powerpoint, name: "Deck.pptx", pageCount: 12)).detail
            == "12 slides")
        #expect(AttachmentChipModel(ref: ChatAttachmentRef(kind: .excel, name: "Budget.xlsx", pageCount: 3)).detail
            == "3 sheets")
        #expect(AttachmentChipModel(ref: ChatAttachmentRef(kind: .text, name: "notes.txt", byteCount: 18_000)).detail
            == "18 KB")
        let shot = AttachmentChipModel(ref: ChatAttachmentRef(
            kind: .screenshot, name: "Screenshot", pixelWidth: 1_944, pixelHeight: 1_464
        ))
        #expect(shot.detail == "1944 × 1464")
        #expect(shot.accessibilityLabel == "Attachment: Screenshot, Screenshot, 1944 by 1464 pixels")
        let page = AttachmentChipModel(ref: ChatAttachmentRef(
            kind: .link, name: "Pricing | Example", url: URL(string: "https://example.com/pricing")
        ))
        #expect(page.detail == "example.com")
        #expect(page.help == "Pricing | Example")
    }

    @Test func sizesReadInDecimalUnits() {
        #expect(AttachmentChipModel.byteText(1) == "1 byte")
        #expect(AttachmentChipModel.byteText(900) == "900 bytes")
        #expect(AttachmentChipModel.byteText(18_000) == "18 KB")
        #expect(AttachmentChipModel.byteText(999_700) == "1.0 MB")
        #expect(AttachmentChipModel.byteText(1_258_291) == "1.3 MB")
        #expect(AttachmentChipModel.byteText(52_400_000) == "52 MB")
        #expect(AttachmentChipModel.byteText(2_100_000_000) == "2.1 GB")
    }

    @Test func everyKindHasTheSpecGlyph() {
        let expected: [ChatAttachmentKind: String] = [
            .pdf: "doc.richtext", .word: "doc.text", .powerpoint: "rectangle.on.rectangle.angled",
            .excel: "tablecells", .html: "chevron.left.forwardslash.chevron.right",
            .text: "text.alignleft", .markdown: "text.alignleft", .code: "curlybraces",
            .link: "link", .image: "photo", .screenshot: "camera.viewfinder", .selection: "text.cursor",
        ]
        for kind in ChatAttachmentKind.allCases {
            #expect(AttachmentChipModel.systemImage(for: kind) == expected[kind])
            #expect(NSImage(systemSymbolName: AttachmentChipModel.systemImage(for: kind), accessibilityDescription: nil) != nil)
        }
    }

    @Test func theViewModelsOwnCapturesShowAsChips() {
        var settings = QuickSettings()
        settings.historyEnabled = false
        let vm = QuickViewModel(settings: settings, service: MockQuickService())
        vm.pendingImages = [Self.image(width: 1_944, height: 1_464), Self.image()]
        vm.pendingContext = CaptureContext(appName: "Safari", selectedText: "the selected passage")

        let chips = PendingCaptureChips.chips(for: vm)
        #expect(chips.map(\.name) == ["Screenshot 1", "Screenshot 2", "Selection · Safari"])
        #expect(chips[0].detail == "1944 × 1464")
        #expect(chips[2].detail == "20 characters")
        #expect(ComposerAttachmentStrip.hasChips(viewModel: vm, tray: nil))

        PendingCaptureChips.remove(chips[0].id, from: vm)
        #expect(vm.pendingImages.count == 1)
        #expect(vm.pendingImages[0].pixelWidth == 64)
        PendingCaptureChips.remove(PendingCaptureChips.contextID, from: vm)
        #expect(vm.pendingContext == nil)
    }

    @Test func addContextShowsEveryRowAndFourMeasureAsBefore() {
        #expect(PanelSizing.addContextListHeight(rows: 4) == PanelSizing.actionListHeight(rows: 4, padded: false))
        #expect(PanelSizing.addContextBlockHeight(rows: 4) == PanelSizing.chooserBlockHeight(rows: 4))
        #expect(PanelSizing.addContextListHeight(rows: 7) >= 7 * House.Control.row, "no row is cut")
    }

    @Test func theStripIsOneChipRowHigh() {
        #expect(PanelSizing.attachmentStripHeight == House.Control.chip + House.Spacing.xs * 2)
        #expect(PanelSizing.attachmentHeight == House.hairline + PanelSizing.attachmentStripHeight)
    }
}

/// The composer keys that changed with the AI Chat window (walkthrough
/// items 14 and 15): Tab leaves the multi-line composer, and the field is
/// named "Message" there.
@Suite("Composer keys and name")
@MainActor
struct QuickAIComposerKeyTests {
    @Test func tabLeavesTheMultiLineComposerButNotTheOneLineField() {
        #expect(QuickAIComposer.tabResult(multiline: true) == .ignored)
        #expect(QuickAIComposer.tabResult(multiline: false) == .handled)
    }

    @Test func inTheWindowTabIsLeftToTheFieldUnlessAnAliasCompletes() {
        var settings = QuickSettings()
        settings.historyEnabled = false
        settings.savedPrompts.append(SavedPrompt(alias: "standup", prompt: "Write my standup notes for today."))
        let chat = QuickViewModel(settings: settings, service: MockQuickService())
        let suite = "QuickAIComposerKeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = AIChatWindowModel(chat: chat, defaults: defaults)

        window.chat.input = "what is a context budget"
        #expect(!window.chat.handleTab(), "no alias: Tab moves on")
        window.chat.input = settings.savedPromptPrefix + "stand"
        #expect(window.chat.handleTab(), "an alias completes")
    }

    @Test func pasteAttachesOnlyWhileTheFieldAsks() {
        #expect(QuickAIComposer.pasteAttaches(composerFocused: true, searchingChats: false, typingMode: false))
        #expect(!QuickAIComposer.pasteAttaches(composerFocused: false, searchingChats: false, typingMode: false))
        #expect(!QuickAIComposer.pasteAttaches(composerFocused: true, searchingChats: true, typingMode: false))
        #expect(!QuickAIComposer.pasteAttaches(composerFocused: true, searchingChats: false, typingMode: true))
    }

    @Test func theFieldIsNamedMessageInAIChat() {
        #expect(QuickAIComposer.fieldName(multiline: true, searchingChats: false) == "Message")
        #expect(QuickAIComposer.fieldName(multiline: false, searchingChats: false) == "Ask Quick AI")
        #expect(QuickAIComposer.fieldName(multiline: true, searchingChats: true) == "Search chats")
    }
}

/// Polls an async condition instead of sleeping a fixed time, and records
/// the timeout itself.
@MainActor
private func eventuallyAsync(
    _ description: String,
    timeout: Duration = .seconds(15),
    _ condition: () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if await condition() { return }
    Issue.record("timed out waiting for \(description)")
}
