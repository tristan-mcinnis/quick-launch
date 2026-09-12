import Foundation
import Testing
@testable import QuickLaunch

/// The placeholder engine is a pure function over (template, clipboard, now,
/// arguments), so every case here is exact: no clock, no clipboard, no store.
@Suite("Snippet placeholders")
struct SnippetPlaceholderTests {
    /// 2023-11-14 22:13:20 UTC, so every date assertion is a fixed string.
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static let utc = TimeZone(identifier: "UTC")!

    private func expand(
        _ template: String,
        clipboard: String? = nil,
        arguments: [String] = []
    ) -> SnippetExpansion {
        SnippetPlaceholders.expand(
            template,
            clipboard: clipboard,
            now: Self.now,
            arguments: arguments,
            timeZone: Self.utc
        )
    }

    // MARK: Cursor

    @Test func cursorIsRemovedAndReportsItsOffset() {
        let result = expand("Dear ,\n{cursor}\nRegards")
        #expect(result.text == "Dear ,\n\nRegards")
        #expect(result.cursorOffset == 7)
    }

    @Test func aTemplateWithoutACursorReportsNoOffset() {
        #expect(expand("plain text").cursorOffset == nil)
        #expect(expand("plain text").text == "plain text")
    }

    @Test func onlyTheFirstCursorCounts() {
        let result = expand("a{cursor}b{cursor}c")
        #expect(result.text == "abc")
        #expect(result.cursorOffset == 1)
    }

    @Test func theCursorOffsetIsMeasuredAfterEveryOtherPlaceholder() {
        let result = expand("{clipboard}{cursor}!", clipboard: "hello")
        #expect(result.text == "hello!")
        #expect(result.cursorOffset == 5)
    }

    // MARK: Clipboard

    @Test func clipboardIsInsertedAndTrimmedUnlessRaw() {
        #expect(expand("<{clipboard}>", clipboard: "  hi \n").text == "<hi>")
        #expect(expand("<{clipboard | raw}>", clipboard: "  hi \n").text == "<  hi \n>")
    }

    @Test func anEmptyClipboardInsertsNothing() {
        #expect(expand("[{clipboard}]", clipboard: nil).text == "[]")
        #expect(expand("[{clipboard}]", clipboard: "").text == "[]")
    }

    // MARK: Dates and times

    @Test func dateAndTimeUseTheirDefaultFormats() {
        #expect(expand("{date}").text == "2023-11-14")
        #expect(expand("{time}").text == "22:13")
    }

    @Test func dateTakesAFormat() {
        #expect(expand("{date format=\"dd/MM/yyyy\"}").text == "14/11/2023")
        #expect(expand("{date format=\"EEEE\"}").text == "Tuesday")
        #expect(expand("{time format=\"HH:mm:ss\"}").text == "22:13:20")
    }

    @Test func dateTakesAnOffset() {
        #expect(expand("{date offset=\"+2d\"}").text == "2023-11-16")
        #expect(expand("{date offset=\"-1d\"}").text == "2023-11-13")
        #expect(expand("{date offset=\"+1y\"}").text == "2024-11-14")
        #expect(expand("{date offset=\"+2w\"}").text == "2023-11-28")
        #expect(expand("{date offset=\"-1M\"}").text == "2023-10-14")
    }

    @Test func offsetTermsCombineInOrder() {
        #expect(expand("{date format=\"yyyy-MM-dd\" offset=\"+3M -5d\"}").text == "2024-02-09")
    }

    @Test func timeTakesAnOffsetInMinutesAndHours() {
        #expect(expand("{time offset=\"+90m\"}").text == "23:43")
        #expect(expand("{time offset=\"-2h\"}").text == "20:13")
    }

    @Test func anUnreadableOffsetTermIsSkippedRatherThanFailing() {
        #expect(expand("{date offset=\"banana +1d\"}").text == "2023-11-15")
    }

    // MARK: Arguments

    @Test func argumentsAreListedInTheOrderTheyAppear() {
        let slots = SnippetPlaceholders.arguments(in: "Hi {argument name=\"First\"}, from {argument name=\"Team\"}")
        #expect(slots.map(\.name) == ["First", "Team"])
        #expect(slots.map(\.index) == [0, 1])
    }

    @Test func anUnnamedArgumentGetsAPositionalName() {
        #expect(SnippetPlaceholders.arguments(in: "{argument} {argument}").map(\.name)
            == ["Argument 1", "Argument 2"])
    }

    @Test func theSameNamedArgumentIsAskedOnlyOnce() {
        let template = "{argument name=\"Client\"} — hello {argument name=\"Client\"}"
        #expect(SnippetPlaceholders.arguments(in: template).count == 1)
        #expect(SnippetPlaceholders.expand(template, now: Self.now, arguments: ["Acme"]).text
            == "Acme — hello Acme")
    }

    @Test func multipleArgumentsFillInOrder() {
        let result = expand("{argument} owes {argument}", arguments: ["Ana", "£20"])
        #expect(result.text == "Ana owes £20")
    }

    @Test func aMissingArgumentFallsBackToItsDefaultThenToNothing() {
        #expect(expand("[{argument name=\"City\" default=\"Beijing\"}]").text == "[Beijing]")
        #expect(expand("[{argument name=\"City\" default=\"Beijing\"}]", arguments: ["  "]).text == "[Beijing]")
        #expect(expand("[{argument name=\"City\" default=\"Beijing\"}]", arguments: ["Shanghai"]).text == "[Shanghai]")
        #expect(expand("[{argument}]").text == "[]")
    }

    // MARK: Modifiers

    @Test func modifiersChangeCase() {
        #expect(expand("{clipboard | uppercase}", clipboard: "quiet").text == "QUIET")
        #expect(expand("{clipboard | lowercase}", clipboard: "LOUD").text == "loud")
        #expect(expand("{argument | uppercase}", arguments: ["ana"]).text == "ANA")
        #expect(expand("{date format=\"MMM\" | uppercase}").text == "NOV")
    }

    @Test func modifiersCombineWithAttributes() {
        #expect(expand("{clipboard | raw | uppercase}", clipboard: " x ").text == " X ")
    }

    // MARK: Pass-through and escapes

    @Test func anUnknownPlaceholderPassesThroughUnchanged() {
        #expect(expand("a {unknown} b").text == "a {unknown} b")
        #expect(expand("{ }").text == "{ }")
        #expect(expand("{}").text == "{}")
    }

    @Test func aKnownNameWithAnUnreadableBodyStaysLiteral() {
        #expect(expand("{date format=unquoted}").text == "{date format=unquoted}")
        #expect(expand("{clipboard | shout}", clipboard: "x").text == "{clipboard | shout}")
    }

    @Test func anUnclosedBraceIsJustText() {
        #expect(expand("100% {of it").text == "100% {of it")
    }

    @Test func anEscapedBraceTypesALiteralBrace() {
        #expect(expand("\\{cursor\\}").text == "{cursor}")
        #expect(expand("\\{cursor\\}").cursorOffset == nil)
        #expect(expand("\\\\").text == "\\")
    }

    @Test func aBackslashThatEscapesNothingSurvives() {
        #expect(expand("C:\\Users\\me").text == "C:\\Users\\me")
    }

    @Test func codeAroundAPlaceholderKeepsItsOwnBraces() {
        let result = expand("func x() { return {clipboard} }", clipboard: "1")
        #expect(result.text == "func x() { return 1 }")
    }

    // MARK: Detection

    @Test func detectionIgnoresTextWithNoRealPlaceholder() {
        #expect(SnippetPlaceholders.containsPlaceholders("{date}"))
        #expect(SnippetPlaceholders.containsPlaceholders("hi {argument}"))
        #expect(!SnippetPlaceholders.containsPlaceholders("plain"))
        #expect(!SnippetPlaceholders.containsPlaceholders("{unknown}"))
        #expect(!SnippetPlaceholders.containsPlaceholders("\\{date\\}"))
    }

    @Test func aWholeTemplateExpandsInOnePass() {
        let result = expand(
            "Hi {argument name=\"Name\"},\n\nOn {date format=\"d MMM\" offset=\"+1d\"} we ship {clipboard}.\n{cursor}\n— T",
            clipboard: "v2",
            arguments: ["Ana"]
        )
        #expect(result.text == "Hi Ana,\n\nOn 15 Nov we ship v2.\n\n— T")
        // "Hi Ana," (7) + two newlines (9) + the sentence (30) + one newline.
        #expect(result.cursorOffset == 31)
    }
}
