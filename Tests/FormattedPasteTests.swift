import AppKit
import Foundation
import Testing
@testable import QuickLaunch

/// Formatted response paste: the representations the builder produces, what
/// the sanitizer removes, theme neutrality, the pasteboard write, and where
/// the action routes (including the failure and no-target fallbacks).
@Suite("Formatted paste", .serialized)
@MainActor
struct FormattedPasteTests {

    // MARK: - Builder

    @Test func representationKeepsHeadingsListsAndLinks() {
        let markdown = """
        # Title

        Some **bold** text with a [link](https://example.com).

        - one
        - two

        ```swift
        let x = 1
        ```
        """
        let representation = FormattedPasteBuilder.representation(fromMarkdown: markdown)

        #expect(representation.plainText.contains("Title"))
        #expect(representation.plainText.contains("bold"))
        #expect(representation.plainText.contains("link"))
        #expect(!representation.html.isEmpty)
        #expect(!representation.rtf.isEmpty)
        #expect(representation.hasRichRepresentation)
        #expect(representation.carriesFormatting)
        #expect(representation.prefersRichPaste)
        #expect(representation.html.lowercased().contains("<a"))
        #expect(representation.html.contains("https://example.com"))
    }

    @Test func representationFromAttributedExportsDirectly() throws {
        let source = NSMutableAttributedString()
        source.append(NSAttributedString(string: "bold ", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor,
        ]))
        source.append(NSAttributedString(string: "link", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.linkColor,
            .link: URL(string: "https://example.com")!,
        ]))

        let representation = FormattedPasteBuilder.representation(fromAttributed: source)

        #expect(representation.plainText == "bold link")
        #expect(representation.carriesFormatting)
        #expect(representation.html.lowercased().contains("<b>"))
        #expect(representation.html.contains("https://example.com"))
        #expect(!representation.rtf.isEmpty)
    }

    @Test func plainProseCarriesNoRichStructure() {
        let representation = FormattedPasteBuilder.representation(
            fromMarkdown: "just some ordinary words"
        )
        #expect(representation.plainText == "just some ordinary words")
        #expect(!representation.carriesFormatting)
        #expect(!representation.prefersRichPaste)
    }

    @Test func unsafeLinkNeverReachesARichRepresentation() {
        let representation = FormattedPasteBuilder.representation(
            fromMarkdown: "See [this](javascript:alert(1)) link."
        )
        #expect(!representation.html.lowercased().contains("javascript:"))
        // The link text survives; only the destination is gone.
        #expect(representation.plainText.contains("this"))
        // Structurally: no unsafe link attribute survived into the RTF.
        let decoded = Self.decodedRTF(representation.rtf)
        var urls: [String] = []
        decoded.enumerateAttribute(.link, in: NSRange(location: 0, length: decoded.length)) { value, _, _ in
            if let url = value as? URL { urls.append(url.absoluteString) }
        }
        #expect(!urls.contains { $0.lowercased().contains("javascript") })
    }

    // MARK: - Theme neutrality

    @Test(arguments: [NSAppearance.Name.darkAqua, NSAppearance.Name.aqua])
    func exportIsNeutralInBothAppearances(_ name: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: name))
        var representation = FormattedPasteRepresentation.empty
        appearance.performAsCurrentDrawingAppearance {
            let source = NSMutableAttributedString()
            source.append(NSAttributedString(string: "Heading\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 20),
                .foregroundColor: NSColor.labelColor,
            ]))
            source.append(NSAttributedString(string: "body text", attributes: [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: House.NSColorToken.surfaceTint,
            ]))
            representation = FormattedPasteBuilder.representation(fromAttributed: source)
        }

        #expect(!representation.html.isEmpty)
        let decoded = Self.decodedRTF(representation.rtf)
        var colors: [NSColor] = []
        decoded.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: decoded.length)) { value, _, _ in
            if let color = value as? NSColor { colors.append(color) }
        }
        #expect(!colors.contains(where: Self.isNearWhite),
                "theme ink must not be baked into the paste")
        // No near-white literal in the HTML either.
        let html = representation.html.lowercased()
        #expect(!html.contains("#ffffff") && !html.contains("#fff") && !html.contains("rgb(255"))
    }

    @Test func decodedRTFKeepsBoldAndLinkStructurally() throws {
        let representation = FormattedPasteBuilder.representation(
            fromMarkdown: "plain **bold** [link](https://example.com)"
        )
        let decoded = Self.decodedRTF(representation.rtf)
        let whole = NSRange(location: 0, length: decoded.length)

        var link: URL?
        decoded.enumerateAttribute(.link, in: whole) { value, _, _ in
            if let url = value as? URL { link = url }
        }
        #expect(link?.absoluteString == "https://example.com")

        var sawBold = false
        decoded.enumerateAttribute(.font, in: whole) { value, _, _ in
            if let font = value as? NSFont,
               font.fontDescriptor.symbolicTraits.contains(.bold) { sawBold = true }
        }
        #expect(sawBold, "bold survives the RTF export")
    }

    // MARK: - Sanitizer

    @Test func sanitizerRemovesScriptsHandlersAndUnsafeURLs() {
        let html = """
        <p onclick="steal()">hello <b>world</b></p>
        <script>alert(1)</script>
        <iframe src="https://evil.example"></iframe>
        <a href="javascript:alert(2)">x</a>
        <a href="https://example.com">ok</a>
        """
        let clean = FormattedPasteSanitizer.sanitizeHTML(html)
        #expect(!clean.lowercased().contains("<script"))
        #expect(!clean.lowercased().contains("alert("))
        #expect(!clean.lowercased().contains("onclick"))
        #expect(!clean.lowercased().contains("<iframe"))
        #expect(!clean.lowercased().contains("javascript:"))
        #expect(clean.contains("hello"))
        #expect(clean.contains("<b>world</b>"))
        #expect(clean.contains("https://example.com"))
        #expect(clean.contains("href=\"#\""))
    }

    @Test func sanitizerDropsResourceFetchTags() {
        let html = """
        <img src="https://tracker.example/pixel.png">
        <video src="https://evil.example/v.mp4"></video>
        <source src="https://evil.example/a.mp3">
        <p>kept</p>
        """
        let clean = FormattedPasteSanitizer.sanitizeHTML(html)
        #expect(!clean.lowercased().contains("tracker.example"))
        #expect(!clean.lowercased().contains("evil.example"))
        #expect(!clean.lowercased().contains("<img"))
        #expect(!clean.lowercased().contains("<video"))
        #expect(!clean.lowercased().contains("<source"))
        #expect(clean.contains("kept"))
    }

    @Test func sanitizerRefusesEntityEncodedAndPaddedSchemes() {
        let html = """
        <a href="javascript&#58;alert(1)">a</a>
        <a href="java&#x73;cript:alert(2)">b</a>
        <a href="java&Tab;script:alert(3)">c</a>
        <a href="  javascript:alert(4)  ">d</a>
        <a href="https://example.com">ok</a>
        """
        let clean = FormattedPasteSanitizer.sanitizeHTML(html)
        #expect(!clean.lowercased().contains("javascript"))
        #expect(!clean.lowercased().contains("alert("))
        #expect(clean.contains("https://example.com"))
    }

    @Test func sanitizerKeepsAClosedInertStyleIntact() {
        let html = "<style type=\"text/css\">p { font: 14.0px 'Helvetica Neue' }</style><p>hi</p>"
        let clean = FormattedPasteSanitizer.sanitizeHTML(html)
        #expect(clean.contains("<style"))
        #expect(clean.contains("</style>"))
        #expect(clean.contains("font: 14.0px"))
        #expect(clean.contains("hi"))
    }

    @Test func sanitizerDropsAFetchingStyleAndAnUnclosedOne() {
        let fetching = FormattedPasteSanitizer.sanitizeHTML(
            "<style>body { background: url(https://evil.example/a.png) }</style><p>hi</p>"
        )
        #expect(!fetching.contains("evil.example"))
        #expect(!fetching.contains("<style"))
        #expect(fetching.contains("hi"))

        let unclosed = FormattedPasteSanitizer.sanitizeHTML(
            "<p>before</p><style>body { color: red } SECRET_CSS"
        )
        #expect(!unclosed.contains("SECRET_CSS"), "an unclosed style leaks nothing")
        #expect(!unclosed.contains("<style"))
        #expect(unclosed.contains("before"))
    }

    @Test func sanitizerRefusesFetchingCSSForms() {
        #expect(FormattedPasteSanitizer.isSafeStyle("font: 14.0px 'Helvetica Neue'"))
        #expect(!FormattedPasteSanitizer.isSafeStyle("background: url(https://evil.example/a.png)"))
        #expect(!FormattedPasteSanitizer.isSafeStyle("@import 'x.css'"))
        #expect(!FormattedPasteSanitizer.isSafeStyle("@font-face { src: url(x.woff) }"))
        #expect(!FormattedPasteSanitizer.isSafeStyle("background: image-set('x.png' 1x)"))
        #expect(!FormattedPasteSanitizer.isSafeStyle("width: expression(alert(1))"))
    }

    @Test func linkSchemePolicy() {
        #expect(FormattedPasteSanitizer.isSafeLink(URL(string: "https://example.com")!))
        #expect(FormattedPasteSanitizer.isSafeLink(URL(string: "mailto:a@b.com")!))
        #expect(!FormattedPasteSanitizer.isSafeLink(URL(string: "javascript:alert(1)")!))
        #expect(!FormattedPasteSanitizer.isSafeLink(URL(string: "file:///etc/passwd")!))
        // Attribute URLs are entity-normalized before the scheme check.
        #expect(!FormattedPasteSanitizer.isSafeAttributeURL("javascript&#58;alert(1)"))
        #expect(FormattedPasteSanitizer.isSafeAttributeURL("https://example.com"))
        #expect(FormattedPasteSanitizer.isSafeAttributeURL("/relative/path"))
    }

    // MARK: - Pasteboard

    @Test func systemPasteboardPublishesRichTypesTransiently() {
        let board = NSPasteboard(name: NSPasteboard.Name("quick-launch-formatted-\(UUID().uuidString)"))
        let pasteboard = SystemPasteboard(pasteboard: board)
        let representation = FormattedPasteRepresentation(
            plainText: "plain",
            html: "<b>plain</b>",
            rtf: Data("rtf".utf8),
            carriesFormatting: true
        )

        pasteboard.writeTransientFormatted(representation)

        let types = board.types ?? []
        #expect(types.contains(.string))
        #expect(types.contains(.html))
        #expect(types.contains(.rtf))
        for marker in SystemPasteboard.transientMarkers {
            #expect(types.contains(marker), "the paste is marked as plumbing: \(marker.rawValue)")
        }
        #expect(board.string(forType: .string) == "plain")
        #expect(board.data(forType: .html) == Data("<b>plain</b>".utf8))
        #expect(board.data(forType: .rtf) == Data("rtf".utf8))
    }

    // MARK: - Routing

    @Test func formattedPasteUsesTheRichPathAndNeverTheTextInsertion() async {
        let selection = FormattedPasteSelection()
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.output = "# Heading\n\n**Bold** answer"

        #expect(vm.resultActions.contains(.pasteFormatted))
        let pasted = await vm.pasteFormattedOutputToPreviousApp()

        #expect(pasted)
        #expect(selection.pastePasteboardCount == 1)
        #expect(selection.pastedText == nil, "the text-only insertion path must not run")
        #expect(pasteboard.formattedWriteCount == 1)
        #expect(pasteboard.lastFormattedRepresentation?.carriesFormatting == true)
        #expect(pasteboard.lastFormattedRepresentation?.html.isEmpty == false)
        #expect(pasteboard.isTransient)
    }

    @Test func plainAnswerFallsBackToThePlainTextPath() async {
        let selection = FormattedPasteSelection()
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.output = "plain answer with no structure"

        let pasted = await vm.pasteFormattedOutputToPreviousApp()

        #expect(pasted)
        #expect(selection.pastePasteboardCount == 0)
        #expect(selection.pastedText == "plain answer with no structure")
    }

    @Test func formattedPasteWithoutATargetCopiesRenderedTextAndExplains() async {
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(pasteboard: pasteboard)
        vm.output = "# Heading\nthe body"

        let pasted = await vm.pasteFormattedOutputToPreviousApp()

        #expect(!pasted)
        #expect(vm.errorMessage == "Open Quick Launch from the app where you want to paste. The result was copied instead.")
        #expect(pasteboard.transientWriteCount == 1)
        #expect(pasteboard.string?.contains("Heading") == true)
        #expect(pasteboard.string?.contains("the body") == true)
        #expect(pasteboard.string?.contains("#") == false, "the rendered text is copied, not the markdown")
        #expect(vm.justCopied)
    }

    @Test func plainPasteWithoutATargetCopiesAndExplains() async {
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(pasteboard: pasteboard)
        vm.output = "the answer"

        let pasted = await vm.pasteOutputToPreviousApp()

        #expect(!pasted)
        #expect(vm.errorMessage == "Open Quick Launch from the app where you want to paste. The result was copied instead.")
        #expect(pasteboard.transientWriteCount == 1)
        #expect(pasteboard.string == "the answer")
    }

    @Test func richPasteFailureCopiesRenderedTextAndExplains() async {
        let selection = FormattedPasteSelection()
        selection.pastePasteboardSucceeds = false
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.output = "**Bold** answer"

        let pasted = await vm.pasteFormattedOutputToPreviousApp()

        #expect(!pasted)
        #expect(selection.pastePasteboardCount == 1)
        #expect(vm.errorMessage == "Could not paste into Editor. The result was copied instead.")
        #expect(pasteboard.formattedWriteCount == 1)
        #expect(pasteboard.string == "Bold answer", "the rendered text is copied on failure")
    }

    @Test func plainPasteFailureCopiesAndExplains() async {
        let selection = FormattedPasteSelection()
        selection.pasteSucceeds = false
        let pasteboard = FakePasteboard()
        let vm = QuickViewModel(selectedTextService: selection, pasteboard: pasteboard)
        vm.rememberSelectionTarget(selection.target)
        vm.output = "the answer"

        let pasted = await vm.pasteOutputToPreviousApp()

        #expect(!pasted)
        #expect(vm.errorMessage == "Could not paste into Editor. The result was copied instead.")
        #expect(pasteboard.transientWriteCount == 1)
        #expect(pasteboard.string == "the answer")
    }

    @Test func performResultActionRoutesToTheFormattedPaste() async {
        let selection = FormattedPasteSelection()
        let vm = QuickViewModel(selectedTextService: selection)
        vm.rememberSelectionTarget(selection.target)
        vm.output = "**Emphasised** answer"

        await vm.performResultAction(.pasteFormatted)

        #expect(selection.pastePasteboardCount == 1)
    }

    @Test func formattedPasteKeyIsControlCommandVAndFree() {
        #expect(ResultAction.pasteFormatted.title == "Paste Formatted Response")
        #expect(ResultAction.pasteFormatted.defaultShortcut == .controlCommand("v"))
        #expect(ResultAction.pasteFormatted.defaultShortcut.keyCaps == ["\u{2303}", "\u{2318}", "V"])
        #expect(ResultAction.pasteFormatted.paletteGroup == "Answer")
        #expect(ShortcutAction.forResultAction(.pasteFormatted) == .pasteFormatted)
        #expect(ShortcutAction.pasteFormatted.resultAction == .pasteFormatted)
        // The shipped Clipboard History global stays on its own key.
        #expect(QuickSettings().clipboardHistoryHotkey.keyCaps == ["\u{21E7}", "\u{2318}", "V"])
    }

    @Test func aiChatWindowDropsTheLauncherOnlyFormattedPaste() throws {
        let vm = QuickViewModel()
        vm.output = "**Emphasised** answer"
        #expect(vm.resultActions.contains(.pasteFormatted))
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let window = AIChatWindowModel(chat: vm, defaults: defaults)
        defer { withExtendedLifetime(window) {} }
        #expect(vm.isAIChatWindow)
        #expect(!vm.resultActions.contains(.pasteFormatted))
    }

    // MARK: - Helpers

    private static func decodedRTF(_ data: Data) -> NSAttributedString {
        (try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )) ?? NSAttributedString()
    }

    private static func isNearWhite(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.8
    }
}

/// Records what the formatted paste asked of the paste service. `paste` is the
/// text-only AX path the rich route must never take; `pastePasteboard` is the
/// ⌘V route it must. Both can be made to fail for the fallback tests.
@MainActor
private final class FormattedPasteSelection: SelectedTextServicing {
    let target = SelectionTarget(processIdentifier: 321, applicationName: "Editor")
    private(set) var pastedText: String?
    private(set) var pastePasteboardCount = 0
    var pasteSucceeds = true
    var pastePasteboardSucceeds = true

    var isAccessibilityTrusted: Bool { true }

    func currentExternalTarget() -> SelectionTarget? { target }

    func capture(from target: SelectionTarget, promptForPermission: Bool) -> SelectedTextContext? { nil }

    func replace(_ text: String, in context: SelectedTextContext) async -> Bool { true }

    func paste(_ text: String, to target: SelectionTarget) async -> Bool {
        pastedText = text
        return pasteSucceeds
    }

    func pastePasteboard(to target: SelectionTarget) async -> Bool {
        pastePasteboardCount += 1
        return pastePasteboardSucceeds
    }

    func openAccessibilitySettings() {}
}
